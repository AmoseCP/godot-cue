@tool
class_name CueEditOps extends RefCounted

## 所有会修改 CueSheet 的操作,集中在这里,每一个都走 [EditorUndoRedoManager]。
##
## 从面板里拆出来的理由:面板本来同时管布局、播放、对话框、频谱作业和编辑,
## 八件事挤在一个文件里。编辑这一组有共同的前提(要 sheet、要 undo、
## 改完要通知视图),抽出来之后既短又能单独讲清楚。
##
## [b]为什么每个动作的目标对象都是 sheet[/b]:4.7.2 实测,没有 resource_path
## 的子资源(CueMarker / CueAudioSegment)归属"当前编辑场景"的 undo 历史,
## 而已存盘的 CueSheet 归 GLOBAL,混在一个 action 里会报
## [code]UndoRedo history mismatch[/code]。所以子资源只作为**参数**传递,
## 目标对象一律是 sheet(参数不参与历史判定)。
## 同理不用 [code]add_do_reference()[/code] —— 它也做历史校验,
## 改由 CueSheet 自己拿住被摘下来的对象。

var _undo: EditorUndoRedoManager = null
var _state: CueViewState = null


func _init(undo: EditorUndoRedoManager, state: CueViewState) -> void:
	_undo = undo
	_state = state


func _sheet() -> CueSheet:
	return _state.sheet if _state != null else null


func _ready_to_edit() -> bool:
	return _undo != null and _sheet() != null


# ── 标记 ────────────────────────────────────────────────────────────

## 在 [param t] 处加一个标记,落在当前活动轨上。返回新标记(失败返回 null)。
func add_marker(t: float) -> CueMarker:
	if not _ready_to_edit():
		return null
	var sheet := _sheet()
	var track := _state.active_track
	var names := sheet.track_names()
	if track == &"" or not names.has(track):
		track = names[0]
	var m := CueMarker.new(sheet.unique_name(StringName(String(track))), t, track)

	_undo.create_action("Cue:添加标记", UndoRedo.MERGE_DISABLE, sheet)
	_undo.add_do_method(sheet, "add_marker", m)
	_undo.add_undo_method(sheet, "remove_marker", m)
	_undo.add_do_method(sheet, "touch")
	_undo.add_undo_method(sheet, "touch")
	_undo.commit_action()
	return m


func delete_marker(m: CueMarker) -> void:
	if not _ready_to_edit() or m == null:
		return
	var sheet := _sheet()
	var idx := sheet.index_of(m)
	_undo.create_action("Cue:删除标记「%s」" % m.name, UndoRedo.MERGE_DISABLE, sheet)
	_undo.add_do_method(sheet, "remove_marker", m)
	_undo.add_undo_method(sheet, "insert_marker", m, idx)
	_undo.add_do_method(sheet, "touch")
	_undo.add_undo_method(sheet, "touch")
	_undo.commit_action()


func move_marker(m: CueMarker, from_t: float, to_t: float) -> void:
	if not _ready_to_edit() or m == null:
		return
	var sheet := _sheet()
	_undo.create_action("Cue:移动标记「%s」" % m.name, UndoRedo.MERGE_DISABLE, sheet)
	_undo.add_do_method(sheet, "set_marker_time", m, to_t)
	_undo.add_undo_method(sheet, "set_marker_time", m, from_t)
	_undo.commit_action()


## 改名。空名或重名会被拒绝并报错 —— 名字唯一是 [method CueSheet.find] 的前提。
func rename_marker(m: CueMarker, new_name: StringName) -> bool:
	if not _ready_to_edit() or m == null or m.name == new_name:
		return false
	if new_name == &"":
		push_error("Cue:标记名不能为空。")
		return false
	var sheet := _sheet()
	var existing := sheet.find(new_name)
	if existing != null and existing != m:
		push_error("Cue:已经有名为「%s」的标记了。同一个 sheet 内标记名必须唯一。" % new_name)
		return false
	_undo.create_action("Cue:重命名标记「%s」" % m.name, UndoRedo.MERGE_DISABLE, sheet)
	_undo.add_do_method(sheet, "set_marker_name", m, new_name)
	_undo.add_undo_method(sheet, "set_marker_name", m, m.name)
	_undo.commit_action()
	return true


# ── 音频片段 ────────────────────────────────────────────────────────

func add_segment(seg: CueAudioSegment) -> void:
	if not _ready_to_edit() or seg == null:
		return
	var sheet := _sheet()
	sheet.migrate_legacy()
	_undo.create_action("Cue:添加音频片段「%s」" % seg.label(), UndoRedo.MERGE_DISABLE, sheet)
	_undo.add_do_method(sheet, "add_segment", seg)
	_undo.add_undo_method(sheet, "remove_segment", seg)
	_undo.commit_action()


func remove_segment(seg: CueAudioSegment) -> bool:
	if not _ready_to_edit():
		return false
	if seg == null:
		push_error("Cue:先在波形上点一下某个片段的把手,选中它。")
		return false
	var sheet := _sheet()
	if sheet.segments.size() <= 1 and not sheet.segments.is_empty():
		push_error("Cue:这是最后一个片段。CueSheet 至少要有一段音频。")
		return false
	var idx := sheet.index_of_segment(seg)
	if idx < 0:
		return false
	_undo.create_action("Cue:移除音频片段「%s」" % seg.label(), UndoRedo.MERGE_DISABLE, sheet)
	_undo.add_do_method(sheet, "remove_segment", seg)
	_undo.add_undo_method(sheet, "insert_segment", seg, idx)
	_undo.commit_action()
	return true


func move_segment(seg: CueAudioSegment, from_off: float, to_off: float) -> void:
	if not _ready_to_edit() or seg == null or is_equal_approx(from_off, to_off):
		return
	var sheet := _sheet()
	_undo.create_action("Cue:移动片段「%s」" % seg.label(), UndoRedo.MERGE_DISABLE, sheet)
	_undo.add_do_method(sheet, "set_segment_offset", seg, to_off)
	_undo.add_undo_method(sheet, "set_segment_offset", seg, from_off)
	_undo.commit_action()


# ── 批量导入 ────────────────────────────────────────────────────────

## 把一批解析好的标记作为[b]一次[/b] undo 动作写进 sheet。
## 导入 200 个口型标记后按一次 Ctrl+Z 就该全部消失,而不是按 200 次。
func import_markers(res: CueImportResult, source_name: String) -> void:
	if not _ready_to_edit() or res == null or res.markers.is_empty():
		return
	var sheet := _sheet()

	# 重名在写入前就解决掉,保证 sheet 内名字唯一
	var taken := {}
	for m in sheet.markers:
		taken[m.name] = true
	for m in res.markers:
		var n := m.name
		var i := 1
		while taken.has(n):
			n = StringName("%s_%d" % [m.name, i])
			i += 1
		m.name = n
		taken[n] = true

	# 新轨道必须和标记[b]同一个 action[/b]。曾经这里在 commit 之后单独建轨道,
	# 于是「导入 → 撤销」会留下孤儿轨道 —— 违反 CLAUDE.md
	# 「所有会修改资源的编辑操作都要走 EditorUndoRedoManager」。
	var new_tracks := missing_tracks(res.tracks)

	_undo.create_action("Cue:导入 %s(%d 个标记)" % [source_name, res.markers.size()],
		UndoRedo.MERGE_DISABLE, sheet)
	for t in new_tracks:
		_undo.add_do_method(sheet, "add_track", t)
	for m in res.markers:
		_undo.add_do_method(sheet, "add_marker", m)
	# 撤销时倒着删,顺序才对得上
	for i in range(res.markers.size() - 1, -1, -1):
		_undo.add_undo_method(sheet, "remove_marker", res.markers[i])
	for i in range(new_tracks.size() - 1, -1, -1):
		_undo.add_undo_method(sheet, "remove_track", new_tracks[i])
	_undo.add_do_method(sheet, "touch")
	_undo.add_undo_method(sheet, "touch")
	_undo.commit_action()


## 为 [param names] 里还没有 CueTrack 的轨道各造一个(带配色)。
## [b]只构造,不写入[/b] —— 写入由调用方放进 undo action 里。
## 新轨道要有个颜色,否则全挤在默认色上分不清。
func missing_tracks(names: PackedStringArray) -> Array[CueTrack]:
	var out: Array[CueTrack] = []
	var sheet := _sheet()
	if sheet == null:
		return out
	var palette := [
		Color(0.40, 0.70, 1.00), Color(1.00, 0.65, 0.30), Color(0.55, 0.90, 0.55),
		Color(0.90, 0.55, 0.90), Color(0.95, 0.85, 0.40),
	]
	var taken := {}
	for t in sheet.tracks:
		if t != null:
			taken[t.name] = true
	for n in names:
		var sn := StringName(n)
		if taken.has(sn):
			continue
		taken[sn] = true
		out.append(CueTrack.new(sn,
			palette[(sheet.tracks.size() + out.size()) % palette.size()]))
	return out
