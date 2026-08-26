extends SceneTree

## 波形视图几何的测试。
##
## 这部分以前藏在 Control 里,完全没有覆盖 —— 而它是最容易出错的一类代码:
## 一堆 y 坐标加减,错一像素就变成"点第 1 条却选中了第 2 条"。
##   godot --headless --path . --script tests/test_geometry.gd

const G := preload("res://addons/cue/editor/cue_waveform_geometry.gd")
const ViewState := preload("res://addons/cue/editor/cue_view_state.gd")

const SIZE := Vector2(1000, 300)

var _pass := 0
var _fail := 0


func _init() -> void:
	_test_lane_area()
	_test_segment_bands()
	_test_handle_hit()
	_test_marker_hit()
	_test_area_split()
	print("\n=== %d 通过 / %d 失败 ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func ok(c: bool, w: String) -> void:
	if c: _pass += 1; print("  PASS  ", w)
	else: _fail += 1; print("  FAIL  ", w)

func eq(a: Variant, b: Variant, w: String) -> void:
	ok(a == b, "%s (得到 %s,期望 %s)" % [w, a, b])

func near(a: float, b: float, w: String) -> void:
	ok(absf(a - b) < 1e-4, "%s (得到 %.3f,期望 %.3f)" % [w, a, b])


func _seg(name: StringName, offset: float, length: float) -> CueAudioSegment:
	var s := CueAudioSegment.new(name, "res://fake/%s.wav" % name, offset)
	var w := WaveformCache.new()
	w.mins = PackedFloat32Array([-0.5]); w.maxs = PackedFloat32Array([0.5])
	w.mix_rate = 44100; w.duration = length
	s.waveform = w
	return s


func _state(n_segments: int = 2, n_tracks: int = 3) -> CueViewState:
	var sheet := CueSheet.new()
	sheet.fps = 30
	var segs: Array[CueAudioSegment] = []
	for i in n_segments:
		segs.append(_seg(StringName("s%d" % i), float(i) * 2.0, 4.0))
	sheet.segments = segs
	var names := [&"dialogue", &"mouth", &"sfx"]
	for i in n_tracks:
		sheet.tracks.append(CueTrack.new(names[i], Color.WHITE))
		sheet.add_marker(CueMarker.new(StringName("m%d" % i), 1.0 + float(i), names[i]))
	var st := ViewState.new()
	st.sheet = sheet
	st.view_width = SIZE.x
	st.px_per_sec = 100.0
	st.scroll_sec = 0.0
	return st


func _test_lane_area() -> void:
	print("\n[几何] 泳道区与波形区")
	var st := _state()
	var lanes := G.lanes_height(st, SIZE)
	near(lanes, ViewState.LANE_H * 3.0, "三条轨的泳道区高度")
	near(G.wave_top(st, SIZE), lanes, "波形区从泳道区下方开始")
	near(G.wave_height(st, SIZE), SIZE.y - lanes, "波形区高度 = 剩下的")

	# 轨道极多时不能把波形挤没了
	var many := _state(1, 3)
	for i in 40:
		many.sheet.add_marker(CueMarker.new(StringName("x%d" % i), float(i), StringName("t%d" % i)))
	many.sheet.touch()
	var capped := G.lanes_height(many, SIZE)
	ok(capped <= SIZE.y * G.LANES_MAX_RATIO + 1e-4,
		"泳道区被截断在控件高度的 %.0f%%(得到 %.1f / %.1f)"
			% [G.LANES_MAX_RATIO * 100.0, capped, SIZE.y])
	ok(G.wave_height(many, SIZE) > 0.0, "截断之后波形区仍有高度")

	# 空状态不能崩
	near(G.lanes_height(null, SIZE), 0.0, "state 为 null 时泳道区为 0")


func _test_segment_bands() -> void:
	print("\n[几何] 片段横带")
	var st := _state(2)
	var top := G.wave_top(st, SIZE)
	var b0 := G.segment_band(st, SIZE, 0, 2)
	var b1 := G.segment_band(st, SIZE, 1, 2)
	near(b0.position.y, top, "第 0 段从波形区顶部开始")
	near(b0.size.y, G.wave_height(st, SIZE) / 2.0, "两段平分波形区")
	near(b1.position.y, top + b0.size.y, "第 1 段接在第 0 段下面")
	near(b1.end.y, SIZE.y, "最后一段贴到底")
	near(b0.size.x, SIZE.x, "横带占满宽度")

	# 单段时占满
	var one := G.segment_band(st, SIZE, 0, 1)
	near(one.size.y, G.wave_height(st, SIZE), "只有一段时占满波形区")
	# total 为 0 不能除零
	var zero := G.segment_band(st, SIZE, 0, 0)
	ok(zero.size.y > 0.0, "total 为 0 时不除零(得到 %.1f)" % zero.size.y)

	# 把手高度不能超过带子的一半
	near(G.handle_height(b0), G.SEG_HANDLE_H, "带子够高时把手是固定高度")
	var thin := Rect2(0, 0, 100, 10)
	near(G.handle_height(thin), 5.0, "带子很矮时把手取一半")


func _test_handle_hit() -> void:
	print("\n[几何] 片段把手命中")
	var st := _state(2)
	var b0 := G.segment_band(st, SIZE, 0, 2)
	var h := G.handle_height(b0)

	# 第 0 段 offset=0,长 4 秒,100px/s → x 从 0 到 400
	var inside := Vector2(200.0, b0.position.y + h * 0.5)
	var hit := G.segment_handle_at(st, SIZE, inside)
	ok(hit != null and hit.name == &"s0", "把手正中命中第 0 段")

	ok(G.segment_handle_at(st, SIZE, Vector2(200.0, b0.position.y + h + 5.0)) == null,
		"把手下方(带子内部)不命中 —— 那里是移动播放头")
	ok(G.segment_handle_at(st, SIZE, Vector2(600.0, b0.position.y + 2.0)) == null,
		"超出该段时间范围的横向位置不命中")
	ok(G.segment_handle_at(st, SIZE, Vector2(200.0, 2.0)) == null,
		"泳道区里不命中片段把手")

	# 第 1 段 offset=2s → x 从 200 到 600
	var b1 := G.segment_band(st, SIZE, 1, 2)
	var hit1 := G.segment_handle_at(st, SIZE, Vector2(400.0, b1.position.y + 2.0))
	ok(hit1 != null and hit1.name == &"s1", "第 1 段的把手命中自己")
	# 两段横向重叠(200~400),但纵向分开 —— 不能互相抢
	var hit0 := G.segment_handle_at(st, SIZE, Vector2(300.0, b0.position.y + 2.0))
	ok(hit0 != null and hit0.name == &"s0", "横向重叠区靠纵向区分,不串段")


func _test_marker_hit() -> void:
	print("\n[几何] 标记命中")
	var st := _state(1, 3)
	# m0 在 dialogue 轨(第 0 条泳道)1.0s → x=100
	var lane0_y := ViewState.LANE_H * 0.5
	var m := G.marker_at(st, Vector2(100.0, lane0_y))
	ok(m != null and m.name == &"m0", "泳道正中命中同轨标记")

	ok(G.marker_at(st, Vector2(100.0 + G.MARKER_HIT_PX + 2.0, lane0_y)) == null,
		"超出命中半径不命中")
	ok(G.marker_at(st, Vector2(100.0 + G.MARKER_HIT_PX - 1.0, lane0_y)) != null,
		"命中半径之内命中")

	# m1 在 mouth 轨 2.0s → x=200。在 dialogue 轨的 x=200 处不该命中它
	ok(G.marker_at(st, Vector2(200.0, lane0_y)) == null,
		"别的轨上时间相近的标记不会被抢过来")
	var lane1_y := ViewState.LANE_H * 1.5
	var m1 := G.marker_at(st, Vector2(200.0, lane1_y))
	ok(m1 != null and m1.name == &"m1", "在自己的泳道里命中")

	ok(G.marker_at(st, Vector2(100.0, 250.0)) == null, "波形区里不命中标记")
	ok(G.marker_at(null, Vector2(100.0, lane0_y)) == null, "state 为 null 不崩")


func _test_area_split() -> void:
	print("\n[几何] 泳道区 / 波形区的分界")
	var st := _state()
	var top := G.wave_top(st, SIZE)
	ok(not G.in_wave_area(st, SIZE, Vector2(0, top - 1.0)), "分界线之上属于泳道区")
	ok(G.in_wave_area(st, SIZE, Vector2(0, top)), "分界线本身属于波形区")
	ok(G.in_wave_area(st, SIZE, Vector2(0, SIZE.y - 1.0)), "底部属于波形区")
