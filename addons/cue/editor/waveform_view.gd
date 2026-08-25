@tool
class_name CueWaveformView extends Control

## 波形 + 标记 + 播放头的绘制与交互。
##
## 性能纪律:[method _draw] 里不做逐采样循环,也不分配新数组。
## 每列的线段坐标预先算好存在 [member _wave_lines] 里,视图变化时才重建。

signal marker_add_requested(time: float)
signal marker_delete_requested(marker: CueMarker)
signal marker_move_requested(marker: CueMarker, from_time: float, to_time: float)
signal marker_rename_requested(marker: CueMarker)
signal marker_selected(marker: CueMarker)
signal seek_requested(time: float)

const MARKER_HIT_PX := 6.0
const MARKER_LABEL_PAD := 4.0
const RULER_LANE_H := 16.0

var state: CueViewState = null

var _wave_lines: PackedVector2Array = PackedVector2Array()
var _lines_dirty: bool = true
var _selected: CueMarker = null
var _drag_marker: CueMarker = null
var _drag_from_time: float = 0.0
var _panning: bool = false

# 主题色。全部取自编辑器主题,不硬编码(见 CLAUDE.md 编辑器插件纪律)。
var _c_bg: Color = Color(0.12, 0.12, 0.14)
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


# ── 绘制 ────────────────────────────────────────────────────────────

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _c_bg)
	if state == null or state.sheet == null:
		_draw_hint("把一个 CueSheet 拖到这里,或在文件系统中双击 .tres 打开")
		return

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


func _wave_top() -> float:
	return RULER_LANE_H


func _wave_height() -> float:
	return maxf(size.y - RULER_LANE_H, 1.0)


func _wave_center_y() -> float:
	return _wave_top() + _wave_height() * 0.5


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
	var top := _wave_top()
	var bottom := size.y
	for m in sheet.sorted():
		var x := state.time_to_x(m.time)
		if x < -80.0 or x > size.x + 80.0:
			continue
		var is_sel := m == _selected
		var col := sheet.track_color(m.track, _c_marker)
		if is_sel:
			col = _c_selected
		draw_line(Vector2(x, top), Vector2(x, bottom), col, 2.0 if is_sel else 1.0)
		# 顶部小三角,给拖拽一个明确的抓取点
		var tri := PackedVector2Array([
			Vector2(x - 5, 0), Vector2(x + 5, 0), Vector2(x, top - 2)
		])
		draw_colored_polygon(tri, col)
		if _font != null and m.name != &"":
			draw_string(_font, Vector2(x + MARKER_LABEL_PAD, top + _font_size),
				String(m.name), HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, col)


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
				grab_focus()
				var hit := _marker_at(e.position.x)
				if hit != null:
					select(hit)
					if e.double_click:
						marker_rename_requested.emit(hit)
					else:
						_drag_marker = hit
						_drag_from_time = hit.time
				else:
					select(null)
					seek_requested.emit(state.maybe_snap(state.x_to_time(e.position.x)))
			else:
				if _drag_marker != null:
					var to_t := _drag_marker.time
					# 拖动过程中直接改了 time,这里先还原,再让 undo 系统把它设回去,
					# 这样撤销栈里存的是一次完整的移动,而不是几十次微调。
					if not is_equal_approx(to_t, _drag_from_time):
						_drag_marker.time = _drag_from_time
						marker_move_requested.emit(_drag_marker, _drag_from_time, to_t)
					_drag_marker = null
			accept_event()


func _handle_motion(e: InputEventMouseMotion) -> void:
	if _panning or (e.button_mask & MOUSE_BUTTON_MASK_MIDDLE) != 0:
		state.pan_pixels(e.relative.x)
		accept_event()
		return
	if _drag_marker != null:
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


func _marker_at(x: float) -> CueMarker:
	var best: CueMarker = null
	var best_d := MARKER_HIT_PX
	for m in state.sheet.sorted():
		var d: float = absf(state.time_to_x(m.time) - x)
		if d <= best_d:
			best_d = d
			best = m
	return best
