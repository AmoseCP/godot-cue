extends SceneTree

## MP3 / OGG 经 ffmpeg 预转的测试(P2)。
##   godot --headless --path . --script tests/test_ffmpeg.gd
##
## 没装 ffmpeg 时不算失败 —— 它是可选依赖,只验证"缺它时给出可操作的提示"。

const MP3 := "res://tests/probe/compressed/tone.mp3"
const OGG := "res://tests/probe/compressed/tone.ogg"

var _pass := 0
var _fail := 0
## 跳过的断言数。必须报出来 —— 否则「因为没装 ffmpeg 所以什么都没测」
## 和「全测过了」在输出里长得一模一样,CI 会给出虚假的信心。
var _skip := 0


func _init() -> void:
	_test_detection()
	_test_missing_tool_message()
	if CueFFmpeg.available():
		_test_convert()
		_test_cache()
	else:
		# 这些本来会跑的断言记成跳过,而不是当作不存在
		_skip = 24
		print("\n  跳过转码测试:没找到 ffmpeg(可选依赖,不算失败)")
	if _skip > 0:
		print("\n=== %d 通过 / %d 失败 / %d 跳过 ===" % [_pass, _fail, _skip])
	else:
		print("\n=== %d 通过 / %d 失败 ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func ok(c: bool, w: String) -> void:
	if c: _pass += 1; print("  PASS  ", w)
	else: _fail += 1; print("  FAIL  ", w)

func eq(a: Variant, b: Variant, w: String) -> void:
	ok(a == b, "%s (得到 %s,期望 %s)" % [w, a, b])


func _test_detection() -> void:
	print("\n[ffmpeg] 格式判定与查找")
	ok(CueFFmpeg.needs_convert("a/b/voice.mp3"), "mp3 需要转")
	ok(CueFFmpeg.needs_convert("voice.OGG"), "大写扩展名也认")
	ok(CueFFmpeg.needs_convert("voice.m4a"), "m4a 需要转")
	ok(CueFFmpeg.needs_convert("voice.flac"), "flac 需要转")
	ok(not CueFFmpeg.needs_convert("voice.wav"), "wav 不需要转")
	ok(not CueFFmpeg.needs_convert("voice.tres"), "非音频不需要转")

	var exe := CueFFmpeg.find()
	print("    ffmpeg = ", exe if exe != "" else "(未找到)")
	if exe != "":
		ok(FileAccess.file_exists(exe), "找到的路径确实存在")
		var v := CueFFmpeg.version()
		ok(v.contains("ffmpeg"), "能问出版本号:%s" % v)
		# 找一次之后要缓存,不该每次都重新搜
		ok(CueFFmpeg.find() == exe, "重复调用返回同一个路径(有缓存)")


func _test_missing_tool_message() -> void:
	print("\n[ffmpeg] 缺工具时的提示")
	# 不存在的文件应当在检查 ffmpeg 之前就被挡掉
	var errs: Array = []
	var r := CueFFmpeg.to_wav("res://没有这个.mp3", errs)
	eq(r, "", "文件不存在 → 返回空串")
	ok(not errs.is_empty() and errs[0].contains("找不到"), "给出中文错误:%s" % errs)


func _test_convert() -> void:
	print("\n[ffmpeg] 真转码")
	for src in [MP3, OGG]:
		var errs: Array = []
		var wav := CueFFmpeg.to_wav(src, errs)
		ok(wav != "", "%s 转码成功:%s" % [src.get_file(), errs])
		if wav == "":
			continue
		var s := CuePcmReader.read_wav_file(wav)
		ok(s.ok(), "转出来的 WAV 能解析:%s" % s.error)
		eq(s.bits, 16, "转成了 16-bit")
		# 采样率不保证与源一致:Opus 一律重采样到 48kHz(编解码器自身的规定)。
		# 这没关系 —— 波形缓存记的是转码后的 mix_rate,
		# seconds_per_bucket() 用的是同一个值,时间轴自洽。
		ok(s.mix_rate in [44100, 48000], "采样率是常见值(%d)" % s.mix_rate)
		# 源是 1 秒 440Hz,转码有损但时长必须对得上
		ok(absf(s.duration() - 1.0) < 0.06,
			"时长约 1 秒(得到 %.3f)—— 采样率变了也不影响时间轴" % s.duration())
		# 内容也该像个正弦波:峰值接近 0.5(源振幅 16384/32768)
		var peak := 0.0
		for i in mini(s.frame_count, 44100):
			peak = maxf(peak, absf(s.sample(i)))
		ok(peak > 0.3 and peak < 0.75, "峰值合理(%.3f),说明真的解出了音频" % peak)

	# open() 应当自动走这条路,调用方什么都不用改
	var auto := CuePcmReader.open(MP3, null)
	ok(auto.ok(), "CuePcmReader.open() 对 mp3 自动转码:%s" % auto.error)
	eq(auto.bits, 16, "拿到 16-bit PCM")

	# 峰值计算也照常
	var cache := CueWaveformBuilder.new().build(auto, 256)
	ok(cache.is_valid(), "能算出波形缓存")
	ok(cache.bucket_count() > 100, "bucket 数合理(%d)" % cache.bucket_count())


func _test_cache() -> void:
	print("\n[ffmpeg] 转码缓存")
	var p1 := CueFFmpeg.cache_path_for(MP3)
	var p2 := CueFFmpeg.cache_path_for(MP3)
	eq(p1, p2, "同一个源文件给出同一个缓存路径")
	ok(p1.begins_with(CueFFmpeg.CACHE_DIR), "缓存写在 user:// 下,不在源文件旁边")
	ok(CueFFmpeg.cache_path_for(OGG) != p1, "不同源文件缓存路径不同")

	# 第二次转码应当直接命中缓存(不再调 ffmpeg)
	var t0 := Time.get_ticks_msec()
	var again := CueFFmpeg.to_wav(MP3, [])
	var dt := Time.get_ticks_msec() - t0
	eq(again, p1, "第二次返回同一个缓存文件")
	ok(dt < 50, "命中缓存,没有重新调用 ffmpeg(%dms)" % dt)
