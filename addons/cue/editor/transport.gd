@tool
class_name CueTransport extends HBoxContainer

## 底部面板的工具栏:打开 / 保存 / 播放 / 缩放 / 吸附 / 分析。
## 按钮在代码里建,图标取编辑器主题(不硬编码任何颜色或图形)。

signal open_requested()
signal save_requested()
signal play_pause_requested()
signal stop_requested()
signal analyze_requested()
signal import_requested()
signal collapse_all_requested(collapsed: bool)
signal export_requested(kind: int)
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

	var fold_btn := _button("", "CollapseTree", "折叠所有轨道")
	fold_btn.pressed.connect(func() -> void: collapse_all_requested.emit(true))
	var unfold_btn := _button("", "ExpandTree", "展开所有轨道")
	unfold_btn.pressed.connect(func() -> void: collapse_all_requested.emit(false))

	add_child(VSeparator.new())

	_analyze_btn = _button("分析波形", "AudioStreamPlayer", "读取音频并重建峰值缓存")
	_analyze_btn.pressed.connect(func() -> void: analyze_requested.emit())

	# 4.7.2 实测编辑器主题里没有 "AssetLib" 图标,用 "AnimationTrackList"
	var imp_btn := _button("导入", "AnimationTrackList", "导入 Rhubarb JSON 或 MFA TextGrid")
	imp_btn.pressed.connect(func() -> void: import_requested.emit())

	_build_export_menu()

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


## 导出动作都收在一个菜单里 —— 工具栏横向空间有限,
## 五个动作各占一个按钮会把缩放控件挤出可视区。
enum Export { MARKERS_JSON, MARKERS_CSV, ENVELOPE_JSON, ENVELOPE_CSV, SCRIPT }


func _build_export_menu() -> void:
	var mb := MenuButton.new()
	mb.text = "导出"
	mb.tooltip_text = "把标记 / 包络 / 剧本骨架写到文件"
	mb.focus_mode = Control.FOCUS_NONE
	if Engine.is_editor_hint():
		var theme := EditorInterface.get_editor_theme()
		if theme != null and theme.has_icon("Save", "EditorIcons"):
			mb.icon = theme.get_icon("Save", "EditorIcons")
	var pm := mb.get_popup()
	pm.add_item("标记 → JSON(无损,可再导回)", Export.MARKERS_JSON)
	pm.add_item("标记 → CSV(给人看 / 表格)", Export.MARKERS_CSV)
	pm.add_separator()
	pm.add_item("振幅包络 → JSON", Export.ENVELOPE_JSON)
	pm.add_item("振幅包络 → CSV", Export.ENVELOPE_CSV)
	pm.add_separator()
	pm.add_item("剧本骨架 → .gd", Export.SCRIPT)
	pm.id_pressed.connect(func(id: int) -> void: export_requested.emit(id))
	add_child(mb)


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
