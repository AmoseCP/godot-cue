@tool
class_name CueTrackHeaders extends Control

## 波形左侧的轨道头:每条轨道一行,显示折叠箭头、颜色条、名字和标记数。
##
## 行高必须和 [CueWaveformView] 里的泳道完全一致,所以两边都从
## [CueViewState] 读同一份泳道几何,谁都不自己算。

const WIDTH := 118.0
## 折叠箭头的点击热区宽度。
const ARROW_W := 18.0

var state: CueViewState = null

var _c_bg: Color = Color(0.14, 0.14, 0.16)
var _c_row: Color = Color(0.18, 0.18, 0.21)
var _c_active: Color = Color(0.25, 0.30, 0.38)
var _c_text: Color = Color(0.85, 0.85, 0.9)
var _font: Font = null
var _font_size: int = 11
var _icon_open: Texture2D = null
var _icon_closed: Texture2D = null


func setup(p_state: CueViewState) -> void:
	state = p_state
	state.sheet_changed.connect(queue_redraw)
	state.lanes_changed.connect(queue_redraw)


func _ready() -> void:
	custom_minimum_size.x = WIDTH
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "点箭头折叠/展开轨道,点名字把它设为「加标记」的目标轨"
	if not Engine.is_editor_hint():
		return
	var t := EditorInterface.get_editor_theme()
	if t == null:
		return
	_c_bg = t.get_color("dark_color_1", "Editor")
	_c_row = t.get_color("dark_color_2", "Editor")
	_c_active = t.get_color("accent_color", "Editor")
	_c_active = Color(_c_active, 0.28)
	_c_text = t.get_color("font_color", "Editor")
	_font = t.get_font("main", "EditorFonts")
	_font_size = maxi(t.get_font_size("main_size", "EditorFonts") - 1, 8)
	if t.has_icon("GuiTreeArrowDown", "EditorIcons"):
		_icon_open = t.get_icon("GuiTreeArrowDown", "EditorIcons")
	if t.has_icon("GuiTreeArrowRight", "EditorIcons"):
		_icon_closed = t.get_icon("GuiTreeArrowRight", "EditorIcons")


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _c_bg)
	if state == null or state.sheet == null or _font == null:
		return

	var names := state.track_list()
	var y := 0.0
	for n in names:
		var h := state.lane_height(n)
		var collapsed := state.is_collapsed(n)
		var row := Rect2(0.0, y, size.x, h - 1.0)
		draw_rect(row, _c_active if n == state.active_track else _c_row)

		# 左边一小条轨道色,和波形里的标记颜色对得上
		var col := state.sheet.track_color(n, Color(0.5, 0.6, 0.75))
		draw_rect(Rect2(0.0, y, 3.0, h - 1.0), col)

		if not collapsed:
			var icon := _icon_closed if collapsed else _icon_open
			if icon != null:
				draw_texture(icon, Vector2(5.0, y + (h - float(icon.get_height())) * 0.5))
			var label := String(n)
			var count := state.sheet.count_in_track(n)
			var text := "%s (%d)" % [label, count]
			draw_string(_font, Vector2(ARROW_W + 4.0, y + h - 7.0), text,
				HORIZONTAL_ALIGNMENT_LEFT, size.x - ARROW_W - 8.0, _font_size, _c_text)
		else:
			# 折叠时太矮,放不下文字,只画箭头和一个截断的名字
			if _icon_closed != null:
				draw_texture(_icon_closed,
					Vector2(5.0, y + (h - float(_icon_closed.get_height())) * 0.5))
			draw_string(_font, Vector2(ARROW_W + 4.0, y + h - 1.0), String(n),
				HORIZONTAL_ALIGNMENT_LEFT, size.x - ARROW_W - 8.0,
				maxi(_font_size - 2, 7), Color(_c_text, 0.75))
		y += h


func _gui_input(event: InputEvent) -> void:
	if state == null or state.sheet == null:
		return
	if not (event is InputEventMouseButton):
		return
	var e := event as InputEventMouseButton
	if not e.pressed or e.button_index != MOUSE_BUTTON_LEFT:
		return
	var n := state.lane_at(e.position.y)
	if n == &"":
		return
	# 箭头热区 → 折叠;其余 → 设为活动轨
	if e.position.x <= ARROW_W:
		state.toggle_collapsed(n)
	elif e.double_click:
		state.toggle_collapsed(n)
	else:
		state.set_active_track(n)
	accept_event()
