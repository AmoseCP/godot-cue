@tool
class_name CueSubtitleBar extends Control

## 波形下方的字幕条:显示播放头此刻每条文本轨上的内容。
##
## 数据来自标记的 [code]payload.text[/code] —— MFA TextGrid 导入器写词级 /
## 音素级文本,手工加的对白标记也可以自己填。没有任何文本轨时整条隐藏,
## 不占地方。

const ROW_H := 20.0

var state: CueViewState = null

var _c_bg: Color = Color(0.10, 0.10, 0.12)
var _c_text: Color = Color(0.90, 0.90, 0.95)
var _font: Font = null
var _font_size: int = 13


func setup(p_state: CueViewState) -> void:
	state = p_state
	state.sheet_changed.connect(_refresh)
	state.playhead_moved.connect(queue_redraw)
	state.view_changed.connect(queue_redraw)


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if Engine.is_editor_hint():
		var t := EditorInterface.get_editor_theme()
		if t != null:
			_c_bg = t.get_color("dark_color_3", "Editor")
			_c_text = t.get_color("font_color", "Editor")
			_font = t.get_font("main", "EditorFonts")
			_font_size = t.get_font_size("main_size", "EditorFonts")
	_refresh()


## 有几条文本轨就多高;一条都没有就整条收起来。
func _refresh() -> void:
	var n := 0
	if state != null and state.sheet != null:
		n = state.sheet.text_tracks().size()
	visible = n > 0
	custom_minimum_size.y = ROW_H * float(n) if n > 0 else 0.0
	queue_redraw()


func _draw() -> void:
	if state == null or state.sheet == null or _font == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), _c_bg)
	var tracks := state.sheet.text_tracks()
	var t := state.playhead
	for i in tracks.size():
		var tn := tracks[i]
		var y := ROW_H * float(i)
		var col := state.sheet.track_color(tn, _c_text)
		draw_string(_font, Vector2(6.0, y + ROW_H - 5.0), String(tn) + ":",
			HORIZONTAL_ALIGNMENT_LEFT, 90.0, maxi(_font_size - 2, 9), Color(col, 0.8))
		var text := state.sheet.text_at(t, tn)
		if text == "":
			continue
		draw_string(_font, Vector2(100.0, y + ROW_H - 5.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, size.x - 106.0, _font_size, _c_text)
