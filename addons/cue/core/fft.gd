@tool
class_name CueFFT

## 迭代式 radix-2 Cooley-Tukey FFT,给频谱图用。
##
## 旋转因子和位反转下标按尺寸缓存 —— 一次 STFT 要跑几百次同尺寸的 FFT,
## 每次重算这两张表比 FFT 本身还贵。

## size → 位反转下标表
static var _rev: Dictionary = {}
## size → [cos 表, sin 表]
static var _tw: Dictionary = {}
## size → Hann 窗
static var _win: Dictionary = {}


static func is_pow2(n: int) -> bool:
	return n > 0 and (n & (n - 1)) == 0


static func _bit_reverse_table(n: int) -> PackedInt32Array:
	if _rev.has(n):
		return _rev[n]
	var bits := 0
	while (1 << bits) < n:
		bits += 1
	var t := PackedInt32Array()
	t.resize(n)
	for i in n:
		var r := 0
		var x := i
		for b in bits:
			r = (r << 1) | (x & 1)
			x >>= 1
		t[i] = r
	_rev[n] = t
	return t


static func _twiddles(n: int) -> Array:
	if _tw.has(n):
		return _tw[n]
	var c := PackedFloat32Array()
	var s := PackedFloat32Array()
	c.resize(n / 2)
	s.resize(n / 2)
	for i in n / 2:
		var a := -TAU * float(i) / float(n)
		c[i] = cos(a)
		s[i] = sin(a)
	var pair := [c, s]
	_tw[n] = pair
	return pair


## Hann 窗。不加窗的话每一帧的两端断口会在频谱上糊成一片。
static func hann(n: int) -> PackedFloat32Array:
	if _win.has(n):
		return _win[n]
	var w := PackedFloat32Array()
	w.resize(n)
	for i in n:
		w[i] = 0.5 - 0.5 * cos(TAU * float(i) / float(n - 1))
	_win[n] = w
	return w


## 原地正变换。[param re] / [param im] 长度必须是同一个 2 的幂。
static func forward(re: PackedFloat32Array, im: PackedFloat32Array) -> void:
	var n := re.size()
	if n < 2 or not is_pow2(n):
		push_error("Cue:FFT 长度必须是 2 的幂,得到 %d。" % n)
		return

	var rev := _bit_reverse_table(n)
	for i in n:
		var j: int = rev[i]
		if j > i:
			var tr := re[i]; re[i] = re[j]; re[j] = tr
			var ti := im[i]; im[i] = im[j]; im[j] = ti

	var tw: Array = _twiddles(n)
	var cos_t: PackedFloat32Array = tw[0]
	var sin_t: PackedFloat32Array = tw[1]

	var size := 2
	while size <= n:
		var half := size >> 1
		var step := n / size
		var i := 0
		while i < n:
			var k := 0
			for j in half:
				var a := i + j
				var b := a + half
				var wr: float = cos_t[k]
				var wi: float = sin_t[k]
				var xr: float = re[b] * wr - im[b] * wi
				var xi: float = re[b] * wi + im[b] * wr
				re[b] = re[a] - xr
				im[b] = im[a] - xi
				re[a] += xr
				im[a] += xi
				k += step
			i += size
		size <<= 1


## 幅度谱,只取前 n/2 个 bin(实信号的另一半是镜像)。
static func magnitudes(re: PackedFloat32Array, im: PackedFloat32Array) -> PackedFloat32Array:
	var half := re.size() / 2
	var out := PackedFloat32Array()
	out.resize(half)
	for i in half:
		out[i] = sqrt(re[i] * re[i] + im[i] * im[i])
	return out
