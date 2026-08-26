@tool
class_name CueSpectrogram extends RefCounted

## 按需生成的频谱图。
##
## [b]刻意不做持久缓存[/b]:5 分钟音频的频谱图即使量化成 8-bit、
## 只留 96 个频段,也有 80 万个数据点 —— 存进 .tres 会让文本资源膨胀成
## 几兆,而频谱图是[b]诊断用[/b]的视图(偶尔看一眼,不是一直盯着),
## 不值得为它污染资源文件。
##
## 实测(4.7.2,M1):512 点 FFT 每次 0.50ms,所以一屏 480 列约 240ms。
## 分块 await 之后编辑器不会卡,旧图在新图算好之前继续显示。

signal progress(ratio: float)

## 每帧最多算多少列。按 0.5ms/列 算,60 列约 30ms,留足余量。
const COLS_PER_SLICE := 60
const DEFAULT_FFT := 512
const DEFAULT_ROWS := 96
## 频率轴的下限。再低的部分对配音没有信息量,却会占掉大半个图。
const MIN_HZ := 50.0
## 动态范围(分贝)。低于 -[constant DB_RANGE] 的一律画成底色。
const DB_RANGE := 70.0

var _re: PackedFloat32Array = PackedFloat32Array()
var _im: PackedFloat32Array = PackedFloat32Array()


## 生成 [param t0]..[param t1](片段内部时间)的频谱图。
##
## 返回一张 [param cols] × [param rows] 的 [Image],值域 0..1 存在红通道里,
## 上色交给调用方 —— 这样配色能跟编辑器主题走,不必在这里硬编码。
func build_async(src: CuePcmReader.Source, t0: float, t1: float,
		cols: int, rows: int = DEFAULT_ROWS, fft_size: int = DEFAULT_FFT) -> Image:
	if not src.ok() or cols <= 0 or rows <= 0 or t1 <= t0:
		return null
	if not CueFFT.is_pow2(fft_size):
		push_error("Cue:FFT 长度必须是 2 的幂,得到 %d。" % fft_size)
		return null

	var img := Image.create(cols, rows, false, Image.FORMAT_RF)
	var win := CueFFT.hann(fft_size)
	var half := fft_size / 2
	var rate := float(src.mix_rate)
	var nyquist := rate * 0.5
	var frames := mini(src.frame_count, src.available_frames())

	# 行 → FFT bin 区间。频率轴取对数 —— 线性轴会把人声那几百赫兹
	# 挤在最底下一两个像素里。
	var row_lo := PackedInt32Array(); row_lo.resize(rows)
	var row_hi := PackedInt32Array(); row_hi.resize(rows)
	var log_min := log(MIN_HZ)
	var log_max := log(maxf(nyquist, MIN_HZ * 2.0))
	for r in rows:
		# 第 0 行画在图像底部 = 低频
		var f0: float = exp(lerpf(log_min, log_max, float(r) / float(rows)))
		var f1: float = exp(lerpf(log_min, log_max, float(r + 1) / float(rows)))
		row_lo[r] = clampi(int(f0 / nyquist * float(half)), 0, half - 1)
		row_hi[r] = clampi(maxi(int(f1 / nyquist * float(half)), row_lo[r] + 1), 1, half)

	_re.resize(fft_size)
	_im.resize(fft_size)

	# 幅度归一化:加了 Hann 窗之后,满量程正弦在峰值 bin 上的幅度是
	# A * N / 4(N/2 来自实信号的双边谱,再乘 Hann 的相干增益 0.5)。
	# 不除掉这个系数的话,满量程正弦算出来是 +42dB 而不是 0dB,
	# 稍微响一点的内容就全部顶到白色,整张图糊成一块。
	var amp_norm := 4.0 / float(fft_size)
	var pow_norm := amp_norm * amp_norm

	for c in cols:
		var t: float = lerpf(t0, t1, (float(c) + 0.5) / float(cols))
		var center := int(t * rate)
		var start := center - half

		for i in fft_size:
			var idx := start + i
			var v := 0.0
			if idx >= 0 and idx < frames:
				v = src.sample(idx)
			_re[i] = v * win[i]
			_im[i] = 0.0
		CueFFT.forward(_re, _im)

		for r in rows:
			var peak := 0.0
			for b in range(row_lo[r], row_hi[r]):
				var m := _re[b] * _re[b] + _im[b] * _im[b]
				if m > peak:
					peak = m
			# 功率 → 分贝 → 0..1。10*log10(power) 省掉一次 sqrt。
			var db := 10.0 * log(maxf(peak * pow_norm, 1e-12)) / log(10.0)
			var norm: float = clampf((db + DB_RANGE) / DB_RANGE, 0.0, 1.0)
			img.set_pixel(c, rows - 1 - r, Color(norm, 0.0, 0.0))

		if c % COLS_PER_SLICE == COLS_PER_SLICE - 1:
			progress.emit(float(c + 1) / float(cols))
			await Engine.get_main_loop().process_frame

	progress.emit(1.0)
	return img


## 把单通道强度图上成彩色。[param low] / [param mid] / [param high]
## 由调用方从编辑器主题取,这里不硬编码任何颜色。
static func colorize(gray: Image, low: Color, mid: Color, high: Color) -> ImageTexture:
	var w := gray.get_width()
	var h := gray.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var v := gray.get_pixel(x, y).r
			var col := low.lerp(mid, v / 0.6) if v < 0.6 else mid.lerp(high, (v - 0.6) / 0.4)
			out.set_pixel(x, y, col)
	return ImageTexture.create_from_image(out)
