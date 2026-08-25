extends SceneTree

func _init() -> void:
	# 直接读源 WAV 文件(绕过导入压缩)
	var f := FileAccess.open("res://tests/probe/tone_5min.wav", FileAccess.READ)
	var t0 := Time.get_ticks_msec()
	var raw := f.get_buffer(f.get_length())
	print("读文件 %d 字节: %d ms" % [raw.size(), Time.get_ticks_msec() - t0])
	var pcm := raw.slice(44)          # 跳过标准 44 字节头
	var n := pcm.size() / 2
	print("采样数 = ", n)

	var buckets := 256

	# 策略 A: 逐采样 decode_s16
	t0 = Time.get_ticks_msec()
	var mn := 0.0; var mx := 0.0
	for i in n:
		var v := pcm.decode_s16(i * 2)
		if v < mn: mn = v
		if v > mx: mx = v
	print("A 逐采样 decode_s16: %d ms  (min=%d max=%d)" % [Time.get_ticks_msec() - t0, mn, mx])

	# 策略 B: to_int32_array 一次转换 + 位提取
	t0 = Time.get_ticks_msec()
	var ints := pcm.to_int32_array()
	var tconv := Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	var mn2 := 0; var mx2 := 0
	for i in ints.size():
		var w: int = ints[i]
		var lo: int = w & 0xFFFF
		if lo > 32767: lo -= 65536
		var hi: int = (w >> 16) & 0xFFFF
		if hi > 32767: hi -= 65536
		if lo < mn2: mn2 = lo
		if lo > mx2: mx2 = lo
		if hi < mn2: mn2 = hi
		if hi > mx2: mx2 = hi
	print("B to_int32_array 转换 %d ms + 位提取 %d ms (min=%d max=%d)" % [tconv, Time.get_ticks_msec() - t0, mn2, mx2])

	# 策略 C: 步进采样(每 bucket 取 64 点)
	t0 = Time.get_ticks_msec()
	var nb := n / buckets
	var step := 4
	var mn3 := 0; var mx3 := 0
	for b in nb:
		var base := b * buckets * 2
		var i := 0
		while i < buckets:
			var v := pcm.decode_s16(base + i * 2)
			if v < mn3: mn3 = v
			if v > mx3: mx3 = v
			i += step
	print("C 步进 1/%d decode_s16: %d ms (min=%d max=%d)" % [step, Time.get_ticks_msec() - t0, mn3, mx3])
	quit()
