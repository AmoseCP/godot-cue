extends SceneTree

## FFT 与频谱图(P2)的测试。
##   godot --headless --path . --script tests/test_spectrogram.gd

var _pass := 0
var _fail := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_fft_correctness()
	_test_fft_edge_cases()
	_test_window()
	await _test_spectrogram()
	await _test_spectrogram_perf()
	_test_colorize()
	print("\n=== %d 通过 / %d 失败 ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func ok(c: bool, w: String) -> void:
	if c: _pass += 1; print("  PASS  ", w)
	else: _fail += 1; print("  FAIL  ", w)

func eq(a: Variant, b: Variant, w: String) -> void:
	ok(a == b, "%s (得到 %s,期望 %s)" % [w, a, b])

func near(a: float, b: float, tol: float, w: String) -> void:
	ok(absf(a - b) <= tol, "%s (得到 %.4f,期望 %.4f)" % [w, a, b])


func _peak_bin(mag: PackedFloat32Array) -> int:
	var p := 0
	for i in mag.size():
		if mag[i] > mag[p]:
			p = i
	return p


func _fft_of(fn: Callable, n: int) -> PackedFloat32Array:
	var re := PackedFloat32Array(); re.resize(n)
	var im := PackedFloat32Array(); im.resize(n)
	for i in n:
		re[i] = fn.call(i)
	CueFFT.forward(re, im)
	return CueFFT.magnitudes(re, im)


func _test_fft_correctness() -> void:
	print("\n[FFT] 正确性")
	var n := 128
	# 正好落在 bin 上的正弦 → 能量集中在那一个 bin
	for k in [1, 5, 16, 40]:
		var mag := _fft_of(func(i: int) -> float:
			return sin(TAU * float(k) * float(i) / float(n)), n)
		eq(_peak_bin(mag), k, "%d 周期正弦 → 峰值落在 bin %d" % [k, k])

	# 直流
	var dc := _fft_of(func(_i: int) -> float: return 1.0, n)
	near(dc[0], float(n), 1e-3, "全 1 → bin0 = N")
	near(dc[1], 0.0, 1e-3, "全 1 → bin1 = 0")

	# 冲激 → 平坦谱
	var imp := _fft_of(func(i: int) -> float: return 1.0 if i == 0 else 0.0, n)
	var flat := true
	for v in imp:
		if absf(v - 1.0) > 1e-4:
			flat = false
	ok(flat, "冲激 → 全频段平坦")

	# 两个频率叠加 → 两个峰
	var two := _fft_of(func(i: int) -> float:
		return sin(TAU * 8.0 * float(i) / float(n)) + sin(TAU * 30.0 * float(i) / float(n)), n)
	ok(two[8] > two[9] * 3.0 and two[30] > two[29] * 3.0, "两个频率各自形成尖峰")
	ok(absf(two[8] - two[30]) < two[8] * 0.1, "等幅两音的峰值也相当")


func _test_fft_edge_cases() -> void:
	print("\n[FFT] 边界")
	ok(CueFFT.is_pow2(2) and CueFFT.is_pow2(1024), "2 的幂判定")
	ok(not CueFFT.is_pow2(0) and not CueFFT.is_pow2(3) and not CueFFT.is_pow2(1000),
		"非 2 的幂判定")

	# 全零输入不能出 NaN
	var z := _fft_of(func(_i: int) -> float: return 0.0, 64)
	var clean := true
	for v in z:
		if is_nan(v) or v != 0.0:
			clean = false
	ok(clean, "全零输入 → 全零输出,无 NaN")

	# 表有缓存:同尺寸重复变换结果必须一致
	var a := _fft_of(func(i: int) -> float: return sin(float(i)), 256)
	var b := _fft_of(func(i: int) -> float: return sin(float(i)), 256)
	var same := true
	for i in a.size():
		if absf(a[i] - b[i]) > 1e-6:
			same = false
	ok(same, "重复变换结果完全一致(旋转因子表缓存没写坏)")


func _test_window() -> void:
	print("\n[FFT] Hann 窗")
	var w := CueFFT.hann(64)
	eq(w.size(), 64, "长度")
	near(w[0], 0.0, 1e-6, "两端为 0")
	near(w[63], 0.0, 1e-6, "两端为 0")
	near(w[32], 1.0, 0.01, "中间接近 1")
	var sym := true
	for i in 32:
		if absf(w[i] - w[63 - i]) > 1e-5:
			sym = false
	ok(sym, "对称")


## 造一段已知频率的音源。
func _tone_source(hz: float, dur: float, rate: int = 44100) -> CuePcmReader.Source:
	var n := int(rate * dur)
	var bytes := PackedByteArray(); bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, int(sin(TAU * hz * float(i) / float(rate)) * 20000.0))
	var s := CuePcmReader.Source.new()
	s.bytes = bytes; s.bits = 16; s.channels = 1
	s.mix_rate = rate; s.frame_count = n
	return s


func _test_spectrogram() -> void:
	print("\n[频谱图] 生成")
	var src := _tone_source(1000.0, 1.0)
	var spec := CueSpectrogram.new()
	var img: Image = await spec.build_async(src, 0.0, 1.0, 64, 96)
	ok(img != null, "生成成功")
	if img == null:
		return
	eq(img.get_width(), 64, "宽 = 列数")
	eq(img.get_height(), 96, "高 = 行数")

	# 1kHz 的能量应当集中在某一行,而且每一列都在同一行
	var rows_hit: Array[int] = []
	for c in [8, 24, 40, 56]:
		var best := 0
		var bv := -1.0
		for r in 96:
			var v := img.get_pixel(c, r).r
			if v > bv:
				bv = v
				best = r
		rows_hit.append(best)
		ok(bv > 0.5, "第 %d 列有明确的能量峰(%.2f)" % [c, bv])
	var consistent := true
	for r in rows_hit:
		if absf(float(r) - float(rows_hit[0])) > 1.0:
			consistent = false
	ok(consistent, "稳态音在各列落在同一行:%s" % [rows_hit])

	# 低频音应该落在更靠下的行(第 0 行在图像底部 = 低频)
	var low_src := _tone_source(200.0, 1.0)
	var low_img: Image = await CueSpectrogram.new().build_async(low_src, 0.0, 1.0, 16, 96)
	var low_row := 0
	var lv := -1.0
	for r in 96:
		var v := low_img.get_pixel(8, r).r
		if v > lv:
			lv = v
			low_row = r
	ok(low_row > rows_hit[0],
		"200Hz 画在 1000Hz 下方(行号 %d > %d,行号大 = 靠近图像底部)" % [low_row, rows_hit[0]])

	# 静音 → 全部压到底
	var silent := CuePcmReader.Source.new()
	silent.bytes = PackedByteArray(); silent.bytes.resize(44100 * 2)
	silent.bits = 16; silent.channels = 1; silent.mix_rate = 44100
	silent.frame_count = 44100
	var s_img: Image = await CueSpectrogram.new().build_async(silent, 0.0, 1.0, 8, 32)
	var maxv := 0.0
	for c in 8:
		for r in 32:
			maxv = maxf(maxv, s_img.get_pixel(c, r).r)
	ok(maxv < 0.05, "静音的频谱几乎全黑(最大 %.3f)" % maxv)

	# 坏参数
	ok(await CueSpectrogram.new().build_async(src, 0.0, 1.0, 0, 96) == null, "列数为 0 → null")
	ok(await CueSpectrogram.new().build_async(src, 1.0, 0.0, 8, 96) == null, "时间倒序 → null")
	ok(await CueSpectrogram.new().build_async(src, 0.0, 1.0, 8, 96, 100) == null,
		"FFT 长度不是 2 的幂 → null")


func _test_spectrogram_perf() -> void:
	print("\n[频谱图] 性能:一屏必须在人能接受的时间内算完")
	var src := _tone_source(440.0, 5.0)
	var t0 := Time.get_ticks_msec()
	var img: Image = await CueSpectrogram.new().build_async(src, 0.0, 5.0, 480, 96)
	var dt := Time.get_ticks_msec() - t0
	ok(img != null, "480 列生成成功")
	print("        480 列 × 96 行 = %d ms" % dt)
	# 是分块 await 的,所以这里的墙钟时间含帧等待;放宽到 2 秒
	ok(dt < 2000, "480 列耗时 %dms < 2000ms" % dt)


func _test_colorize() -> void:
	print("\n[频谱图] 上色")
	var g := Image.create(4, 2, false, Image.FORMAT_RF)
	g.set_pixel(0, 0, Color(0.0, 0, 0))
	g.set_pixel(1, 0, Color(0.6, 0, 0))
	g.set_pixel(2, 0, Color(1.0, 0, 0))
	var tex := CueSpectrogram.colorize(g, Color.BLACK, Color.RED, Color.WHITE)
	ok(tex != null, "上色返回贴图")
	var out := tex.get_image()
	eq(out.get_width(), 4, "宽度保持")
	ok(out.get_pixel(0, 0).is_equal_approx(Color.BLACK), "0 → 低色")
	ok(out.get_pixel(1, 0).r > 0.9 and out.get_pixel(1, 0).b < 0.1, "0.6 → 中色")
	ok(out.get_pixel(2, 0).is_equal_approx(Color.WHITE), "1 → 高色")
