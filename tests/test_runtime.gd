extends SceneTree

## 运行时 API(Cue / CueClock)的 headless 测试。
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runtime.gd
##
## 强制走 Movie 模式(帧计数时钟),这样时间完全由帧数决定,测试本身也是确定性的。
##
## 注意:GDScript 的 lambda [b]按值[/b]捕获局部变量(4.7.2 实测),
## 所以协程里回传状态必须用 Array/Dictionary 这类引用类型,不能用 bool。

const CueScript := preload("res://addons/cue/runtime/cue.gd")

var _pass := 0
var _fail := 0
var _cue: Node = null


func _init() -> void:
	root.call_deferred("add_child", _make_cue())
	_run.call_deferred()


func _make_cue() -> Node:
	_cue = CueScript.new()
	_cue.name = "Cue"
	return _cue


func _run() -> void:
	CueClock.force_mode = 1          # 强制帧计数时钟
	await process_frame

	await _test_clock()
	await _test_at_ordering()
	await _test_missing_marker_no_deadlock()
	await _test_past_marker_returns_now()
	await _test_stop_wakes_awaiters()
	await _test_window_and_phonemes()
	await _test_dense_markers_same_frame()
	await _test_mouth_shape()
	await _test_mouth_shape_payload()
	await _test_mouth_shape_amplitude()
	await _test_multi_segment()
	await _test_render_fps_calibration()
	await _test_seek_during_await()
	await _test_seek_forward_releases_skipped()
	await _test_await_before_play_and_while_paused()
	await _test_mouth_auto_rebuild()
	await _test_after_and_pause_then_stop()
	await _test_freed_target_node()
	await _test_play_resume()

	print("\n=== %d 通过 / %d 失败 ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


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
	ok(absf(a - b) <= tol, "%s (得到 %.5f,期望 %.5f ±%.5f)" % [what, a, b, tol])


func _sheet(times: Array, fps: int = 30) -> CueSheet:
	var s := CueSheet.new()
	s.fps = fps
	for e in times:
		var m := CueMarker.new(e[0], e[1], e[2] if e.size() > 2 else &"dialogue")
		if e.size() > 3:
			m.payload = e[3]
		s.add_marker(m)
	# 没有音频时 duration() 靠 waveform,这里手搓一个只带时长的缓存。
	# audio_path 随手给一个 —— 否则 validate() 会为"片段既没 path 也没 stream"
	# 报错刷屏,那是合理的告警,不该靠削弱校验来消音。
	s.audio_path = "res://tests/probe/tone_1s.wav"
	var w := WaveformCache.new()
	w.mins = PackedFloat32Array([0.0]); w.maxs = PackedFloat32Array([0.0])
	w.mix_rate = 44100; w.duration = 10.0
	s.waveform = w
	return s


## 推进 n 帧。Movie 模式下 1 帧 = 1/fps 秒,时间完全可预测。
## (CueClock 数的是 Engine.get_process_frames(),headless 下也会推进。)
func _advance(n: int) -> void:
	for i in n:
		await process_frame


# ── CueClock ────────────────────────────────────────────────────────

func _test_clock() -> void:
	print("\n[CueClock] 帧计数时钟")
	var c := CueClock.new(30.0, null)
	ok(c.is_movie_mode(), "force_mode=1 时进入 Movie 模式")
	c.start(0.0)
	var f0 := Engine.get_process_frames()
	await _advance(6)
	var elapsed := Engine.get_process_frames() - f0
	var expect := float(elapsed) / 30.0
	ok(absf(c.now() - expect) < 1e-6,
		"时间 = 帧数/fps(走了 %d 帧,now=%.6f,期望 %.6f)" % [elapsed, c.now(), expect])

	# 同样的帧数必须给同样的时间 —— 这是离线渲染可复现的根本
	var c2 := CueClock.new(30.0, null)
	c2.start(0.0)
	var a := c2.now()
	var b := c2.now()
	ok(a == b, "同一帧内连续读取返回同一个值(%f)" % a)

	c.stop()
	var frozen := c.now()
	await _advance(3)
	ok(c.now() == frozen, "stop() 之后时间冻结")
	c.resume()
	await _advance(2)
	ok(c.now() > frozen, "resume() 之后继续走")

	var c3 := CueClock.new(30.0, null)
	ok(c3.frame_of(0.0) == 0, "frame_of(0)=0")
	ok(c3.frame_of(1.0) == 30, "frame_of(1.0)=30")
	ok(c3.frame_of(0.999) == 29, "frame_of(0.999)=29(向下取整)")

	CueClock.force_mode = 0
	ok(not CueClock.detect_movie_mode(), "force_mode=0 时强制实时模式")
	CueClock.force_mode = 1


# ── Cue.at() ────────────────────────────────────────────────────────

func _test_at_ordering() -> void:
	print("\n[Cue] at() 按时间顺序触发")
	_cue.load_sheet(_sheet([[&"a", 0.1], [&"b", 0.25], [&"c", 0.4]]))
	var order: Array[String] = []
	var done: Array[bool] = [false]        # 按值捕获,用数组回传

	var task := func() -> void:
		await _cue.at(&"a"); order.append("a")
		await _cue.at(&"b"); order.append("b")
		await _cue.at(&"c"); order.append("c")
		done[0] = true
	task.call()

	_cue.play(0.0)
	for i in 40:
		await process_frame
		if done[0]:
			break
	ok(done[0], "三个标记都触发了")
	ok(order == ["a", "b", "c"], "触发顺序 %s" % [order])
	_cue.stop()


func _test_missing_marker_no_deadlock() -> void:
	print("\n[Cue] at() 对不存在的标记不死锁(M4 验收项)")
	_cue.load_sheet(_sheet([[&"real", 0.1]]))
	_cue.play(0.0)
	var returned: Array[bool] = [false]
	var task := func() -> void:
		await _cue.at(&"根本没有这个标记")
		returned[0] = true
	task.call()
	# 不推进帧也应该已经返回了 —— at() 找不到标记时是同步返回的
	ok(returned[0], "立即返回,没有挂起")
	_cue.stop()


func _test_past_marker_returns_now() -> void:
	print("\n[Cue] at() 对已经过去的标记立即返回")
	_cue.load_sheet(_sheet([[&"early", 0.05], [&"late", 5.0]]))
	_cue.play(2.0)            # 从 2 秒开始,early 已经过去
	var returned: Array[bool] = [false]
	var task := func() -> void:
		await _cue.at(&"early")
		returned[0] = true
	task.call()
	ok(returned[0], "已过去的标记立即返回")
	_cue.stop()


func _test_stop_wakes_awaiters() -> void:
	print("\n[Cue] stop() 唤醒还挂着的 at()")
	_cue.load_sheet(_sheet([[&"far", 9.0]]))
	_cue.play(0.0)
	var returned: Array[bool] = [false]
	var task := func() -> void:
		await _cue.at(&"far")
		returned[0] = true
	task.call()
	await _advance(3)
	ok(not returned[0], "标记还没到,协程仍在等待")
	_cue.stop()
	await _advance(2)
	ok(returned[0], "stop() 之后协程被唤醒,不会永远挂着")


func _test_window_and_phonemes() -> void:
	print("\n[Cue] window() 与 phonemes()")
	_cue.load_sheet(_sheet([
		[&"w1", 1.0, &"dialogue"],
		[&"m1", 1.2, &"mouth", {"phonemes": [{"t": 0.0, "shape": "A"}, {"t": 0.1, "shape": "E"}]}],
		[&"w2", 2.5, &"dialogue"],
		[&"m2", 3.0, &"mouth"],
	]))
	var w: Dictionary = _cue.window(&"w1")
	ok(w["start"] == 1.0, "window.start = 标记自己的时间")
	ok(w["end"] == 2.5, "window.end = 同轨下一个标记(得到 %s)" % w["end"])
	var w2: Dictionary = _cue.window(&"m2")
	ok(w2["end"] == 10.0, "同轨没有下一个时 end = 音频总长(得到 %s)" % w2["end"])

	var ph: Array = _cue.phonemes(&"m1")
	ok(ph.size() == 2, "读到 2 个音素")
	ok(ph[0]["shape"] == "A", "第一个音素是 A")
	ok(_cue.phonemes(&"w1").is_empty(), "没有 payload 的标记返回空数组")
	ok(_cue.phonemes(&"不存在").is_empty(), "标记不存在时返回空数组而不是崩溃")
	ok(_cue.markers_in(&"mouth").size() == 2, "markers_in 按轨过滤")


func _test_dense_markers_same_frame() -> void:
	print("\n[Cue] 一帧内跨过多个标记时全部补发")
	# 30fps 下一帧是 33ms;这四个标记挤在 10ms 内,必然同帧
	_cue.load_sheet(_sheet([[&"p0", 0.200], [&"p1", 0.203],
			[&"p2", 0.206], [&"p3", 0.209]]))
	var seen: Array[String] = []
	_cue.marker_reached.connect(func(n: StringName) -> void:
		if n != &"":
			seen.append(String(n)))
	_cue.play(0.0)
	await _advance(15)
	_cue.stop()
	ok(seen.size() == 4, "四个密集标记全部触发(得到 %d 个:%s)" % [seen.size(), seen])
	ok(seen == ["p0", "p1", "p2", "p3"], "补发顺序与时间顺序一致")


# ── CueMouthShape ───────────────────────────────────────────────────

func _mouth_sheet() -> CueSheet:
	# 一条 mouth 轨:X 闭嘴 → B → C → A → X
	return _sheet([
		[&"m0", 0.10, &"mouth", {"shape": "X"}],
		[&"m1", 0.25, &"mouth", {"shape": "B"}],
		[&"m2", 0.40, &"mouth", {"shape": "C"}],
		[&"m3", 0.70, &"mouth", {"shape": "A"}],
		[&"m4", 1.00, &"mouth", {"shape": "X"}],
		[&"line", 0.05, &"dialogue"],
	])


func _test_mouth_shape() -> void:
	print("\n[CueMouthShape] 从轨道读口型")
	_cue.load_sheet(_mouth_sheet())
	var mouth := CueMouthShape.new()
	mouth.cue_path = _cue.get_path()
	mouth.track = &"mouth"
	mouth.rest_shape = &"X"
	root.add_child(mouth)
	await process_frame
	mouth.rebuild()

	ok(mouth.entry_count() == 5, "抓到 5 条口型(得到 %d)" % mouth.entry_count())
	eq(String(mouth.shape_at(0.0)), "X", "序列开始前是静止嘴型")
	eq(String(mouth.shape_at(0.09)), "X", "第一条之前仍是静止")
	eq(String(mouth.shape_at(0.10)), "X", "正好踩在第一条上")
	eq(String(mouth.shape_at(0.25)), "B", "正好踩在 B 上")
	eq(String(mouth.shape_at(0.30)), "B", "两条之间保持前一个")
	eq(String(mouth.shape_at(0.399)), "B", "边界前一刻还是 B")
	eq(String(mouth.shape_at(0.40)), "C", "边界这一刻切到 C")
	eq(String(mouth.shape_at(0.85)), "A", "区间中段")
	eq(String(mouth.shape_at(99.0)), "X", "超出末尾保持最后一个")

	# 纯函数:反复问同一个 t 必须给同样的答案
	var stable := true
	for i in 50:
		if mouth.shape_at(0.517) != &"C":
			stable = false
	ok(stable, "shape_at() 是纯函数,重复调用结果稳定")

	# 只在真正变化时才发信号
	var fired: Array[String] = []
	mouth.shape_changed.connect(func(sh: StringName) -> void: fired.append(String(sh)))
	_cue.play(0.0)
	await _advance(40)
	_cue.stop()
	ok(fired.size() >= 3, "播放过程中切换了 %d 次嘴型:%s" % [fired.size(), fired])
	var no_repeat := true
	for i in range(1, fired.size()):
		if fired[i] == fired[i - 1]:
			no_repeat = false
	ok(no_repeat, "同一个嘴型不会连发两次")
	mouth.queue_free()


func _test_mouth_shape_payload() -> void:
	print("\n[CueMouthShape] 从标记 payload 读口型序列")
	var sheet := _sheet([
		[&"line_1", 1.00, &"dialogue", {"phonemes": [
			{"t": 0.00, "shape": "B"},
			{"t": 0.20, "shape": "E"},
			{"t": 0.45, "shape": "X"},
		]}],
	])
	_cue.load_sheet(sheet)
	var mouth := CueMouthShape.new()
	mouth.cue_path = _cue.get_path()
	mouth.source = CueMouthShape.Source.MARKER_PAYLOAD
	mouth.marker = &"line_1"
	root.add_child(mouth)
	await process_frame
	mouth.rebuild()

	eq(mouth.entry_count(), 3, "抓到 3 条")
	# payload 里的 t 是相对宿主标记的,所以要加上宿主时间 1.0
	eq(String(mouth.shape_at(0.5)), "X", "宿主标记之前是静止嘴型")
	eq(String(mouth.shape_at(1.00)), "B", "宿主时间点 → 第一个音素")
	eq(String(mouth.shape_at(1.10)), "B", "还在第一个音素区间内")
	eq(String(mouth.shape_at(1.20)), "E", "偏移 0.20 → E")
	eq(String(mouth.shape_at(1.45)), "X", "偏移 0.45 → 闭嘴")

	# 同时间平局必须按嘴型代号排,保证全序(确定性)
	var tie := _sheet([
		[&"h", 0.5, &"dialogue", {"phonemes": [
			{"t": 0.1, "shape": "F"}, {"t": 0.1, "shape": "A"},
		]}],
	])
	_cue.load_sheet(tie)
	var m2 := CueMouthShape.new()
	m2.cue_path = _cue.get_path()
	m2.source = CueMouthShape.Source.MARKER_PAYLOAD
	m2.marker = &"h"
	root.add_child(m2)
	await process_frame
	m2.rebuild()
	var first := m2.shape_at(0.6)
	var same := true
	for i in 20:
		m2.rebuild()
		if m2.shape_at(0.6) != first:
			same = false
	ok(same, "同时间的两个音素,排序结果每次都一样(全序)")
	mouth.queue_free()
	m2.queue_free()


func _test_mouth_shape_amplitude() -> void:
	print("\n[CueMouthShape] 响度驱动的降级模式")
	var sheet := _sheet([[&"x", 0.0]])
	var env := CueEnvelope.new()
	env.rate = 10.0
	env.duration = 0.5
	# 0 → 0.10 → 0.25 → 0.50 → 0.90:正好跨过三个阈值的四个档
	env.values = PackedFloat32Array([0.0, 0.10, 0.25, 0.50, 0.90])
	sheet.envelope = env
	_cue.load_sheet(sheet)

	near(_cue.amplitude(0.0), 0.0, 1e-6, "Cue.amplitude() 读到静音")
	near(_cue.amplitude(0.4), 0.90, 1e-6, "Cue.amplitude() 读到峰值")
	near(_cue.amplitude(0.05), 0.05, 1e-6, "Cue.amplitude() 会插值")

	var mouth := CueMouthShape.new()
	mouth.cue_path = _cue.get_path()
	mouth.source = CueMouthShape.Source.AMPLITUDE
	mouth.amplitude_shapes = [&"X", &"B", &"C", &"D"]
	mouth.amplitude_thresholds = PackedFloat32Array([0.06, 0.18, 0.38])
	root.add_child(mouth)
	await process_frame
	mouth.rebuild()

	ok(mouth.is_ready(), "有包络时视为就绪")
	eq(String(mouth.shape_at(0.0)), "X", "静音 → 闭嘴")
	eq(String(mouth.shape_at(0.1)), "B", "小声 → 微张")
	eq(String(mouth.shape_at(0.2)), "C", "中等 → 张开")
	eq(String(mouth.shape_at(0.3)), "D", "大声 → 全开")
	eq(String(mouth.shape_at(0.4)), "D", "更大声仍是最高档")

	# 纯函数 —— 响度模式不预展开序列,直接查包络,同样必须稳定
	var stable := true
	for i in 30:
		if mouth.shape_at(0.23) != &"C":
			stable = false
	ok(stable, "响度模式的 shape_at() 也是纯函数")

	# 档位比嘴型少时不能越界
	mouth.amplitude_shapes = [&"X", &"B"]
	eq(String(mouth.shape_at(0.4)), "B", "嘴型不够时取最后一个,不越界")

	# 没有包络时要报错但不崩
	var no_env := _sheet([[&"y", 0.0]])
	_cue.load_sheet(no_env)
	var m2 := CueMouthShape.new()
	m2.cue_path = _cue.get_path()
	m2.source = CueMouthShape.Source.AMPLITUDE
	root.add_child(m2)
	await process_frame
	m2.rebuild()
	ok(not m2.is_ready(), "没有包络时 is_ready() 为 false")
	eq(String(m2.shape_at(0.5)), "X", "没有包络时退回静止嘴型,不崩溃")
	mouth.queue_free()
	m2.queue_free()


func _test_multi_segment() -> void:
	print("\n[Cue] 多音频片段:标记跨片段统一触发")
	var sheet := CueSheet.new()
	sheet.fps = 30
	var a := CueAudioSegment.new(&"peter", "", 0.0)
	var wa := WaveformCache.new()
	wa.mins = PackedFloat32Array([-0.5]); wa.maxs = PackedFloat32Array([0.5])
	wa.mix_rate = 44100; wa.duration = 1.0
	a.waveform = wa
	var b := CueAudioSegment.new(&"john", "", 2.0)
	var wb := WaveformCache.new()
	wb.mins = PackedFloat32Array([-0.5]); wb.maxs = PackedFloat32Array([0.5])
	wb.mix_rate = 44100; wb.duration = 1.0
	b.waveform = wb
	sheet.segments = [a, b] as Array[CueAudioSegment]
	# 三个标记:第一段里、空隙里、第二段里
	sheet.add_marker(CueMarker.new(&"in_a", 0.4))
	sheet.add_marker(CueMarker.new(&"in_gap", 1.5))
	sheet.add_marker(CueMarker.new(&"in_b", 2.4))

	near(sheet.duration(), 3.0, 1e-6, "总时长跨两段")
	_cue.load_sheet(sheet)

	var order: Array[String] = []
	var done: Array[bool] = [false]
	var task := func() -> void:
		await _cue.at(&"in_a"); order.append("a")
		await _cue.at(&"in_gap"); order.append("gap")
		await _cue.at(&"in_b"); order.append("b")
		done[0] = true
	task.call()

	_cue.play(0.0)
	for i in 120:
		await process_frame
		if done[0]:
			break
	ok(done[0], "三个标记全部触发")
	ok(order == ["a", "gap", "b"], "跨片段顺序正确:%s" % [order])

	# window() 也跨片段
	var w: Dictionary = _cue.window(&"in_gap")
	near(float(w["start"]), 1.5, 1e-6, "空隙里的标记 window.start")
	near(float(w["end"]), 2.4, 1e-6, "window.end 是下一个标记,与片段边界无关")
	var wl: Dictionary = _cue.window(&"in_b")
	near(float(wl["end"]), 3.0, 1e-6, "最后一个标记 window.end = 整条时间轴总长")
	_cue.stop()

	# 从第二段中间起播
	_cue.play(2.2)
	await _advance(2)
	ok(_cue.time() >= 2.2, "从第二段中间起播,时间正确(%.3f)" % _cue.time())
	_cue.stop()


func _test_render_fps_calibration() -> void:
	print("\n[CueClock] 用实际渲染帧率校准离线时钟")
	# sheet 说 30fps,但影片按 60fps 录 —— 不校准的话时间会走快一倍
	# 反推本身是纯函数,可以脱离运行环境测
	near(CueClock.fps_from_delta(1.0 / 60.0), 60.0, 1e-6, "1/60 → 60fps")
	near(CueClock.fps_from_delta(1.0 / 30.0), 30.0, 1e-6, "1/30 → 30fps")
	near(CueClock.fps_from_delta(1.0 / 24.0), 24.0, 1e-6, "1/24 → 24fps")
	near(CueClock.fps_from_delta(0.0), 0.0, 1e-6, "delta 为 0 → 0(不可用)")
	near(CueClock.fps_from_delta(-1.0), 0.0, 1e-6, "负 delta → 0")
	near(CueClock.fps_from_delta(2.0), 0.0, 1e-6, "delta 大于 1 秒 → 0(不可信)")

	var c := CueClock.new(30.0, null)
	eq(c.render_fps(), 30.0, "还没测到时用 sheet 的 fps")

	# 关键守卫:不是真在录影片时,observe_delta 必须什么都不做。
	# headless 下帧率不受限,delta 是真实耗时,反推出来是上万的"帧率",
	# 照单全收会让时钟直接停摆(这条是踩过之后补的)。
	c.observe_delta(1.0 / 6000.0)
	eq(c.render_fps(), 30.0, "非录制环境下忽略 delta,不会被离谱的帧率污染")

	# 校准生效之后时间按实际帧率走 —— 直接设内部值来验这一段
	var c3 := CueClock.new(30.0, null)
	c3.set("_render_fps", 60.0)
	eq(c3.render_fps(), 60.0, "校准后的帧率")
	c3.start(0.0)
	var f0 := Engine.get_process_frames()
	await _advance(6)
	var elapsed := Engine.get_process_frames() - f0
	near(c3.now(), float(elapsed) / 60.0, 1e-6,
		"走了 %d 帧 → %.4fs(按 60fps 而不是 30fps)" % [elapsed, c3.now()])


func _test_seek_during_await() -> void:
	print("\n[Cue] 播放中 seek 不能把挂着的 at() 打断")
	# 分镜脚本挂在 at() 上时,用户完全可能去拖播放头 / 跳到某个节拍。
	# 如果 seek 把所有 await 唤醒并返回,整段脚本会在 seek 之后静默崩掉。
	_cue.load_sheet(_sheet([[&"a", 0.20], [&"b", 0.60], [&"c", 1.00]]))

	var order: Array[String] = []
	var done: Array[bool] = [false]
	var task := func() -> void:
		await _cue.at(&"a"); order.append("a")
		await _cue.at(&"b"); order.append("b")
		await _cue.at(&"c"); order.append("c")
		done[0] = true
	task.call()

	_cue.play(0.0)
	# 等 a 触发
	for i in 40:
		await process_frame
		if order.size() >= 1:
			break
	ok(order == ["a"], "a 已触发,协程正挂在 b 上:%s" % [order])

	# 关键动作:此刻往回 seek。b、c 都还在未来,协程应当继续等
	_cue.seek(0.30)
	await _advance(3)
	ok(order == ["a"], "seek 之后没有假触发:%s" % [order])
	ok(_cue.is_playing(), "seek 之后仍在播放")

	for i in 80:
		await process_frame
		if done[0]:
			break
	ok(done[0], "seek 之后 b、c 仍能正常触发")
	ok(order == ["a", "b", "c"], "顺序完整:%s" % [order])
	_cue.stop()


func _test_seek_forward_releases_skipped() -> void:
	print("\n[Cue] 向前 seek 跳过的标记要放行等待者")
	_cue.load_sheet(_sheet([[&"p", 0.20], [&"q", 0.50], [&"r", 2.00]]))
	var order: Array[String] = []
	var done: Array[bool] = [false]
	var task := func() -> void:
		await _cue.at(&"p"); order.append("p")
		await _cue.at(&"q"); order.append("q")
		await _cue.at(&"r"); order.append("r")
		done[0] = true
	task.call()

	_cue.play(0.0)
	await _advance(2)
	# p、q 都还没到就直接跳到 1.0 —— 它们已经"过去"了,
	# 按 at() 的既有规则(标记时间已过 → 立即返回)应当放行
	_cue.seek(1.0)
	await _advance(4)
	ok(order == ["p", "q"], "跳过的 p、q 被放行:%s" % [order])
	ok(not done[0], "r 还在未来,仍然挂着")

	for i in 80:
		await process_frame
		if done[0]:
			break
	ok(done[0], "r 到点后正常触发")
	_cue.stop()


func _test_await_before_play_and_while_paused() -> void:
	print("\n[Cue] play() 之前 / 暂停期间 await 都不能立即返回")
	# 这两种情况下 _playing 都是 false。曾经拿它当 at() 的循环条件,
	# 于是「先起协程再 play()」会让整段分镜在一帧里跑完。
	_cue.load_sheet(_sheet([[&"one", 0.30], [&"two", 0.80]]))

	var order: Array[String] = []
	var task := func() -> void:
		await _cue.at(&"one"); order.append("one")
		await _cue.at(&"two"); order.append("two")
	task.call()                      # 注意:play() 还没调
	ok(order.is_empty(), "play() 之前起的协程仍在等待:%s" % [order])

	_cue.play(0.0)
	for i in 40:
		await process_frame
		if order.size() >= 1:
			break
	ok(order == ["one"], "第一个标记正常触发:%s" % [order])

	# 暂停期间新起一个 await,同样不能立刻返回
	_cue.pause()
	var late: Array[String] = []
	var late_task := func() -> void:
		await _cue.at(&"two"); late.append("two")
	late_task.call()
	await _advance(3)
	ok(late.is_empty(), "暂停期间起的 await 仍在等待:%s" % [late])
	ok(order == ["one"], "暂停期间原协程也没有被误唤醒")

	_cue.resume()
	for i in 60:
		await process_frame
		if late.size() >= 1:
			break
	ok(late == ["two"], "恢复播放后触发:%s" % [late])
	ok(order == ["one", "two"], "原协程也走完:%s" % [order])
	_cue.stop()

	# stop() 仍然必须放行,否则协程永远挂着
	_cue.load_sheet(_sheet([[&"far", 9.0]]))
	var freed: Array[bool] = [false]
	var t2 := func() -> void:
		await _cue.at(&"far")
		freed[0] = true
	t2.call()
	_cue.play(0.0)
	await _advance(2)
	ok(not freed[0], "标记还远,挂着")
	_cue.stop()
	await _advance(2)
	ok(freed[0], "stop() 之后放行")


func _test_mouth_auto_rebuild() -> void:
	print("\n[CueMouthShape] 换 sheet 自动重建")
	_cue.load_sheet(_mouth_sheet())
	var mouth := CueMouthShape.new()
	mouth.cue_path = _cue.get_path()
	mouth.track = &"mouth"
	root.add_child(mouth)
	await process_frame
	eq(mouth.entry_count(), 5, "初始抓到 5 条")

	# 换一个口型条数不同的 sheet —— 不手动 rebuild()
	var other := _sheet([
		[&"x1", 0.1, &"mouth", {"shape": "B"}],
		[&"x2", 0.2, &"mouth", {"shape": "C"}],
	])
	_cue.load_sheet(other)
	await process_frame
	eq(mouth.entry_count(), 2, "换 sheet 后自动重建成 2 条(没有手动调 rebuild)")
	eq(String(mouth.shape_at(0.15)), "B", "新数据生效")

	# 节点移除后不该再被信号牵连
	mouth.queue_free()
	await process_frame
	await process_frame
	_cue.load_sheet(_mouth_sheet())
	await process_frame
	ok(true, "节点释放后再换 sheet 不报错(信号已断开)")


func _test_after_and_pause_then_stop() -> void:
	print("\n[Cue] after() 与「先暂停再停止」")
	# 上一轮只改了 at(),after() 里同样有 while _playing。
	# 同一类错误在别处再找一遍 —— 这次是延迟期间暂停。
	_cue.load_sheet(_sheet([[&"beat", 0.20]]))
	var hit: Array[bool] = [false]
	var t1 := func() -> void:
		await _cue.after(&"beat", 0.50)
		hit[0] = true
	t1.call()

	_cue.play(0.0)
	# 等 beat 过去,此时正处在 0.5 秒的延迟里
	for i in 20:
		await process_frame
		if _cue.time() > 0.25:
			break
	ok(not hit[0], "beat 已过,正在等 0.5 秒的延迟")

	_cue.pause()
	await _advance(4)
	ok(not hit[0], "延迟期间暂停,不能提前返回")

	_cue.resume()
	for i in 60:
		await process_frame
		if hit[0]:
			break
	ok(hit[0], "恢复后延迟正常走完")
	ok(_cue.time() >= 0.70, "确实等满了(t=%.2f ≥ 0.20+0.50)" % _cue.time())
	_cue.stop()

	# 先 pause() 再 stop():stop() 里 was := _playing 已经是 false,
	# 旧实现会跳过唤醒,挂着的协程永远等不到信号
	_cue.load_sheet(_sheet([[&"far", 9.0]]))
	var freed: Array[bool] = [false]
	var t2 := func() -> void:
		await _cue.at(&"far")
		freed[0] = true
	t2.call()
	_cue.play(0.0)
	await _advance(2)
	_cue.pause()
	await _advance(2)
	ok(not freed[0], "暂停期间仍在等待")
	_cue.stop()
	await _advance(3)
	ok(freed[0], "先暂停再停止,协程仍被放行(不会挂死)")

	# after() 在这一轮作废后也要放行
	_cue.load_sheet(_sheet([[&"g", 0.1]]))
	var freed2: Array[bool] = [false]
	var t3 := func() -> void:
		await _cue.after(&"g", 5.0)
		freed2[0] = true
	t3.call()
	_cue.play(0.0)
	for i in 20:
		await process_frame
		if _cue.time() > 0.2:
			break
	ok(not freed2[0], "正在等 5 秒延迟")
	_cue.stop()
	await _advance(3)
	ok(freed2[0], "stop() 也能放行卡在 after() 延迟里的协程")

func _test_freed_target_node() -> void:
	print("\n[CueMouthShape] 目标节点被释放之后")
	# 角色下场、场景切换,目标 Sprite 被 free 掉是很正常的事。
	# 被 free 的 Node [b]不是 null[/b],是失效实例 —— 用 `== null` 判断挡不住,
	# 访问它会报错,而 _apply() 报错会让它后面的 shape_changed.emit() 不执行。
	# 所以"信号还发不发"正好能测出这个 bug。
	_cue.load_sheet(_mouth_sheet())
	var sprite := Sprite2D.new()
	root.add_child(sprite)

	var mouth := CueMouthShape.new()
	mouth.cue_path = _cue.get_path()
	mouth.track = &"mouth"
	mouth.sprite = sprite
	mouth.shape_textures = {
		&"X": PlaceholderTexture2D.new(),
		&"B": PlaceholderTexture2D.new(),
		&"C": PlaceholderTexture2D.new(),
		&"A": PlaceholderTexture2D.new(),
	}
	root.add_child(mouth)
	await process_frame

	var fired: Array[String] = []
	mouth.shape_changed.connect(func(sh: StringName) -> void: fired.append(String(sh)))

	# 先正常跑一段,确认信号本来是会发的
	_cue.play(0.0)
	await _advance(10)
	var before := fired.size()
	ok(before > 0, "释放之前 shape_changed 正常发出(%d 次)" % before)

	# 把目标节点释放掉,继续播
	sprite.free()
	await _advance(20)
	ok(fired.size() > before,
		"目标被释放后 shape_changed 仍然发出(%d → %d)—— 说明 _apply() 没有报错中断"
			% [before, fired.size()])
	ok(String(mouth.current_shape()) != "", "当前嘴型仍在更新:%s" % mouth.current_shape())
	_cue.stop()
	mouth.queue_free()
	await process_frame

func _test_play_resume() -> void:
	print("\n[Cue] play() 省略参数时从当前播放头继续")
	# 以前默认值是 0.0,于是 seek(5) 之后 play() 会莫名回到开头 ——
	# 每个媒体播放器都不会这么干。
	var sheet := _sheet([[&"early", 0.10], [&"late", 1.50]])
	_cue.load_sheet(sheet)

	# 刚 load 完播放头在 0,play() 行为不变
	_cue.play()
	await _advance(2)
	ok(_cue.time() < 0.30, "刚 load 完 play() 仍然从 0 开始(%.3f)" % _cue.time())
	_cue.stop()

	# seek 之后 play() 必须从那里继续
	_cue.seek(1.0)
	_cue.play()
	await _advance(2)
	ok(_cue.time() >= 1.0, "seek(1.0) 之后 play() 从 1.0 继续(%.3f)" % _cue.time())
	_cue.stop()

	# 显式传参仍然精确生效
	_cue.play(0.5)
	await _advance(1)
	ok(_cue.time() >= 0.5 and _cue.time() < 0.9,
		"play(0.5) 从 0.5 开始(%.3f)" % _cue.time())
	_cue.stop()

	# 播完之后再 play():不能在结尾原地立刻结束,要从头来
	var dur := sheet.duration()
	ok(dur > 0.0, "这个 sheet 有时长(%.2f)" % dur)
	_cue.seek(dur)
	_cue.play()
	await _advance(2)
	ok(_cue.time() < dur * 0.5,
		"播放头已在末尾时 play() 从头开始(%.3f,总长 %.2f)" % [_cue.time(), dur])
	_cue.stop()

	# 负数当作"从当前位置"
	_cue.seek(0.8)
	_cue.play(-1.0)
	await _advance(1)
	ok(_cue.time() >= 0.8, "play(-1.0) 等同于省略参数(%.3f)" % _cue.time())
	_cue.stop()

	# 剧本骨架生成的是无参 play(),必须还能从头正常跑
	_cue.load_sheet(_sheet([[&"a", 0.1], [&"b", 0.3]]))
	var order: Array[String] = []
	var task := func() -> void:
		await _cue.at(&"a"); order.append("a")
		await _cue.at(&"b"); order.append("b")
	task.call()
	_cue.play()
	for i in 40:
		await process_frame
		if order.size() >= 2:
			break
	ok(order == ["a", "b"], "生成的剧本骨架(load_sheet + play())照常工作:%s" % [order])
	_cue.stop()
