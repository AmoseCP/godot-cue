extends SceneTree

## 轨道泳道几何与折叠状态的测试。
## 轨道头和波形视图读的是同一份几何,所以这里测的是"两边不会错位"的根基。
##   godot --headless --path . --script tests/test_lanes.gd

const ViewState := preload("res://addons/cue/editor/cue_view_state.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	_test_track_names()
	_test_lane_geometry()
	_test_collapse()
	_test_lane_at()
	_test_headers_and_view_agree()
	print("\n=== %d 通过 / %d 失败 ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func ok(c: bool, w: String) -> void:
	if c: _pass += 1; print("  PASS  ", w)
	else: _fail += 1; print("  FAIL  ", w)

func eq(a: Variant, b: Variant, w: String) -> void:
	ok(a == b, "%s (得到 %s,期望 %s)" % [w, a, b])

func near(a: float, b: float, w: String) -> void:
	ok(absf(a - b) < 1e-5, "%s (得到 %.3f,期望 %.3f)" % [w, a, b])


func _sheet() -> CueSheet:
	var s := CueSheet.new()
	s.tracks = [
		CueTrack.new(&"dialogue", Color.RED),
		CueTrack.new(&"mouth", Color.GREEN),
	]
	s.add_marker(CueMarker.new(&"a", 1.0, &"dialogue"))
	s.add_marker(CueMarker.new(&"b", 2.0, &"mouth"))
	s.add_marker(CueMarker.new(&"c", 3.0, &"mouth"))
	# 一条只在标记里出现、没有声明 CueTrack 的轨道
	s.add_marker(CueMarker.new(&"d", 4.0, &"sfx"))
	return s


func _test_track_names() -> void:
	print("\n[轨道] 有序并集")
	var s := _sheet()
	var names := s.track_names()
	eq(Array(names), [&"dialogue", &"mouth", &"sfx"],
		"声明过的按声明顺序在前,未声明的补在后面")
	eq(s.count_in_track(&"mouth"), 2, "mouth 轨标记数")
	eq(s.count_in_track(&"dialogue"), 1, "dialogue 轨标记数")
	eq(s.count_in_track(&"没有这条"), 0, "不存在的轨返回 0")

	var empty := CueSheet.new()
	eq(Array(empty.track_names()), [&"dialogue"], "空 sheet 也给一条默认轨")

	# 重复声明不该产生重复泳道
	var dup := CueSheet.new()
	dup.tracks = [CueTrack.new(&"x", Color.RED), CueTrack.new(&"x", Color.BLUE)]
	eq(dup.track_names().size(), 1, "同名轨道只出现一次")


func _test_lane_geometry() -> void:
	print("\n[泳道] 高度与偏移")
	var st := ViewState.new()
	st.sheet = _sheet()
	var H: float = ViewState.LANE_H
	var C: float = ViewState.LANE_H_COLLAPSED

	near(st.lanes_height(), H * 3.0, "三条全展开的总高")
	near(st.lane_top(0), 0.0, "第 0 条顶部")
	near(st.lane_top(1), H, "第 1 条顶部")
	near(st.lane_top(2), H * 2.0, "第 2 条顶部")
	near(st.lane_top(3), H * 3.0, "越界索引给到末尾(等于总高)")

	st.set_collapsed(&"mouth", true)
	near(st.lane_height(&"mouth"), C, "折叠后的行高")
	near(st.lane_height(&"dialogue"), H, "别的轨不受影响")
	near(st.lanes_height(), H * 2.0 + C, "总高随之缩小")
	near(st.lane_top(2), H + C, "折叠会把后面的轨道往上顶")


func _test_collapse() -> void:
	print("\n[泳道] 折叠状态")
	var st := ViewState.new()
	st.sheet = _sheet()
	var fired: Array[int] = [0]
	st.lanes_changed.connect(func() -> void: fired[0] += 1)

	ok(not st.is_collapsed(&"mouth"), "默认展开")
	st.set_collapsed(&"mouth", true)
	ok(st.is_collapsed(&"mouth"), "折叠生效")
	eq(fired[0], 1, "发了一次 lanes_changed")

	st.set_collapsed(&"mouth", true)
	eq(fired[0], 1, "重复设成同一个值不重复发信号")

	st.toggle_collapsed(&"mouth")
	ok(not st.is_collapsed(&"mouth"), "toggle 切回展开")

	st.set_all_collapsed(true)
	ok(st.is_collapsed(&"dialogue") and st.is_collapsed(&"mouth") and st.is_collapsed(&"sfx"),
		"折叠全部")
	st.set_all_collapsed(false)
	ok(not st.is_collapsed(&"sfx"), "展开全部")

	# 折叠状态不能污染资源 —— 它是视图状态
	ok(not (&"collapsed" in CueTrack.new()), "CueTrack 上没有 collapsed 字段")


func _test_lane_at() -> void:
	print("\n[泳道] 命中测试")
	var st := ViewState.new()
	st.sheet = _sheet()
	var H: float = ViewState.LANE_H

	eq(String(st.lane_at(0.0)), "dialogue", "顶端落在第 0 条")
	eq(String(st.lane_at(H - 0.1)), "dialogue", "第 0 条底边之内")
	eq(String(st.lane_at(H)), "mouth", "正好是第 1 条的顶边")
	eq(String(st.lane_at(H * 2.5)), "sfx", "第 2 条中间")
	eq(String(st.lane_at(H * 3.0 + 5.0)), "", "泳道区之下不属于任何轨")
	eq(String(st.lane_at(-5.0)), "", "负坐标不属于任何轨")

	st.set_collapsed(&"dialogue", true)
	eq(String(st.lane_at(ViewState.LANE_H_COLLAPSED + 1.0)), "mouth",
		"折叠第 0 条后,第 1 条上移")


func _test_headers_and_view_agree() -> void:
	print("\n[泳道] 轨道头与波形视图几何一致")
	var st := ViewState.new()
	st.sheet = _sheet()
	st.set_collapsed(&"mouth", true)

	# 轨道头逐行累加出来的 y,必须和 lane_top() 给的一致 ——
	# 两边错位就会出现"点第 1 条却折叠了第 2 条"
	var names := st.track_list()
	var y := 0.0
	var agree := true
	for i in names.size():
		if absf(y - st.lane_top(i)) > 1e-5:
			agree = false
		# 每条泳道正中间做一次反查,必须回到自己
		if st.lane_at(y + st.lane_height(names[i]) * 0.5) != names[i]:
			agree = false
		y += st.lane_height(names[i])
	ok(agree, "逐行累加 == lane_top(),且 lane_at() 能反查回来")
	near(y, st.lanes_height(), "累加总高 == lanes_height()")
