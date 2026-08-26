@tool
class_name CueMarkerList extends VBoxContainer

## 可搜索的标记列表:一集几千个标记时,靠拖滚动条是找不到 peter_line_7 的。
##
## 搜索同时匹配标记名和 [code]payload.text[/code] —— 核字幕时按内容找
## 比按 `m_0007` 找自然得多。
##
## [b]结果条数是有上限的[/b]:2320 个标记全塞进 ItemList 会让每次按键都卡一下。
## 超出上限时只显示前 N 条并明确写出"还有多少条没显示",
## 而不是悄悄截断 —— 悄悄截断会让人以为"就这么多了"。

signal marker_activated(marker: CueMarker)

const WIDTH := 240.0
## 一次最多往 ItemList 里塞多少条。
const MAX_ROWS := 300

var state: CueViewState = null

var _filter: LineEdit = null
var _only_active: CheckBox = null
var _list: ItemList = null
var _count: Label = null
var _rows: Array[CueMarker] = []
var _c_dim: Color = Color(0.6, 0.6, 0.65)


func setup(p_state: CueViewState) -> void:
	state = p_state
	state.sheet_changed.connect(refresh)
	state.lanes_changed.connect(refresh)


func _ready() -> void:
	custom_minimum_size.x = WIDTH
	add_theme_constant_override("separation", 2)

	_filter = LineEdit.new()
	_filter.placeholder_text = "搜索标记名或字幕文本…"
	_filter.clear_button_enabled = true
	_filter.text_changed.connect(func(_t: String) -> void: refresh())
	add_child(_filter)

	_only_active = CheckBox.new()
	_only_active.text = "只看当前轨"
	_only_active.tooltip_text = "口型轨几千个标记时,勾上它才找得到对白"
	_only_active.toggled.connect(func(_on: bool) -> void: refresh())
	add_child(_only_active)

	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.allow_reselect = true
	_list.item_selected.connect(_on_item_selected)
	add_child(_list)

	_count = Label.new()
	_count.add_theme_font_size_override("font_size", 10)
	add_child(_count)

	if Engine.is_editor_hint():
		var t := EditorInterface.get_editor_theme()
		if t != null:
			_c_dim = Color(t.get_color("font_color", "Editor"), 0.55)
			_count.add_theme_color_override("font_color", _c_dim)
	refresh()


## 设置搜索词并刷新。
func set_filter(text: String) -> void:
	if _filter != null:
		_filter.text = text
	refresh()


## 实际填进列表的行数。用来确认"刷新"真的做了事 ——
## 一个提前 return 的 refresh() 和一个高效的 refresh() 在计时器上长得一样。
func row_count() -> int:
	return _rows.size()


## 当前结果条数(未截断前)。
func hit_count() -> int:
	if state == null or state.sheet == null:
		return 0
	var track: StringName = state.active_track if (_only_active != null \
		and _only_active.button_pressed) else &""
	return state.sheet.search(_filter.text if _filter != null else "", track).size()


func refresh() -> void:
	if _list == null:
		return
	_list.clear()
	_rows.clear()
	if state == null or state.sheet == null:
		_count.text = "(未打开)"
		return

	var track: StringName = state.active_track if _only_active.button_pressed else &""
	var hits := state.sheet.search(_filter.text, track)
	var fps := float(state.sheet.fps)

	var shown: int = mini(hits.size(), MAX_ROWS)
	for i in shown:
		var m := hits[i]
		var label := "%6.2fs  %s" % [m.time, m.name]
		var txt := String(m.payload.get("text", "")).strip_edges()
		if txt != "":
			label += "  「%s」" % txt
		_list.add_item(label)
		_list.set_item_tooltip(_list.item_count - 1,
			"%s\n%.3fs / f%d\n轨道:%s" % [m.name, m.time, int(round(m.time * fps)), m.track])
		_rows.append(m)

	if hits.size() > shown:
		# 明确写出被截掉了多少 —— 悄悄截断会让人以为"就这么多了"
		_count.text = "显示 %d / 共 %d 条,请再缩小搜索范围" % [shown, hits.size()]
	elif hits.is_empty():
		_count.text = "没有匹配的标记" if _filter.text != "" else "这条轨上没有标记"
	else:
		_count.text = "共 %d 条" % hits.size()


func _on_item_selected(index: int) -> void:
	if index < 0 or index >= _rows.size():
		return
	marker_activated.emit(_rows[index])


## 外部改变选中标记时,让列表跟着高亮(如果它在当前结果里)。
func sync_selection(m: CueMarker) -> void:
	if _list == null:
		return
	var i := _rows.find(m)
	if i >= 0:
		_list.select(i)
	else:
		_list.deselect_all()
