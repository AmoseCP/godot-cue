extends SceneTree

## 生成测试用的 WAV。这些文件是可再生的(总共 27MB),所以不进 git。
##   godot --headless --path . --script tests/make_fixtures.gd
##
## tests/run_all.sh 和 tests/determinism.sh 会在缺文件时自动调用它。

const RATE := 44100


func _init() -> void:
	# 1 秒 440Hz 纯音,内容可精确断言
	_tone("res://tests/probe/tone_1s.wav", 1.0, func(t: float) -> float:
		return sin(TAU * 440.0 * t) * 0.5, true)

	# 5 分钟,用于性能基准
	_tone("res://tests/probe/tone_5min.wav", 300.0, func(t: float) -> float:
		return sin(TAU * 220.0 * t) * 0.8 * (0.5 + 0.5 * sin(TAU * 0.5 * t)), false)

	# 3 秒,确定性测试用
	_tone("res://tests/determinism/tone_3s.wav", 3.0, func(t: float) -> float:
		return sin(TAU * 330.0 * t) * 0.7 * (0.5 + 0.5 * sin(TAU * 1.5 * t)), false)

	print("fixture 生成完毕")
	quit()


## [param exact_16k] 为 true 时按 16384 缩放并取整,方便测试逐点反算。
func _tone(path: String, dur: float, gen: Callable, exact_16k: bool) -> void:
	var n := int(RATE * dur)
	var pcm := PackedByteArray()
	pcm.resize(n * 2)
	for i in n:
		var v: float = gen.call(float(i) / RATE)
		if exact_16k:
			pcm.encode_s16(i * 2, int(v * 32768.0))
		else:
			pcm.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	var f := FileAccess.open(path, FileAccess.WRITE)
	var ds := pcm.size()
	f.store_buffer("RIFF".to_ascii_buffer()); f.store_32(36 + ds)
	f.store_buffer("WAVEfmt ".to_ascii_buffer()); f.store_32(16)
	f.store_16(1); f.store_16(1); f.store_32(RATE)
	f.store_32(RATE * 2); f.store_16(2); f.store_16(16)
	f.store_buffer("data".to_ascii_buffer()); f.store_32(ds)
	f.store_buffer(pcm); f.close()
	print("  写入 %s(%.1f MB)" % [path, float(ds) / 1048576.0])
