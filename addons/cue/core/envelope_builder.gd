@tool
class_name CueEnvelopeBuilder

## 从已经算好的 [WaveformCache] 生成 [CueEnvelope]。
##
## 为什么不重新扫一遍 PCM 求 RMS:峰值缓存已经是每 256 采样一组的
## min/max,把 [code](|min| + |max|) / 2[/code] 在窗口内平均,得到的是
## **平均整流幅度**,和响度的相关性足够好,而且是[b]瞬时[/b]完成的
## (5 分钟音频 51680 个 bucket)。重扫 PCM 要再花 1 秒多,
## 会把 M1 的"首次分析 ≤ 2s"顶穿,换来的精度对"三档嘴型"没有意义。

const DEFAULT_RATE := 60.0


static func from_cache(wf: WaveformCache, rate: float = DEFAULT_RATE) -> CueEnvelope:
	var env := CueEnvelope.new()
	if wf == null or not wf.is_valid() or rate <= 0.0:
		return env

	var spb := wf.seconds_per_bucket()
	if spb <= 0.0:
		return env

	var n_buckets := wf.bucket_count()
	var dur := wf.duration if wf.duration > 0.0 else float(n_buckets) * spb
	var n_points: int = maxi(int(ceil(dur * rate)), 1)

	var vals := PackedFloat32Array()
	vals.resize(n_points)
	var mins := wf.mins
	var maxs := wf.maxs

	# 每个输出点覆盖 buckets_per_point 个 bucket;不足 1 个时至少取 1,
	# 这样高 rate 下相邻点会共用 bucket,曲线仍然连续。
	var buckets_per_point: float = (1.0 / rate) / spb
	for i in n_points:
		var b0: int = int(floor(float(i) * buckets_per_point))
		var b1: int = int(ceil(float(i + 1) * buckets_per_point))
		if b1 <= b0:
			b1 = b0 + 1
		b0 = clampi(b0, 0, n_buckets)
		b1 = clampi(b1, 0, n_buckets)
		if b0 >= b1:
			vals[i] = 0.0
			continue
		var acc := 0.0
		for b in range(b0, b1):
			acc += (absf(mins[b]) + absf(maxs[b])) * 0.5
		vals[i] = acc / float(b1 - b0)

	env.values = vals
	env.rate = rate
	env.duration = dur
	return env


## 把一个 sheet 的全部片段按 offset 拼成一条覆盖整条时间轴的包络。
##
## 重叠处取**较大者**而不是相加 —— 两个角色同时说话时相加会让重叠段虚高,
## 之后归一化又把其余部分压暗,整条包络就废了。
static func from_sheet(sheet: CueSheet, rate: float = DEFAULT_RATE) -> CueEnvelope:
	var segs := sheet.all_segments()
	var dur := sheet.duration()
	if segs.is_empty() or dur <= 0.0 or rate <= 0.0:
		return null

	var out := CueEnvelope.new()
	out.rate = rate
	out.duration = dur
	var vals := PackedFloat32Array()
	vals.resize(maxi(int(ceil(dur * rate)), 1))

	var any := false
	for seg in segs:
		if not seg.has_waveform():
			continue
		any = true
		var part := from_cache(seg.waveform, rate)
		var base := int(round(seg.offset * rate))
		for i in part.values.size():
			var j := base + i
			if j < 0 or j >= vals.size():
				continue
			vals[j] = maxf(vals[j], part.values[i])
	if not any:
		return null

	out.values = vals
	for seg in segs:
		if seg.waveform != null and seg.waveform.source_hash != "":
			out.source_hash = seg.waveform.source_hash
			break
	return normalized(out)


## 归一化到峰值为 1。配音电平普遍偏低,不归一化的话阈值得逐个素材重调。
static func normalized(env: CueEnvelope, headroom: float = 1.0) -> CueEnvelope:
	var p := env.peak()
	if p <= 0.0001:
		return env
	var k := headroom / p
	var out := PackedFloat32Array()
	out.resize(env.values.size())
	for i in env.values.size():
		out[i] = minf(env.values[i] * k, 1.0)
	env.values = out
	return env
