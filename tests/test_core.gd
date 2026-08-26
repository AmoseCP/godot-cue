extends SceneTree

## Cue 核心逻辑的 headless 测试。
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_core.gd
##
## 覆盖 PLAN 第 8 节的单元测试项 + M1 的性能门槛。

const WAV_5MIN := "res://tests/probe/tone_5min.wav"
const WAV_1S := "res://tests/probe/tone_1s.wav"

var _pass := 0
var _fail := 0


func _init() -> void:
	_test_riff_parse()
	_test_known_samples()
	_test_stereo_and_8bit()
	_test_bad_format_errors()
	_test_peak_build()
	_test_perf_5min()
	_test_cache_roundtrip()
	_test_sheet_lookup_and_sort()
	_test_snap()
	_test_validate()
	_test_redraw_perf()

	print("\n=== %d 通过 / %d 失败 ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# ── 断言 ────────────────────────────────────────────────────────────

func ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("  PASS  ", what)
	else:
		_fail += 1
		print("  FAIL  ", what)


func eq(a: Variant, b: Variant, what: String) -> void:
	ok(a == b, "%s (得到 %s,期望 %s)" % [what, a, b])


func near(a: float, b: float, tol: float, what: String) -> void:
	ok(absf(a - b) <= tol, "%s (得到 %.6f,期望 %.6f ±%.6f)" % [what, a, b, tol])


# ── PCM 解码 ────────────────────────────────────────────────────────

func _test_riff_parse() -> void:
	print("\n[PCM] RIFF 解析")
	var src := CuePcmReader.read_wav_file(WAV_1S)
	ok(src.ok(), "1 秒 WAV 解析成功:%s" % src.error)
	eq(src.bits, 16, "位深")
	eq(src.channels, 1, "声道数")
	eq(src.mix_rate, 44100, "采样率")
	eq(src.frame_count, 44100, "采样帧数")
	near(src.duration(), 1.0, 0.001, "时长")


func _test_known_samples() -> void:
	print("\n[PCM] 已知波形逐点比对")
	# tone_1s.wav 内容是 sin(TAU*440*i/44100) * 16384,原样反算
	var src := CuePcmReader.read_wav_file(WAV_1S)
	var worst := 0.0
	for i in [0, 1, 25, 100, 4410, 22050, 44099]:
		var expect := sin(TAU * 440.0 * float(i) / 44100.0) * 16384.0
		expect = float(int(expect)) / 32768.0     # 源写入时截断为整数
		worst = maxf(worst, absf(src.sample(i) - expect))
	near(worst, 0.0, 1.0 / 32768.0, "解码值与源一致(最大偏差)")

	# 边界值:构造 -32768 / 0 / 32767
	var bytes := PackedByteArray()
	bytes.resize(6)
	bytes.encode_s16(0, -32768)
	bytes.encode_s16(2, 0)
	bytes.encode_s16(4, 32767)
	var s := CuePcmReader.Source.new()
	s.bytes = bytes; s.bits = 16; s.channels = 1; s.mix_rate = 44100; s.frame_count = 3
	near(s.sample(0), -1.0, 1e-6, "最小值 → -1.0")
	near(s.sample(1), 0.0, 1e-6, "零值 → 0.0")
	near(s.sample(2), 1.0, 1e-4, "最大值 → ~1.0")


func _test_stereo_and_8bit() -> void:
	print("\n[PCM] 立体声交错与 8-bit")
	# 立体声:左 = +0.5,右 = -0.5。只取左声道。
	var b := PackedByteArray(); b.resize(8)
	b.encode_s16(0, 16384);  b.encode_s16(2, -16384)
	b.encode_s16(4, 16384);  b.encode_s16(6, -16384)
	var s := CuePcmReader.Source.new()
	s.bytes = b; s.bits = 16; s.channels = 2; s.mix_rate = 44100; s.frame_count = 2
	near(s.sample(0), 0.5, 1e-4, "立体声第 0 帧取左声道")
	near(s.sample(1), 0.5, 1e-4, "立体声第 1 帧取左声道")

	# RIFF 的 8-bit PCM 是无符号:128 = 静音
	var b8 := PackedByteArray([128, 255, 0])
	var s8 := CuePcmReader.Source.new()
	s8.bytes = b8; s8.bits = 8; s8.channels = 1; s8.unsigned_8 = true
	s8.mix_rate = 22050; s8.frame_count = 3
	near(s8.sample(0), 0.0, 1e-6, "8-bit 无符号 128 → 0.0")
	near(s8.sample(1), 0.9922, 1e-3, "8-bit 无符号 255 → ~+1.0")
	near(s8.sample(2), -1.0, 1e-6, "8-bit 无符号 0 → -1.0")


func _test_bad_format_errors() -> void:
	print("\n[PCM] 坏格式给中文错误而不是崩溃")
	var f := FileAccess.open("user://not_a_wav.wav", FileAccess.WRITE)
	f.store_string("这不是 WAV 文件,只是一堆文字而已，长度足够绕过最小长度检查。")
	f.close()
	var src := CuePcmReader.read_wav_file("user://not_a_wav.wav")
	ok(not src.ok(), "非 RIFF 文件被拒绝")
	ok(src.error.contains("Cue:"), "错误信息带 Cue: 前缀")
	ok(src.error.contains("WAV") or src.error.contains("RIFF"), "错误信息说明了原因:%s" % src.error)

	var missing := CuePcmReader.read_wav_file("res://tests/probe/不存在.wav")
	ok(not missing.ok(), "不存在的文件被拒绝而不是崩溃")

	# QOA(4.7 默认导入)必须给出可操作的中文提示
	var wav: AudioStreamWAV = load(WAV_1S)
	eq(wav.format, AudioStreamWAV.FORMAT_QOA, "4.7 默认导入确实是 QOA")
	var q := CuePcmReader.read_imported(wav)
	ok(not q.ok(), "QOA 导入数据被拒绝")
	ok(q.error.contains("压缩模式"), "QOA 错误告诉用户怎么修:%s" % q.error)

	# 但 open() 会自动回退到源文件,用户什么都不用改
	var auto := CuePcmReader.open(WAV_1S, wav)
	ok(auto.ok(), "open() 绕过 QOA,直接读源文件成功")
	eq(auto.frame_count, 44100, "回退路径拿到完整采样")


# ── 峰值 ────────────────────────────────────────────────────────────

func _test_peak_build() -> void:
	print("\n[峰值] 正确性")
	# 4 个 bucket,内容分别是 +1 / -1 / 0 / 斜坡
	var n := 4 * 256
	var b := PackedByteArray(); b.resize(n * 2)
	for i in n:
		var bucket := i / 256
		var v := 0
		match bucket:
			0: v = 32767
			1: v = -32768
			2: v = 0
			3: v = int(lerpf(-16384.0, 16384.0, float(i % 256) / 255.0))
		b.encode_s16(i * 2, v)
	var s := CuePcmReader.Source.new()
	s.bytes = b; s.bits = 16; s.channels = 1; s.mix_rate = 44100; s.frame_count = n

	var cache := CueWaveformBuilder.new().build(s, 256)
	eq(cache.bucket_count(), 4, "bucket 数")
	near(cache.maxs[0], 1.0, 1e-4, "bucket0 max")
	near(cache.mins[1], -1.0, 1e-6, "bucket1 min")
	near(cache.maxs[2], 0.0, 1e-6, "bucket2 max")
	near(cache.mins[2], 0.0, 1e-6, "bucket2 min")
	near(cache.mins[3], -0.5, 1e-3, "bucket3 min(斜坡起点)")
	near(cache.maxs[3], 0.5, 1e-3, "bucket3 max(斜坡终点)")
	near(cache.seconds_per_bucket(), 256.0 / 44100.0, 1e-9, "每 bucket 秒数")

	# 不整除的尾巴不能丢
	var tail := 4 * 256 + 7
	var b2 := PackedByteArray(); b2.resize(tail * 2)
	for i in tail:
		b2.encode_s16(i * 2, 8192 if i >= 4 * 256 else 0)
	var s2 := CuePcmReader.Source.new()
	s2.bytes = b2; s2.bits = 16; s2.channels = 1; s2.mix_rate = 44100; s2.frame_count = tail
	var c2 := CueWaveformBuilder.new().build(s2, 256)
	eq(c2.bucket_count(), 5, "尾部不足一个 bucket 也要占一格")
	near(c2.maxs[4], 0.25, 1e-3, "尾部 bucket 的峰值来自那 7 个采样")

	# 头部声称的帧数超过实际数据时,必须夹紧而不是越界读
	var s3 := CuePcmReader.Source.new()
	s3.bytes = b2; s3.bits = 16; s3.channels = 1; s3.mix_rate = 44100
	s3.frame_count = tail * 10          # 谎报十倍
	var c3 := CueWaveformBuilder.new().build(s3, 256)
	eq(c3.bucket_count(), 5, "截断文件按实际字节数算 bucket,不按头部声称的长度")


func _test_perf_5min() -> void:
	print("\n[性能] M1 门槛:5 分钟 WAV 首次分析 ≤ 2s")
	var t0 := Time.get_ticks_msec()
	var src := CuePcmReader.read_wav_file(WAV_5MIN)
	var t_read := Time.get_ticks_msec() - t0
	ok(src.ok(), "5 分钟 WAV 读取成功")
	eq(src.frame_count, 13230000, "采样帧数")

	t0 = Time.get_ticks_msec()
	var cache := CueWaveformBuilder.new().build(src, 256)
	var t_peak := Time.get_ticks_msec() - t0
	var total := t_read + t_peak
	print("        读文件 %dms + 峰值 %dms = %dms" % [t_read, t_peak, total])
	ok(total <= 2000, "总耗时 %dms ≤ 2000ms" % total)
	eq(cache.bucket_count(), int(ceil(13230000.0 / 256.0)), "bucket 数")
	near(cache.duration, 300.0, 0.01, "时长 300s")


func _test_cache_roundtrip() -> void:
	print("\n[缓存] .res 存取与失效检测")
	var src := CuePcmReader.read_wav_file(WAV_5MIN)
	var cache := CueWaveformBuilder.new().build(src, 256)
	cache.source_hash = WaveformCache.compute_hash(WAV_5MIN)
	ok(cache.source_hash != "", "算出了音频哈希")

	var path := "user://cue_test_wave.res"
	eq(ResourceSaver.save(cache, path), OK, "保存 .res")

	var t0 := Time.get_ticks_msec()
	var loaded: WaveformCache = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var t_load := Time.get_ticks_msec() - t0
	print("        缓存加载 %dms" % t_load)
	ok(t_load <= 100, "缓存命中 %dms ≤ 100ms" % t_load)
	eq(loaded.bucket_count(), cache.bucket_count(), "bucket 数往返一致")
	near(loaded.mins[1000], cache.mins[1000], 1e-6, "峰值往返一致")
	ok(loaded.matches(WAV_5MIN), "哈希匹配 → 缓存有效")
	ok(not loaded.matches(WAV_1S), "换音频 → 缓存失效")


# ── CueSheet ────────────────────────────────────────────────────────

func _test_sheet_lookup_and_sort() -> void:
	print("\n[Sheet] 查找与排序")
	var sheet := CueSheet.new()
	sheet.fps = 30
	for d in [[&"c", 3.0, &"dialogue"], [&"a", 1.0, &"dialogue"],
			[&"b", 2.0, &"mouth"], [&"d", 1.0, &"mouth"]]:
		sheet.add_marker(CueMarker.new(d[0], d[1], d[2]))

	var s := sheet.sorted()
	eq(s.size(), 4, "排序结果条数")
	# 1.0 上有 a 和 d,平局按名字 → a 在前。这条保证排序是全序(确定性要求)。
	eq(String(s[0].name), "a", "第 0 个")
	eq(String(s[1].name), "d", "第 1 个(同时间按名字)")
	eq(String(s[2].name), "b", "第 2 个")
	eq(String(s[3].name), "c", "第 3 个")

	# 同一份数据反复排序必须得到同一个顺序
	var again := sheet.sorted()
	var same := true
	for i in s.size():
		if s[i].name != again[i].name:
			same = false
	ok(same, "重复排序结果稳定")

	eq(sheet.find(&"b").time, 2.0, "按名字查找")
	ok(sheet.find(&"没有这个") == null, "查不到返回 null")
	eq(sheet.in_track(&"mouth").size(), 2, "按轨道过滤")
	eq(String(sheet.in_track(&"mouth")[0].name), "d", "轨道内也按时间排序")

	# 排序缓存必须在编辑后失效
	sheet.find(&"c").time = 0.5
	sheet.invalidate()
	eq(String(sheet.sorted()[0].name), "c", "改时间后重新排序")

	eq(String(sheet.unique_name(&"a")), "a_1", "重名时自动改名")
	eq(String(sheet.unique_name(&"全新")), "全新", "不重名就原样返回")


func _test_snap() -> void:
	print("\n[Sheet] 帧吸附")
	var sheet := CueSheet.new()
	sheet.fps = 30
	near(sheet.snap(0.0), 0.0, 1e-9, "0 吸附到 0")
	near(sheet.snap(1.0 / 30.0 + 0.001), 1.0 / 30.0, 1e-6, "略微超过一帧 → 吸回该帧")
	# 吸附取最近帧:0.049*30 = 1.47 → 第 1 帧
	near(sheet.snap(0.049), 1.0 / 30.0, 1e-6, "0.049s → 最近的是第 1 帧")
	near(sheet.snap(0.051), 2.0 / 30.0, 1e-6, "0.051s → 最近的是第 2 帧")
	sheet.fps = 24
	near(sheet.snap(0.5), 12.0 / 24.0, 1e-9, "24fps 下 0.5s 正好是第 12 帧")


func _test_validate() -> void:
	print("\n[Sheet] 数据校验")
	var sheet := CueSheet.new()
	sheet.add_marker(CueMarker.new(&"x", 1.0))
	ok(sheet.validate().is_empty(), "健康数据无告警")
	sheet.add_marker(CueMarker.new(&"x", 2.0))
	var issues := sheet.validate()
	ok(issues.size() == 1 and issues[0].contains("重复"), "重名被检出:%s" % issues)
	sheet.add_marker(CueMarker.new(&"", 3.0))
	ok(sheet.validate().size() == 2, "未命名标记也被检出")


# ── 绘制性能 ────────────────────────────────────────────────────────

func _test_redraw_perf() -> void:
	print("\n[性能] M1 门槛:缩放全程 ≥ 50fps(每帧线段重建 ≤ 20ms)")
	var src := CuePcmReader.read_wav_file(WAV_5MIN)
	var sheet := CueSheet.new()
	var seg := CueAudioSegment.new(&"voice", WAV_5MIN, 0.0)
	seg.waveform = CueWaveformBuilder.new().build(src, 256)
	sheet.segments = [seg] as Array[CueAudioSegment]

	var state := CueViewState.new()
	state.sheet = sheet
	state.view_width = 1920.0

	var view := CueWaveformView.new()
	view.setup(state)
	view.size = Vector2(1920, 200)

	var worst := 0
	var worst_at := 0.0
	# 从 60 秒/屏 一路拉到 0.2 秒/屏
	for i in 40:
		var vis: float = lerpf(60.0, 0.2, float(i) / 39.0)
		state.px_per_sec = 1920.0 / vis
		state.scroll_sec = 100.0
		var t0 := Time.get_ticks_msec()
		view.call("_rebuild_lines")
		var dt := Time.get_ticks_msec() - t0
		if dt > worst:
			worst = dt
			worst_at = vis
	print("        最慢一帧 %dms(在 %.2f 秒/屏)" % [worst, worst_at])
	ok(worst <= 20, "最慢 %dms ≤ 20ms(≥50fps)" % worst)

	# 多段时线段拼进同一个数组,一次 draw_multiline 画完
	var seg2 := CueAudioSegment.new(&"voice_b", WAV_5MIN, 120.0)
	seg2.waveform = seg.waveform
	sheet.segments = [seg, seg2] as Array[CueAudioSegment]
	state.px_per_sec = 1920.0 / 8.0
	state.scroll_sec = 130.0
	var t2 := Time.get_ticks_msec()
	view.call("_rebuild_lines")
	var dt2 := Time.get_ticks_msec() - t2
	print("        两段重叠时一帧 %dms" % dt2)
	ok(dt2 <= 20, "两段时最慢 %dms ≤ 20ms" % dt2)
	view.free()
