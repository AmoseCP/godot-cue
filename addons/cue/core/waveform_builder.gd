@tool
class_name CueWaveformBuilder extends RefCounted

## 从 PCM 源计算 min/max 峰值,产出 [WaveformCache]。
##
## 4.7.2 实测:5 分钟 44.1kHz 单声道(1323 万采样)全量逐采样
## [code]decode_s16[/code] 约需 630ms —— PLAN 第 7 节担心的
## "GDScript 逐采样循环性能不足" 不成立,所以这里不做步进近似,
## 峰值是精确的。分块只是为了不冻结编辑器 UI。

## 每次分块最多处理的采样数。按实测 ~21M 采样/秒算,200 万采样约 95ms,
## 压在 CLAUDE.md 要求的"不冻结编辑器超过 100ms"以内。
const SAMPLES_PER_SLICE := 2_000_000

signal progress(ratio: float)

var _mins: PackedFloat32Array = PackedFloat32Array()
var _maxs: PackedFloat32Array = PackedFloat32Array()


## 一次算完。用于 headless 测试和小文件。
func build(src: CuePcmReader.Source, samples_per_bucket: int = 256) -> WaveformCache:
	var spb := _prepare(src, samples_per_bucket)
	if spb <= 0:
		return WaveformCache.new()
	_fill(src, spb, 0, _mins.size())
	return _finish(src, spb)


## 分块算,期间 [code]await[/code] 帧,编辑器不会冻结。
func build_async(src: CuePcmReader.Source, samples_per_bucket: int = 256) -> WaveformCache:
	var spb := _prepare(src, samples_per_bucket)
	if spb <= 0:
		return WaveformCache.new()
	var n := _mins.size()
	var per_slice: int = maxi(SAMPLES_PER_SLICE / spb, 1)
	var b := 0
	while b < n:
		var e: int = mini(b + per_slice, n)
		_fill(src, spb, b, e)
		b = e
		progress.emit(float(b) / float(n))
		if b < n:
			await Engine.get_main_loop().process_frame
	return _finish(src, spb)


## 分配峰值数组。返回实际使用的 samples_per_bucket,0 表示源不可用。
func _prepare(src: CuePcmReader.Source, samples_per_bucket: int) -> int:
	if not src.ok():
		return 0
	var spb: int = maxi(samples_per_bucket, 1)
	var n: int = int(ceil(float(_frames(src)) / float(spb)))
	_mins = PackedFloat32Array()
	_maxs = PackedFloat32Array()
	_mins.resize(n)
	_maxs.resize(n)
	return spb


## 计算 [param from_bucket, to_bucket) 区间的峰值。
func _fill(src: CuePcmReader.Source, spb: int, from_bucket: int, to_bucket: int) -> void:
	var frames := _frames(src)
	# 16-bit 单声道的热路径单独展开:省掉每个采样上的声道乘法和位深分支。
	# 这是 1300 万次迭代里唯一值得手工优化的地方。
	var fast16 := src.bits == 16 and src.channels == 1
	var bytes := src.bytes
	for b in range(from_bucket, to_bucket):
		var start := b * spb
		var stop: int = mini(start + spb, frames)
		var lo := 1.0
		var hi := -1.0
		var i := start
		if fast16:
			while i < stop:
				var v := float(bytes.decode_s16(i * 2)) / 32768.0
				if v < lo: lo = v
				if v > hi: hi = v
				i += 1
		else:
			while i < stop:
				var v := src.sample(i)
				if v < lo: lo = v
				if v > hi: hi = v
				i += 1
		if hi < lo:
			lo = 0.0
			hi = 0.0
		_mins[b] = lo
		_maxs[b] = hi


## 以 bytes 实际能提供的帧数为准 —— 头部声称的帧数可能更大(文件被截断),
## 照着它读会越界。
static func _frames(src: CuePcmReader.Source) -> int:
	return mini(src.frame_count, src.available_frames())


func _finish(src: CuePcmReader.Source, spb: int) -> WaveformCache:
	var cache := WaveformCache.new()
	cache.mins = _mins
	cache.maxs = _maxs
	cache.samples_per_bucket = spb
	cache.mix_rate = src.mix_rate
	cache.duration = float(_frames(src)) / float(maxi(src.mix_rate, 1))
	return cache
