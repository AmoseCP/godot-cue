@tool
class_name CueTransport extends HBoxContainer

## 底部面板的工具栏:打开 / 保存 / 播放 / 缩放 / 吸附 / 分析。
## 按钮在代码里建,图标取编辑器主题(不硬编码任何颜色或图形)。

signal open_requested()
signal save_requested()
signal play_pause_requested()
signal stop_requested()
signal analyze_requested()
signal zoom_in_requested()
signal zoom_out_requested()
signal zoom_fit_requested()
signal snap_toggled(on: bool)
signal add_marker_requested()

var state: CueViewState = null

var _title: Label
var _play_btn: Button
var _stop_btn: Button
var _time_label: Label
var _analyze_btn: Button
var _progress: ProgressBar
var _snap_check: CheckBox
var _save_btn: Button
var _dirty: bool = false


func setup(p_state: CueViewState) -> void:
	state = p_state
	state.sheet_changed.connect(_refresh_title)
	state.playhead_moved.connect(_refresh_time)


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	_build()
	_refresh_title()
	_refresh_time()


func _build() -> void:
	var open_btn := _button("打开", "Load", "打开一个 CueSheet 资源")
	open_btn.pressed.connect(func() -> void: open_requested.emit())

	_save_btn = _button("保存", "Save", "把 CueSheet 写回 .tres 文件")
	_save_btn.pressed.connect(func() -> void: save_requested.emit())

	_title = Label.new()
	_title.custom_minimum_size.x = 180.0
	_title.clip_text = true
	add_child(_title)

	add_child(VSeparator.new())

	_play_btn = _button("", "MainPlay", "播放 / 暂停(空格)")
	_play_btn.pressed.connect(func() -> void: play_pause_requested.emit())
	_stop_btn = _button("", "Stop", "停止并回到起点")
	_stop_btn.pressed.connect(func() -> void: stop_requested.emit())

	_time_label = Label.new()
	_time_label.custom_minimum_size.x = 130.0
	add_child(_time_label)

	add_child(VSeparator.new())

	var add_btn := _button("加标记", "Add", "在播放头处添加标记(M)")
	add_btn.pressed.connect(func() -> void: add_marker_requested.emit())

	_snap_check = CheckBox.new()
	_snap_check.text = "帧吸附"
	_snap_check.tooltip_text = "标记与定位吸附到帧边界(拖动时按住 Ctrl 可临时启用)"
	_snap_check.toggled.connect(func(on: bool) -> void:
		state.snap_to_frame = on
		snap_toggled.emit(on))
	add_child(_snap_check)

	add_child(VSeparator.new())

	_analyze_btn = _button("分析波形", "AudioStreamPlayer", "读取音频并重建峰值缓存")
	_analyze_btn.pressed.connect(func() -> void: analyze_requested.emit())

	_progress = ProgressBar.new()
	_progress.custom_minimum_size.x = 90.0
	_progress.show_percentage = false
	_progress.max_value = 1.0
	_progress.visible = false
	add_child(_progress)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(spacer)

	var zo := _button("", "ZoomLess", "缩小(滚轮下)")
	zo.pressed.connect(func() -> void: zoom_out_requested.emit())
	var zf := _button("适配", "", "缩放到整段音频")
	zf.pressed.connect(func() -> void: zoom_fit_requested.emit())
	var zi := _button("", "ZoomMore", "放大(滚轮上)")
	zi.pressed.connect(func() -> void: zoom_in_requested.emit())


func _button(text: String, icon_name: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	if icon_name != "" and Engine.is_editor_hint():
		var theme := EditorInterface.get_editor_theme()
		if theme != null and theme.has_icon(icon_name, "EditorIcons"):
			b.icon = theme.get_icon(icon_name, "EditorIcons")
	add_child(b)
	return b


func set_playing(playing: bool) -> void:
	if not Engine.is_editor_hint():
		return
	var theme := EditorInterface.get_editor_theme()
	if theme == null:
		return
	var n := "Pause" if playing else "MainPlay"
	if theme.has_icon(n, "EditorIcons"):
		_play_btn.icon = theme.get_icon(n, "EditorIcons")


func set_dirty(dirty: bool) -> void:
	_dirty = dirty
	_refresh_title()


func show_progress(ratio: float) -> void:
	_progress.visible = ratio < 1.0
	_progress.value = ratio
	_analyze_btn.disabled = ratio < 1.0


func _refresh_title() -> void:
	if _title == null:
		return
	if state == null or state.sheet == null:
		_title.text = "(未打开)"
		_title.tooltip_text = ""
		return
	var p := state.sheet.resource_path
	var n := p.get_file() if p != "" else "未保存的 CueSheet"
	_title.text = ("*" if _dirty else "") + n
	_title.tooltip_text = p


func _refresh_time() -> void:
	if _time_label == null or state == null:
		return
	var t := state.playhead
	var fps := state.sheet.fps if state.sheet != null else 30
	var m := int(t) / 60
	var s := t - float(m * 60)
	_time_label.text = "%d:%06.3f  f%d" % [m, s, int(round(t * float(fps)))]
