@tool
class_name CueWaveformView extends Control

## 波形 + 轨道泳道 + 播放头的绘制与交互。
##
## 布局:上方是每条轨道一条泳道(可折叠),下方是波形。
## 标记画在自己的泳道里,同时向下引一条淡淡的辅助线穿过波形,
## 方便把标记对到具体的音上。
##
## 泳道几何全部从 [CueViewState] 读,和左侧 [CueTrackHeaders] 共用一份数字。
##
## 性能纪律:[method _draw] 里不做逐采样循环,也不分配新数组。
## 每列的线段坐标预先算好存在 [member _wave_lines] 里,视图变化时才重建。

signal marker_add_requested(time: float)
signal marker_delete_requested(marker: CueMarker)
signal marker_move_requested(marker: CueMarker, from_time: float, to_time: float)
signal marker_rename_requested(marker: CueMarker)
signal marker_selected(marker: CueMarker)
signal seek_requested(time: float)

const MARKER_HIT_PX := 7.0
const MARKER_LABEL_PAD := 5.0

var state: CueViewState = null

var _wave_lines: PackedVector2Array = PackedVector2Array()
var _lines_dirty: bool = true
var _selected: CueMarker = null
var _drag_marker: CueMarker = null
var _drag_from_time: float = 0.0
var _panning: bool = false

# 主题色。全部取自编辑器主题,不硬编码(见 CLAUDE.md 编辑器插件纪律)。
var _c_bg: Color = Color(0.12, 0.12, 0.14)
var _c_lane: Color = Color(0.16, 0.16, 0.19)
var _c_lane_alt: Color = Color(0.18, 0.18, 0.21)
var _c_wave: Color = Color(0.45, 0.62, 0.85)
var _c_mid: Color = Color(1, 1, 1, 0.12)
var _c_marker: Color = Color(1.0, 0.75, 0.2)
var _c_selected: Color = Color(1.0, 0.95, 0.5)
var _c_playhead: Color = Color(1.0, 0.35, 0.35)
var _c_text: Color = Color(0.9, 0.9, 0.9)
var _font: Font = null
var _font_size: int = 12


func setup(p_state: CueViewState) -> void:
	state = p_state
	state.view_changed.connect(_on_view_changed)
	state.sheet_changed.connect(_on_view_changed)
	state.lanes_changed.connect(_on_view_changed)
	state.playhead_moved.connect(queue_redraw)


func _ready() -> void:
	focus_mode = Control.FOCUS_CLICK
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_pull_theme()
	resized.connect(_on_resized)


func _pull_theme() -> void:
	if not Engine.is_editor_hint():
		return
	var t := EditorInterface.get_editor_theme()
	if t == null:
		return
	_c_bg = t.get_color("dark_color_2", "Editor")
	_c_lane = t.get_color("dark_color_1", "Editor")
	_c_lane_alt = t.get_color("dark_color_3", "Editor")
	_c_wave = t.get_color("accent_color", "Editor")
	_c_text = t.get_color("font_color", "Editor")
	_c_mid = Color(_c_text, 0.12)
	_c_marker = t.get_color("warning_color", "Editor")
	_c_selected = t.get_color("property_color_z", "Editor")
	_c_playhead = t.get_color("error_color", "Editor")
	# 4.7.2 实测:编辑器主题里没有 ("font", "Editor"),
	# 正确的键是 ("main", "EditorFonts") / ("main_size", "EditorFonts")。
	_font = t.get_font("main", "EditorFonts")
	_font_size = t.get_font_size("main_size", "EditorFonts")


func selected_marker() -> CueMarker:
	return _selected


func select(m: CueMarker) -> void:
	_selected = m
	marker_selected.emit(m)
	queue_redraw()


func _on_resized() -> void:
	if state != null:
		state.view_width = size.x
	_lines_dirty = true
	queue_redraw()


func _on_view_changed() -> void:
	_lines_dirty = true
	queue_redraw()


# ── 几何 ────────────────────────────────────────────────────────────

## 泳道区总高。超过控件一半就截断 —— 轨道很多时不能把波形挤没了。
func _lanes_h() -> float:
	if state == null:
		return 0.0
	return minf(state.lanes_height(), size.y * 0.6)


func _wave_top() -> float:
	return _lanes_h()


func _wave_height() -> float:
	return maxf(size.y - _wave_top(), 1.0)


func _wave_center_y() -> float:
	return _wave_top() + _wave_height() * 0.5


# ── 绘制 ────────────────────────────────────────────────────────────

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _c_bg)
	if state == null or state.sheet == null:
		_draw_hint("把一个 CueSheet 拖到这里,或在文件系统中双击 .tres 打开")
		return

	_draw_lane_bands()

	var wf := state.sheet.waveform
	if wf == null or not wf.is_valid():
		_draw_hint("这个 CueSheet 还没有波形缓存 —— 点工具栏的「分析波形」")
	else:
		if _lines_dirty:
			_rebuild_lines(wf)
		var mid := _wave_center_y()
		draw_line(Vector2(0, mid), Vector2(size.x, mid), _c_mid, 1.0)
		if _wave_lines.size() >= 2:
			draw_multiline(_wave_lines, _c_wave, 1.0)

	_draw_markers()
	_draw_playhead()


## 泳道底色,深浅交替,方便一眼分清是哪一条。
func _draw_lane_bands() -> void:
	var names := state.track_list()
	var y := 0.0
	var limit := _lanes_h()
	for i in names.size():
		var h := state.lane_height(names[i])
		if y >= limit:
			break
		var hh: float = minf(h, limit - y)
		draw_rect(Rect2(0.0, y, size.x, hh), _c_lane_alt if i % 2 else _c_lane)
		y += h
	if limit > 0.0:
		draw_line(Vector2(0, limit), Vector2(size.x, limit), _c_mid, 1.0)


## 每个像素列一条竖线,坐标一次性算好。一列覆盖的 bucket 数随缩放变化:
## 拉远时一列聚合很多 bucket(取包络的并集),拉近时若干列共用一个 bucket。
func _rebuild_lines(wf: WaveformCache) -> void:
	_lines_dirty = false
	var w := int(size.x)
	var pts := PackedVector2Array()
	if w <= 0 or wf.bucket_count() == 0:
		_wave_lines = pts
		return

	var spb := wf.seconds_per_bucket()
	if spb <= 0.0:
		_wave_lines = pts
		return

	var half := _wave_height() * 0.5
	var mid := _wave_center_y()
	var n := wf.bucket_count()
	var mins := wf.mins
	var maxs := wf.maxs

	pts.resize(w * 2)
	var used := 0
	for x in w:
		var t0 := state.x_to_time(float(x))
		var t1 := state.x_to_time(float(x) + 1.0)
		var b0 := int(floor(t0 / spb))
		var b1 := int(ceil(t1 / spb))
		if b1 <= b0:
			b1 = b0 + 1
		b0 = maxi(b0, 0)
		b1 = mini(b1, n)
		if b0 >= n or b1 <= 0:
			continue
		var lo := 1.0
		var hi := -1.0
		for b in range(b0, b1):
			var mn: float = mins[b]
			var mx: float = maxs[b]
			if mn < lo: lo = mn
			if mx > hi: hi = mx
		if hi < lo:
			continue
		var fx := float(x) + 0.5
		pts[used] = Vector2(fx, mid - hi * half)
		pts[used + 1] = Vector2(fx, mid - lo * half)
		used += 2
	pts.resize(used)
	_wave_lines = pts


func _draw_markers() -> void:
	var sheet := state.sheet
	var names := state.track_list()
	var limit := _lanes_h()
	var bottom := size.y

	for i in names.size():
		var tname := names[i]
		var top := state.lane_top(i)
		if top >= limit:
			break
		var h := state.lane_height(tname)
		var collapsed := state.is_collapsed(tname)
		var base := sheet.track_color(tname, _c_marker)

		for m in sheet.in_track(tname):
			var x := state.time_to_x(m.time)
			if x < -120.0 or x > size.x + 120.0:
				continue
			var is_sel := m == _selected
			var col := _c_selected if is_sel else base

			# 向下的辅助线,穿过波形,用来把标记对到具体的音上
			draw_line(Vector2(x, top + h), Vector2(x, bottom),
				Color(col, 0.9 if is_sel else 0.35), 2.0 if is_sel else 1.0)

			if collapsed:
				# 折叠时只留一个细刻度,仍然看得出标记密度
				draw_rect(Rect2(x - 1.0, top + 1.0, 2.0, h - 2.0), col)
				continue

			# 泳道里的抓取块
			draw_rect(Rect2(x - 1.0, top + 1.0, 2.0, h - 2.0), col)
			var tri := PackedVector2Array([
				Vector2(x - 5.0, top + 1.0),
				Vector2(x + 5.0, top + 1.0),
				Vector2(x, top + 9.0),
			])
			draw_colored_polygon(tri, col)
			if _font != null and m.name != &"":
				draw_string(_font, Vector2(x + MARKER_LABEL_PAD, top + h - 5.0),
					String(m.name), HORIZONTAL_ALIGNMENT_LEFT, -1,
					maxi(_font_size - 1, 8), col)


func _draw_playhead() -> void:
	var x := state.time_to_x(state.playhead)
	if x < -2.0 or x > size.x + 2.0:
		return
	draw_line(Vector2(x, 0), Vector2(x, size.y), _c_playhead, 1.0)


func _draw_hint(msg: String) -> void:
	if _font == null:
		return
	var w := _font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x
	draw_string(_font, Vector2((size.x - w) * 0.5, size.y * 0.5),
		msg, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, Color(_c_text, 0.5))


# ── 交互 ────────────────────────────────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if state == null or state.sheet == null:
		return

	if event is InputEventMouseButton:
		_handle_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_motion(event as InputEventMouseMotion)
	elif event is InputEventKey and (event as InputEventKey).pressed:
		_handle_key(event as InputEventKey)


func _handle_button(e: InputEventMouseButton) -> void:
	match e.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if e.pressed:
				state.zoom_at(1.15 if not e.ctrl_pressed else 1.4, e.position.x)
				accept_event()
		MOUSE_BUTTON_WHEEL_DOWN:
			if e.pressed:
				state.zoom_at(1.0 / (1.15 if not e.ctrl_pressed else 1.4), e.position.x)
				accept_event()
		MOUSE_BUTTON_MIDDLE:
			_panning = e.pressed
			accept_event()
		MOUSE_BUTTON_LEFT:
			if e.pressed:
				_press(e)
			else:
				_release()
			accept_event()


## 泳道区里点 = 操作标记;波形区里点 = 移动播放头。
## 分开之后就没有"到底是想选标记还是想定位"的歧义了。
func _press(e: InputEventMouseButton) -> void:
	grab_focus()
	if e.position.y >= _lanes_h():
		select(null)
		seek_requested.emit(state.maybe_snap(state.x_to_time(e.position.x)))
		return

	var lane := state.lane_at(e.position.y)
	if lane != &"":
		state.set_active_track(lane)
	var hit := _marker_at(e.position)
	if hit == null:
		select(null)
		seek_requested.emit(state.maybe_snap(state.x_to_time(e.position.x)))
		return
	select(hit)
	if e.double_click:
		marker_rename_requested.emit(hit)
	else:
		_drag_marker = hit
		_drag_from_time = hit.time


func _release() -> void:
	if _drag_marker == null:
		return
	var to_t := _drag_marker.time
	# 拖动过程中直接改了 time,这里先还原,再让 undo 系统把它设回去,
	# 这样撤销栈里存的是一次完整的移动,而不是几十次微调。
	if not is_equal_approx(to_t, _drag_from_time):
		_drag_marker.time = _drag_from_time
		marker_move_requested.emit(_drag_marker, _drag_from_time, to_t)
	_drag_marker = null


func _handle_motion(e: InputEventMouseMotion) -> void:
	if _panning or (e.button_mask & MOUSE_BUTTON_MASK_MIDDLE) != 0:
		state.pan_pixels(e.relative.x)
		accept_event()
		return
	if _drag_marker != null:
		# 拖动只改时间,不换轨 —— 换轨是另一回事,不该靠手抖触发
		var t: float = clampf(state.x_to_time(e.position.x), 0.0, maxf(state.duration(), 0.0))
		if e.ctrl_pressed or state.snap_to_frame:
			t = state.sheet.snap(t)
		_drag_marker.time = t
		state.notify_sheet_edited()
		queue_redraw()
		accept_event()


func _handle_key(e: InputEventKey) -> void:
	match e.keycode:
		KEY_M:
			marker_add_requested.emit(state.maybe_snap(state.playhead))
			accept_event()
		KEY_DELETE, KEY_BACKSPACE:
			if _selected != null:
				marker_delete_requested.emit(_selected)
				accept_event()
		KEY_F2:
			if _selected != null:
				marker_rename_requested.emit(_selected)
				accept_event()


## 只在鼠标所在的那条泳道里找 —— 不同轨上时间相近的标记
## (口型轨尤其密)才不会互相抢点击。
func _marker_at(pos: Vector2) -> CueMarker:
	var lane := state.lane_at(pos.y)
	if lane == &"":
		return null
	var best: CueMarker = null
	var best_d := MARKER_HIT_PX
	for m in state.sheet.in_track(lane):
		var d: float = absf(state.time_to_x(m.time) - pos.x)
		if d <= best_d:
			best_d = d
			best = m
	return best
