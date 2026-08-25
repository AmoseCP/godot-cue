@tool
class_name CuePanel extends VBoxContainer

## 底部面板根节点。持有视图状态、编辑器音频播放器,并且是[b]唯一[/b]
## 执行编辑操作的地方 —— 所有改动都经过 [EditorUndoRedoManager]
## (见 CLAUDE.md:没有 undo 的编辑功能视为未完成)。

const CueViewStateScript := preload("res://addons/cue/editor/cue_view_state.gd")

var state: CueViewState = null

var _undo: EditorUndoRedoManager = null
var _transport: CueTransport = null
var _ruler: CueRuler = null
var _view: CueWaveformView = null
var _hscroll: HScrollBar = null
var _player: AudioStreamPlayer = null
var _clock: CueClock = null
var _name_edit: LineEdit = null
var _renaming: CueMarker = null
var _open_dialog: EditorFileDialog = null
var _dirty: bool = false
var _analyzing: bool = false


func setup(undo: EditorUndoRedoManager) -> void:
	_undo = undo


func _ready() -> void:
	custom_minimum_size.y = 220.0
	state = CueViewStateScript.new()

	_transport = CueTransport.new()
	_transport.setup(state)
	add_child(_transport)

	_ruler = CueRuler.new()
	_ruler.setup(state)
	add_child(_ruler)

	_view = CueWaveformView.new()
	_view.setup(state)
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_view)

	_hscroll = HScrollBar.new()
	_hscroll.visible = false
	add_child(_hscroll)

	_player = AudioStreamPlayer.new()
	_player.name = "PreviewPlayer"
	add_child(_player)
	_player.finished.connect(_on_audio_finished)

	_name_edit = LineEdit.new()
	_name_edit.visible = false
	_name_edit.custom_minimum_size.x = 120.0
	_view.add_child(_name_edit)
	_name_edit.text_submitted.connect(_on_rename_submitted)
	_name_edit.focus_exited.connect(_cancel_rename)

	_transport.open_requested.connect(_open_dialog_show)
	_transport.save_requested.connect(save_sheet)
	_transport.play_pause_requested.connect(_toggle_play)
	_transport.stop_requested.connect(_stop)
	_transport.analyze_requested.connect(analyze_waveform)
	_transport.add_marker_requested.connect(func() -> void: _add_marker(state.maybe_snap(state.playhead)))
	_transport.zoom_in_requested.connect(func() -> void: state.zoom_at(1.4, size.x * 0.5))
	_transport.zoom_out_requested.connect(func() -> void: state.zoom_at(1.0 / 1.4, size.x * 0.5))
	_transport.zoom_fit_requested.connect(func() -> void: state.zoom_fit())

	_view.marker_add_requested.connect(_add_marker)
	_view.marker_delete_requested.connect(_delete_marker)
	_view.marker_move_requested.connect(_move_marker)
	_view.marker_rename_requested.connect(_begin_rename)
	_view.seek_requested.connect(_seek)
	_ruler.seek_requested.connect(_seek)

	state.view_changed.connect(_sync_scrollbar)
	state.sheet_changed.connect(_sync_scrollbar)
	_hscroll.value_changed.connect(func(v: float) -> void:
		if not _syncing:
			state.scroll_to(v))

	set_process(false)


func _exit_tree() -> void:
	# @tool 脚本会被反复重载,残留的连接会在下次 _ready 里变成重复连接。
	if state != null and state.sheet != null and state.sheet.changed.is_connected(_after_edit):
		state.sheet.changed.disconnect(_after_edit)
	if _player != null and _player.playing:
		_player.stop()


# ── sheet 生命周期 ──────────────────────────────────────────────────

func open_sheet(sheet: CueSheet) -> void:
	_stop()
	var old := state.sheet
	if old != null and old.changed.is_connected(_after_edit):
		old.changed.disconnect(_after_edit)
	if sheet != null and not sheet.changed.is_connected(_after_edit):
		sheet.changed.connect(_after_edit)
	state.set_sheet(sheet)
	_player.stream = sheet.audio if sheet != null else null
	_clock = CueClock.new(float(sheet.fps) if sheet != null else 30.0, _player)
	_dirty = false
	_transport.set_dirty(false)
	if sheet != null:
		state.zoom_fit()
		if sheet.waveform == null or not sheet.waveform.is_valid():
			analyze_waveform()
	if is_instance_valid(_view):
		_view.queue_redraw()


func save_sheet() -> void:
	var sheet := state.sheet
	if sheet == null:
		return
	if sheet.resource_path == "":
		push_error("Cue:这个 CueSheet 还没有文件路径,请先在文件系统中另存为 .tres。")
		return
	var issues := sheet.validate()
	if not issues.is_empty():
		for i in issues:
			push_error("Cue:%s" % i)
		return
	# EditorInterface 在 4.7 里没有 save_resource(),用 ResourceSaver。
	var err := ResourceSaver.save(sheet, sheet.resource_path)
	if err != OK:
		push_error("Cue:保存失败(错误码 %d):%s" % [err, sheet.resource_path])
		return
	_dirty = false
	_transport.set_dirty(false)
	EditorInterface.get_resource_filesystem().update_file(sheet.resource_path)


func _mark_dirty() -> void:
	_dirty = true
	_transport.set_dirty(true)


# ── 波形分析 ────────────────────────────────────────────────────────

func analyze_waveform() -> void:
	var sheet := state.sheet
	if sheet == null or _analyzing:
		return
	var path := sheet.audio_path
	if path == "" and sheet.audio != null:
		path = sheet.audio.resource_path
	var src := CuePcmReader.open(path, sheet.audio)
	if not src.ok():
		push_error(src.error)
		return

	_analyzing = true
	var builder := CueWaveformBuilder.new()
	builder.progress.connect(func(r: float) -> void: _transport.show_progress(r))
	var cache: WaveformCache = await builder.build_async(src)
	cache.source_hash = WaveformCache.compute_hash(path)
	_analyzing = false
	_transport.show_progress(1.0)

	if state.sheet != sheet:
		return                        # 分析期间用户换了 sheet
	sheet.waveform = cache
	_mark_dirty()
	state.notify_sheet_edited()
	state.zoom_fit()


# ── 播放 ────────────────────────────────────────────────────────────

func _toggle_play() -> void:
	if state.sheet == null:
		return
	if _player.playing and not _player.stream_paused:
		_player.stream_paused = true
		_clock.stop()
		set_process(false)
		_transport.set_playing(false)
	elif _player.playing and _player.stream_paused:
		_player.stream_paused = false
		_clock.resume()
		set_process(true)
		_transport.set_playing(true)
	else:
		if _player.stream == null:
			push_error("Cue:这个 CueSheet 没有设置 audio,无法播放。")
			return
		_player.play(state.playhead)
		_clock.start(state.playhead)
		set_process(true)
		_transport.set_playing(true)


func _stop() -> void:
	if _player != null:
		_player.stop()
		_player.stream_paused = false
	if _clock != null:
		_clock.stop()
	set_process(false)
	if _transport != null:
		_transport.set_playing(false)


func _seek(t: float) -> void:
	state.set_playhead(t)
	if _player.playing:
		_player.play(t)
		_clock.start(t)


func _on_audio_finished() -> void:
	_stop()


func _process(_delta: float) -> void:
	if _clock == null or not _player.playing or _player.stream_paused:
		return
	state.set_playhead(_clock.now())
	state.follow_playhead()


# ── 编辑操作(全部走 undo)──────────────────────────────────────────

func _add_marker(t: float) -> void:
	var sheet := state.sheet
	if sheet == null or _undo == null:
		return
	var m := CueMarker.new(sheet.unique_name(&"cue"), t)
	_undo.create_action("Cue:添加标记", UndoRedo.MERGE_DISABLE, sheet)
	_undo.add_do_method(sheet, "add_marker", m)
	_undo.add_undo_method(sheet, "remove_marker", m)
	_undo.add_do_method(sheet, "touch")
	_undo.add_undo_method(sheet, "touch")
	_undo.commit_action()
	_view.select(m)
	_begin_rename(m)


func _delete_marker(m: CueMarker) -> void:
	var sheet := state.sheet
	if sheet == null or _undo == null or m == null:
		return
	var idx := sheet.index_of(m)
	_undo.create_action("Cue:删除标记「%s」" % m.name, UndoRedo.MERGE_DISABLE, sheet)
	_undo.add_do_method(sheet, "remove_marker", m)
	_undo.add_undo_method(sheet, "insert_marker", m, idx)
	_undo.add_do_method(sheet, "touch")
	_undo.add_undo_method(sheet, "touch")
	_undo.commit_action()
	_view.select(null)


func _move_marker(m: CueMarker, from_t: float, to_t: float) -> void:
	if state.sheet == null or _undo == null:
		return
	_undo.create_action("Cue:移动标记「%s」" % m.name, UndoRedo.MERGE_DISABLE, state.sheet)
	_undo.add_do_method(state.sheet, "set_marker_time", m, to_t)
	_undo.add_undo_method(state.sheet, "set_marker_time", m, from_t)
	_undo.commit_action()


func _rename_marker(m: CueMarker, new_name: StringName) -> void:
	if state.sheet == null or _undo == null or m.name == new_name:
		return
	if new_name == &"":
		push_error("Cue:标记名不能为空。")
		return
	var existing := state.sheet.find(new_name)
	if existing != null and existing != m:
		push_error("Cue:已经有名为「%s」的标记了。同一个 sheet 内标记名必须唯一。" % new_name)
		return
	_undo.create_action("Cue:重命名标记「%s」" % m.name, UndoRedo.MERGE_DISABLE, state.sheet)
	_undo.add_do_method(state.sheet, "set_marker_name", m, new_name)
	_undo.add_undo_method(state.sheet, "set_marker_name", m, m.name)
	_undo.commit_action()


## sheet 的 changed 信号处理器 —— do 和 undo 都会经过这里
## (undo 动作里调的是 CueSheet.touch(),它发 changed)。
func _after_edit() -> void:
	_mark_dirty()
	if state != null:
		state.notify_sheet_edited()
	if is_instance_valid(_view):
		_view.queue_redraw()


# ── 行内改名 ────────────────────────────────────────────────────────

func _begin_rename(m: CueMarker) -> void:
	if m == null:
		return
	_renaming = m
	_name_edit.text = String(m.name)
	_name_edit.visible = true
	var x := state.time_to_x(m.time) + 6.0
	_name_edit.position = Vector2(clampf(x, 0.0, maxf(_view.size.x - 130.0, 0.0)), 18.0)
	_name_edit.grab_focus()
	_name_edit.select_all()


func _on_rename_submitted(text: String) -> void:
	var m := _renaming
	_cancel_rename()
	if m != null:
		_rename_marker(m, StringName(text.strip_edges()))


func _cancel_rename() -> void:
	_renaming = null
	_name_edit.visible = false


# ── 打开对话框 / 滚动条 ─────────────────────────────────────────────

func _open_dialog_show() -> void:
	if _open_dialog == null:
		_open_dialog = EditorFileDialog.new()
		_open_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_open_dialog.access = EditorFileDialog.ACCESS_RESOURCES
		_open_dialog.add_filter("*.tres", "CueSheet 资源")
		_open_dialog.title = "打开 CueSheet"
		_open_dialog.file_selected.connect(_on_file_chosen)
		add_child(_open_dialog)
	_open_dialog.popup_centered_ratio(0.6)


func _on_file_chosen(path: String) -> void:
	var res := ResourceLoader.load(path)
	if res is CueSheet:
		open_sheet(res as CueSheet)
		EditorInterface.edit_resource(res)
	else:
		push_error("Cue:%s 不是 CueSheet 资源。" % path)


var _syncing: bool = false

func _sync_scrollbar() -> void:
	if _hscroll == null:
		return
	var d := state.duration()
	var vis := state.visible_seconds()
	_syncing = true
	if d <= 0.0 or vis >= d:
		_hscroll.visible = false
	else:
		_hscroll.visible = true
		_hscroll.min_value = 0.0
		_hscroll.max_value = d
		_hscroll.page = vis
		_hscroll.value = state.scroll_sec
	_syncing = false


func _shortcut_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or state.sheet == null:
		return
	if event is InputEventKey and (event as InputEventKey).pressed \
			and (event as InputEventKey).keycode == KEY_SPACE \
			and not _name_edit.visible:
		_toggle_play()
		get_viewport().set_input_as_handled()
