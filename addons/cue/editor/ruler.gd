@tool
class_name CueRuler extends Control

## 时间标尺:秒 + 帧。刻度间隔随缩放自动选择,保证标签不重叠。

signal seek_requested(time: float)

## 候选刻度间隔(秒)。从密到疏,挑第一个像素间距够大的。
const STEPS: Array[float] = [
	0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0,
]
const MIN_LABEL_PX := 64.0

var state: CueViewState = null

var _c_bg: Color = Color(0.15, 0.15, 0.17)
var _c_tick: Color = Color(0.6, 0.6, 0.6)
var _c_text: Color = Color(0.85, 0.85, 0.85)
var _font: Font = null
var _font_size: int = 11


func setup(p_state: CueViewState) -> void:
	state = p_state
	state.view_changed.connect(queue_redraw)
	state.sheet_changed.connect(queue_redraw)
	state.playhead_moved.connect(queue_redraw)


func _ready() -> void:
	custom_minimum_size.y = 24.0
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	if Engine.is_editor_hint():
		var t := EditorInterface.get_editor_theme()
		if t != null:
			_c_bg = t.get_color("dark_color_1", "Editor")
			_c_text = t.get_color("font_color", "Editor")
			_c_tick = Color(_c_text, 0.55)
			# 4.7.2 实测:编辑器主题里没有 ("font", "Editor"),
			# 正确的键是 ("main", "EditorFonts") / ("main_size", "EditorFonts")。
			_font = t.get_font("main", "EditorFonts")
			_font_size = maxi(t.get_font_size("main_size", "EditorFonts") - 1, 8)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _c_bg)
	if state == null or state.sheet == null or _font == null:
		return

	var step := _pick_step()
	var t0: float = floorf(state.scroll_sec / step) * step
	var t_end := state.x_to_time(size.x)
	var fps := float(state.sheet.fps)

	var t := t0
	# 用整数计数推进而不是 t += step,避免浮点误差在长音频上累积成半个像素的漂移。
	var k := 0
	while t <= t_end:
		t = t0 + float(k) * step
		k += 1
		if t < 0.0:
			continue
		var x: float = roundf(state.time_to_x(t))
		if x < -MIN_LABEL_PX:
			continue
		if x > size.x:
			break
		draw_line(Vector2(x, size.y - 8.0), Vector2(x, size.y), _c_tick, 1.0)
		draw_string(_font, Vector2(x + 3.0, size.y - 10.0), _format(t, fps),
			HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, _c_text)

	var px := state.time_to_x(state.playhead)
	if px >= 0.0 and px <= size.x:
		draw_line(Vector2(px, 0), Vector2(px, size.y), Color(1.0, 0.35, 0.35), 1.0)


## 挑一个刻度间隔,使相邻标签至少隔 [constant MIN_LABEL_PX] 像素。
func _pick_step() -> float:
	for s in STEPS:
		if s * state.px_per_sec >= MIN_LABEL_PX:
			return s
	return STEPS[STEPS.size() - 1]


func _format(t: float, fps: float) -> String:
	var f := int(round(t * fps))
	var m := int(t) / 60
	var s := t - float(m * 60)
	if m > 0:
		return "%d:%05.2f  f%d" % [m, s, f]
	return "%.2fs  f%d" % [s, f]


func _gui_input(event: InputEvent) -> void:
	if state == null or state.sheet == null:
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_seek_to((event as InputEventMouseButton).position.x)
		accept_event()
	elif event is InputEventMouseMotion \
			and ((event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_seek_to((event as InputEventMouseMotion).position.x)
		accept_event()


func _seek_to(x: float) -> void:
	var t := state.maybe_snap(state.x_to_time(x))
	state.set_playhead(t)
	seek_requested.emit(t)
