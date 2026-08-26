extends SceneTree

## 规模验证:一集真实体量的数据下,面板还能不能用。
##   godot --headless --path . --script tests/test_scale.gd
##
## M1 的性能数字是单片段 + 少量标记测出来的。真实一集是
## 多角色分轨 + 口型轨几千个标记,这里按那个体量重测一遍。

const WAV_5MIN := "res://tests/probe/tone_5min.wav"

## 一集的量级:4 段音频(4 个角色),2000 个标记(主要是口型)
const SEGMENTS := 4
const MOUTH_MARKERS := 1800
const DIALOGUE_MARKERS := 120
const WORD_MARKERS := 400

var _pass := 0
var _fail := 0


func _init() -> void:
	var sheet := _build()
	_test_sort(sheet)
	_test_lookup(sheet)
	_test_draw(sheet)
	_test_subtitles(sheet)
	_test_export(sheet)
	print("\n=== %d 通过 / %d 失败 ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func ok(c: bool, w: String) -> void:
	if c: _pass += 1; print("  PASS  ", w)
	else: _fail += 1; print("  FAIL  ", w)


func budget(ms: int, limit: int, what: String) -> void:
	ok(ms <= limit, "%s:%dms(上限 %dms)" % [what, ms, limit])


func _build() -> CueSheet:
	print("\n[规模] 构造一集体量的数据")
	var src := CuePcmReader.read_wav_file(WAV_5MIN)
	var wf := CueWaveformBuilder.new().build(src, 256)

	var sheet := CueSheet.new()
	sheet.fps = 30
	var segs: Array[CueAudioSegment] = []
	for i in SEGMENTS:
		var s := CueAudioSegment.new(StringName("角色%d" % i), WAV_5MIN, float(i) * 60.0)
		s.waveform = wf                      # 共用同一份,只测查询/绘制开销
		segs.append(s)
	sheet.segments = segs

	sheet.tracks = [
		CueTrack.new(&"dialogue", Color.SKY_BLUE),
		CueTrack.new(&"mouth", Color.ORANGE),
		CueTrack.new(&"words", Color.LIGHT_GREEN),
	]

	var dur := sheet.duration()
	for i in MOUTH_MARKERS:
		var m := CueMarker.new(StringName("m_%04d" % i), float(i) / float(MOUTH_MARKERS) * dur, &"mouth")
		m.payload = {"shape": "ABCDEFGHX"[i % 9], "end": float(i + 1) / float(MOUTH_MARKERS) * dur}
		sheet.add_marker(m)
	for i in DIALOGUE_MARKERS:
		sheet.add_marker(CueMarker.new(StringName("line_%03d" % i),
			float(i) / float(DIALOGUE_MARKERS) * dur, &"dialogue"))
	for i in WORD_MARKERS:
		var w := CueMarker.new(StringName("w_%04d" % i),
			float(i) / float(WORD_MARKERS) * dur, &"words")
		w.payload = {"text": "词%d" % i, "end": float(i + 1) / float(WORD_MARKERS) * dur}
		sheet.add_marker(w)

	print("        %d 段音频 · %d 个标记 · %d 条轨 · 总长 %.0fs"
		% [sheet.segment_count(), sheet.markers.size(), sheet.track_names().size(), dur])
	return sheet


func _test_sort(sheet: CueSheet) -> void:
	print("\n[规模] 排序与缓存")
	sheet.invalidate()
	var t0 := Time.get_ticks_msec()
	var s := sheet.sorted()
	var first := Time.get_ticks_msec() - t0
	ok(s.size() == sheet.markers.size(), "排序结果条数正确")
	budget(first, 60, "首次排序 %d 个标记" % s.size())

	t0 = Time.get_ticks_msec()
	for i in 100:
		sheet.sorted()
	var cached := Time.get_ticks_msec() - t0
	budget(cached, 5, "缓存命中 100 次")


func _test_lookup(sheet: CueSheet) -> void:
	print("\n[规模] 查找")
	var t0 := Time.get_ticks_msec()
	for i in 200:
		sheet.find(StringName("m_%04d" % (i * 9)))
	budget(Time.get_ticks_msec() - t0, 200, "find() 200 次")

	# in_track 是绘制热路径上调用最频繁的一个
	t0 = Time.get_ticks_msec()
	for i in 60:
		sheet.in_track(&"mouth")
	var dt := Time.get_ticks_msec() - t0
	budget(dt, 200, "in_track() 60 次(相当于 60 帧,每帧一次)")

	t0 = Time.get_ticks_msec()
	for i in 60:
		sheet.segment_at(float(i))
	budget(Time.get_ticks_msec() - t0, 20, "segment_at() 60 次")


func _test_draw(sheet: CueSheet) -> void:
	print("\n[规模] 绘制热路径")
	var state := CueViewState.new()
	state.sheet = sheet
	state.view_width = 1920.0
	var view := CueWaveformView.new()
	view.setup(state)
	view.size = Vector2(1920, 320)

	# 整段视野:所有标记都在屏幕上,最坏情况
	state.px_per_sec = 1920.0 / sheet.duration()
	state.scroll_sec = 0.0
	var t0 := Time.get_ticks_msec()
	for i in 30:
		view.call("_rebuild_lines")
	var whole := Time.get_ticks_msec() - t0
	budget(whole / 30, 20, "整段视野下每帧线段重建")

	# 放大到 5 秒/屏
	state.px_per_sec = 1920.0 / 5.0
	state.scroll_sec = 100.0
	t0 = Time.get_ticks_msec()
	for i in 30:
		view.call("_rebuild_lines")
	budget((Time.get_ticks_msec() - t0) / 30, 20, "5 秒/屏下每帧线段重建")

	# _draw_markers 走的是 in_track,每条轨一次;这里模拟 60 帧
	t0 = Time.get_ticks_msec()
	for f in 60:
		for tn in sheet.track_names():
			var arr := sheet.in_track(tn)
			var n := arr.size()      # 防止被优化掉
	var marker_draw := Time.get_ticks_msec() - t0
	budget(marker_draw / 60, 16, "每帧遍历全部轨道的标记(60fps 预算 16ms)")
	view.free()


func _test_subtitles(sheet: CueSheet) -> void:
	print("\n[规模] 字幕条")
	var t0 := Time.get_ticks_msec()
	for f in 60:
		for tn in sheet.text_tracks():
			sheet.text_at(float(f) * 0.5, tn)
	budget(Time.get_ticks_msec() - t0, 100, "字幕条 60 帧")


func _test_export(sheet: CueSheet) -> void:
	print("\n[规模] 导出与生成")
	var t0 := Time.get_ticks_msec()
	var js := CueMarkerExport.to_json(sheet)
	budget(Time.get_ticks_msec() - t0, 500, "导出 %d 个标记为 JSON(%d KB)"
		% [sheet.markers.size(), js.length() / 1024])

	t0 = Time.get_ticks_msec()
	CueMarkerExport.to_csv(sheet)
	budget(Time.get_ticks_msec() - t0, 500, "导出 CSV")

	t0 = Time.get_ticks_msec()
	var opts := CueScriptGenerator.Options.new()
	opts.tracks = PackedStringArray(["dialogue"])
	var gd := CueScriptGenerator.generate(sheet, opts)
	budget(Time.get_ticks_msec() - t0, 300, "生成剧本骨架(仅 dialogue 轨)")
	ok(gd.count("await Cue.at(") == DIALOGUE_MARKERS, "剧本里的 await 条数正确")
