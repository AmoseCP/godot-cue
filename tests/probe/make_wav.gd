extends SceneTree

# 生成一个已知内容的 16-bit PCM WAV 文件到 res:// 供导入测试。
func _init() -> void:
	var mix_rate := 44100
	var dur := 300.0            # 5 分钟,用于性能基准
	var n := int(mix_rate * dur)
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		var t := float(i) / mix_rate
		var v := sin(TAU * 220.0 * t) * 0.8 * (0.5 + 0.5 * sin(TAU * 0.5 * t))
		bytes.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	_write_wav("res://tests/probe/tone_5min.wav", bytes, mix_rate, 1)

	# 一个 1 秒的短样本,内容可精确断言
	var n2 := mix_rate
	var b2 := PackedByteArray(); b2.resize(n2 * 2)
	for i in n2:
		b2.encode_s16(i * 2, int(sin(TAU * 440.0 * float(i) / mix_rate) * 16384.0))
	_write_wav("res://tests/probe/tone_1s.wav", b2, mix_rate, 1)
	print("WAV 写入完成")
	quit()

func _write_wav(path: String, pcm: PackedByteArray, rate: int, ch: int) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	var data_size := pcm.size()
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + data_size)
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(16)              # fmt chunk size
	f.store_16(1)               # PCM
	f.store_16(ch)
	f.store_32(rate)
	f.store_32(rate * ch * 2)   # byte rate
	f.store_16(ch * 2)          # block align
	f.store_16(16)              # bits
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(data_size)
	f.store_buffer(pcm)
	f.close()
