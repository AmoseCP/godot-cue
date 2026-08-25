@tool
class_name CuePcmReader

## WAV → PCM 采样读取。
##
## 有两条路径,按顺序尝试:
##
## 1. [b]直接读源文件[/b](首选)。Godot 4.4+ 默认用 QOA 压缩导入 WAV
##    (4.7.2 实测 [code]compress/mode=2[/code] → [code]format == FORMAT_QOA[/code]),
##    此时 [code]AudioStreamWAV.data[/code] 是压缩数据,GDScript 无法解码。
##    自己解析 RIFF 头就完全绕过导入设置,用户不必改任何东西。
## 2. [b]读导入后的 data[/b]。当用户把压缩模式设为"禁用"时,
##    [code]data[/code] 是裸 PCM,省掉一次文件读取。
##
## 只支持 8/16-bit 整数 PCM(见 PLAN D2)。IMA-ADPCM / QOA / float WAV 一律拒绝并报错。

## 一次读取的结果。刻意不持有解码后的浮点数组:5 分钟 44.1kHz 单声道
## 展开成 PackedFloat32Array 是 53MB,而峰值计算是流式的,不需要全量驻留。
class Source extends RefCounted:
	var bytes: PackedByteArray = PackedByteArray()
	## 8 或 16。
	var bits: int = 16
	var channels: int = 1
	var mix_rate: int = 44100
	## 每声道的采样帧数。
	var frame_count: int = 0
	## 8-bit 时源数据是否为无符号(RIFF 规范如此,Godot 内部则是有符号)。
	var unsigned_8: bool = false
	var error: String = ""

	func ok() -> bool:
		return error == "" and frame_count > 0

	## bytes 实际能提供的帧数。被截断的录音文件里,头部声称的长度
	## 可能超过 data 块的实际长度,直接信任它会导致越界读取。
	func available_frames() -> int:
		var bpf := channels * (bits / 8)
		if bpf <= 0:
			return 0
		return bytes.size() / bpf

	func duration() -> float:
		if mix_rate <= 0:
			return 0.0
		return float(frame_count) / float(mix_rate)

	## 读取第 [param frame] 帧的第 0 声道采样,归一化到 -1..1。
	## 立体声只取左声道 —— 波形只是用来对准口型的参考,混合声道反而会掩盖瞬态。
	func sample(frame: int) -> float:
		var i := frame * channels
		if bits == 16:
			return float(bytes.decode_s16(i * 2)) / 32768.0
		var b := bytes.decode_u8(i)
		if unsigned_8:
			return (float(b) - 128.0) / 128.0
		return float(bytes.decode_s8(i)) / 128.0


const _CHUNK_HEADER := 8


## 打开一个音频源。[param audio_path] 是 res:// 下的源 WAV 路径,
## [param stream] 是导入后的资源(任一为空都可以,但不能都为空)。
static func open(audio_path: String, stream: AudioStream = null) -> Source:
	if audio_path != "" and audio_path.get_extension().to_lower() == "wav" \
			and FileAccess.file_exists(audio_path):
		var src := read_wav_file(audio_path)
		if src.ok():
			return src
		# 源文件在但解析失败 —— 保留这个错误,它比"没有源文件"更有信息量。
		if stream == null:
			return src

	if stream is AudioStreamWAV:
		return read_imported(stream)

	var bad := Source.new()
	if stream == null:
		bad.error = "Cue:没有可分析的音频。请在 CueSheet 上设置 audio 或 audio_path。"
	else:
		bad.error = "Cue:不支持的音频类型 %s。波形分析只支持 16-bit PCM WAV(见 README)。" \
			% stream.get_class()
	return bad


## 解析磁盘上的 RIFF/WAVE 文件。不假设 44 字节固定头 —— Audacity 等工具
## 会插入 LIST/INFO 等额外 chunk,必须逐块遍历。
static func read_wav_file(path: String) -> Source:
	var src := Source.new()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		src.error = "Cue:无法打开音频文件 %s(错误码 %d)。" % [path, FileAccess.get_open_error()]
		return src

	var size := f.get_length()
	if size < 12:
		src.error = "Cue:%s 太小,不是有效的 WAV 文件。" % path
		return src
	if f.get_buffer(4).get_string_from_ascii() != "RIFF":
		src.error = "Cue:%s 不是 RIFF/WAVE 文件。波形分析只支持未压缩的 16-bit PCM WAV。" % path
		return src
	f.seek(8)
	if f.get_buffer(4).get_string_from_ascii() != "WAVE":
		src.error = "Cue:%s 是 RIFF 文件但不是 WAVE 格式。" % path
		return src

	var fmt_found := false
	var pos := 12
	while pos + _CHUNK_HEADER <= size:
		f.seek(pos)
		var id := f.get_buffer(4).get_string_from_ascii()
		var chunk_size := f.get_32()
		var body := pos + _CHUNK_HEADER

		if id == "fmt ":
			var audio_format := f.get_16()
			src.channels = f.get_16()
			src.mix_rate = f.get_32()
			f.get_32()                      # byte rate,可由其他字段推出
			f.get_16()                      # block align
			src.bits = f.get_16()
			fmt_found = true
			if audio_format != 1:           # 1 = WAVE_FORMAT_PCM
				# 0xFFFE 是 WAVE_FORMAT_EXTENSIBLE,子格式仍可能是 PCM;
				# 但 16-bit 整数 extensible 的数据布局与 PCM 一致,放行。
				if not (audio_format == 0xFFFE and src.bits in [8, 16]):
					src.error = "Cue:%s 是压缩音频(WAVE 格式码 %d)。请在 Audacity 中导出为「WAV 16-bit PCM」。" \
						% [path.get_file(), audio_format]
					return src
			if not src.bits in [8, 16]:
				src.error = "Cue:%s 是 %d-bit WAV,只支持 8-bit 和 16-bit。请导出为 16-bit PCM。" \
					% [path.get_file(), src.bits]
				return src
			if src.channels <= 0:
				src.error = "Cue:%s 的声道数无效(%d)。" % [path.get_file(), src.channels]
				return src

		elif id == "data":
			if not fmt_found:
				src.error = "Cue:%s 的 data 块出现在 fmt 块之前,文件结构异常。" % path.get_file()
				return src
			var avail: int = mini(chunk_size, size - body)
			f.seek(body)
			src.bytes = f.get_buffer(avail)
			var bytes_per_frame := src.channels * (src.bits / 8)
			src.frame_count = src.bytes.size() / bytes_per_frame if bytes_per_frame > 0 else 0
			src.unsigned_8 = src.bits == 8      # RIFF 的 8-bit PCM 是无符号的
			f.close()
			if src.frame_count <= 0:
				src.error = "Cue:%s 的 data 块为空。" % path.get_file()
			return src

		# chunk 以偶数字节对齐
		pos = body + chunk_size + (chunk_size & 1)

	f.close()
	src.error = "Cue:%s 中找不到 data 块。" % path.get_file()
	return src


## 从已导入的 AudioStreamWAV 读取。仅当导入时关闭了压缩才可用。
static func read_imported(wav: AudioStreamWAV) -> Source:
	var src := Source.new()
	match wav.format:
		AudioStreamWAV.FORMAT_16_BITS:
			src.bits = 16
		AudioStreamWAV.FORMAT_8_BITS:
			src.bits = 8
			src.unsigned_8 = false          # Godot 内部存的是有符号 8-bit
		AudioStreamWAV.FORMAT_IMA_ADPCM:
			src.error = "Cue:音频以 IMA-ADPCM 压缩导入,无法读取波形。请在文件的「导入」面板中把「压缩模式」设为「禁用」并重新导入,或保留源 .wav 文件在项目内。"
			return src
		AudioStreamWAV.FORMAT_QOA:
			src.error = "Cue:音频以 QOA 压缩导入(Godot 4.4+ 的默认设置),无法读取波形。请在文件的「导入」面板中把「压缩模式」设为「禁用」并重新导入,或保留源 .wav 文件在项目内。"
			return src
		_:
			src.error = "Cue:未知的音频格式枚举值 %d。" % wav.format
			return src

	src.bytes = wav.data
	src.channels = 2 if wav.stereo else 1
	src.mix_rate = wav.mix_rate
	var bytes_per_frame := src.channels * (src.bits / 8)
	src.frame_count = src.bytes.size() / bytes_per_frame if bytes_per_frame > 0 else 0
	if src.frame_count <= 0:
		src.error = "Cue:导入的音频数据为空。"
	return src
