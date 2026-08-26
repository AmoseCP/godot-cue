extends SceneTree

## FFT 正确性 + 性能实测。频谱图的设计要照实测数字来,不能照猜的。

func _init() -> void:
	_correctness()
	_bench()
	quit()


func _correctness() -> void:
	print("=== 正确性 ===")
	var n := 64
	# 纯正弦,频率正好落在第 8 个 bin 上 → 能量应该集中在 bin 8
	var re := PackedFloat32Array(); re.resize(n)
	var im := PackedFloat32Array(); im.resize(n)
	for i in n:
		re[i] = sin(TAU * 8.0 * float(i) / float(n))
	CueFFT.forward(re, im)
	var mag := CueFFT.magnitudes(re, im)
	var peak := 0
	for i in mag.size():
		if mag[i] > mag[peak]:
			peak = i
	print("  正弦 8 周期 → 峰值 bin = ", peak, "(应为 8),幅度 = %.1f" % mag[peak])

	# 直流
	var re2 := PackedFloat32Array(); re2.resize(n)
	var im2 := PackedFloat32Array(); im2.resize(n)
	for i in n:
		re2[i] = 1.0
	CueFFT.forward(re2, im2)
	var m2 := CueFFT.magnitudes(re2, im2)
	print("  全 1 → bin0 = %.1f(应为 %d),bin1 = %.4f(应为 0)" % [m2[0], n, m2[1]])

	# 冲激 → 全频段平坦
	var re3 := PackedFloat32Array(); re3.resize(n)
	var im3 := PackedFloat32Array(); im3.resize(n)
	re3[0] = 1.0
	CueFFT.forward(re3, im3)
	var m3 := CueFFT.magnitudes(re3, im3)
	var flat := true
	for v in m3:
		if absf(v - 1.0) > 1e-4:
			flat = false
	print("  冲激 → 平坦谱: ", flat)


func _bench() -> void:
	print("=== 性能 ===")
	for n in [256, 512, 1024]:
		var re := PackedFloat32Array(); re.resize(n)
		var im := PackedFloat32Array(); im.resize(n)
		for i in n:
			re[i] = sin(float(i) * 0.1)
		# 预热,让旋转因子表建好
		CueFFT.forward(re.duplicate(), im.duplicate())

		var reps := 500
		var t0 := Time.get_ticks_msec()
		for r in reps:
			var a := re.duplicate()
			var b := im.duplicate()
			CueFFT.forward(a, b)
		var dt := Time.get_ticks_msec() - t0
		print("  %d 点 × %d 次 = %d ms(每次 %.3f ms → 1 秒能算 %d 列)"
			% [n, reps, dt, float(dt) / float(reps), int(float(reps) * 1000.0 / maxf(float(dt), 1.0))])
