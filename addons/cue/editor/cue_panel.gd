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
var _headers: CueTrackHeaders = null
var _subtitles: CueSubtitleBar = null
var _hscroll: HScrollBar = null
var _player: AudioStreamPlayer = null
var _clock: CueClock = null
var _name_edit: LineEdit = null
var _renaming: CueMarker = null
var _open_dialog: EditorFileDialog = null
var _import_dialog: EditorFileDialog = null
var _script_dialog: EditorFileDialog = null
var _export_kind: int = -1
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

	# 标尺行:左边留一块和轨道头等宽的空白,这样标尺的 0 秒
	# 和波形的 0 秒在同一条竖线上。
	var ruler_row := HBoxContainer.new()
	ruler_row.add_theme_constant_override("separation", 0)
	add_child(ruler_row)
	var ruler_gutter := Control.new()
	ruler_gutter.custom_minimum_size.x = CueTrackHeaders.WIDTH
	ruler_row.add_child(ruler_gutter)

	_ruler = CueRuler.new()
	_ruler.setup(state)
	_ruler.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ruler_row.add_child(_ruler)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 0)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(body)

	_headers = CueTrackHeaders.new()
	_headers.setup(state)
	body.add_child(_headers)

	_view = CueWaveformView.new()
	_view.setup(state)
	_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_view)

	_subtitles = CueSubtitleBar.new()
	_subtitles.setup(state)
	add_child(_subtitles)

	var scroll_row := HBoxContainer.new()
	scroll_row.add_theme_constant_override("separation", 0)
	add_child(scroll_row)
	var scroll_gutter := Control.new()
	scroll_gutter.custom_minimum_size.x = CueTrackHeaders.WIDTH
	scroll_row.add_child(scroll_gutter)
	_hscroll = HScrollBar.new()
	_hscroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hscroll.visible = false
	scroll_row.add_child(_hscroll)

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
	_transport.import_requested.connect(_import_dialog_show)
	_transport.collapse_all_requested.connect(func(v: bool) -> void: state.set_all_collapsed(v))
	_transport.export_requested.connect(_export_requested)
	_transport.show_text_toggled.connect(func(_on: bool) -> void:
		state.notify_sheet_edited()
		_view.queue_redraw())
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
		var names := sheet.track_names()
		state.active_track = names[0]
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

## 分析全部片段。只重算[b]需要[/b]重算的那些 —— 改一个角色的配音时
## 不该把整集其他角色的波形也重扫一遍(这是 D10′ 保留"局部重渲"诉求的落点)。
func analyze_waveform(force: bool = false) -> void:
	var sheet := state.sheet
	if sheet == null or _analyzing:
		return

	# 旧的单音频 sheet 在这里就地升级成 segments 形式
	sheet.migrate_legacy()

	var segs := sheet.all_segments()
	if segs.is_empty():
		push_error("Cue:这个 CueSheet 还没有音频片段。请在 Inspector 里往 segments 加一段。")
		return

	_analyzing = true
	var builder := CueWaveformBuilder.new()
	var done := 0
	var failed := PackedStringArray()

	for seg in segs:
		if not force and seg.has_waveform() and not seg.waveform_stale():
			done += 1
			_transport.show_progress(float(done) / float(segs.size()))
			continue
		var src := CuePcmReader.open(seg.path, seg.stream)
		if not src.ok():
			failed.append(src.error)
			done += 1
			continue
		# 多段时进度条要横跨所有段,不能每段都从 0 走一遍
		var base := float(done) / float(segs.size())
		var span := 1.0 / float(segs.size())
		var cb := func(r: float) -> void: _transport.show_progress(base + r * span)
		builder.progress.connect(cb)
		var cache: WaveformCache = await builder.build_async(src)
		builder.progress.disconnect(cb)
		cache.source_hash = WaveformCache.compute_hash(seg.path)
		if state.sheet != sheet:
			_analyzing = false        # 分析期间用户换了 sheet
			return
		seg.waveform = cache
		done += 1

	_analyzing = false
	_transport.show_progress(1.0)
	for e in failed:
		push_error(e)

	# 包络跨全部片段,从各段的峰值缓存拼出来
	sheet.envelope = _build_envelope(sheet)
	_mark_dirty()
	state.notify_sheet_edited()
	state.zoom_fit()


## 把各片段的峰值缓存按 offset 拼成一条覆盖整条时间轴的包络。
func _build_envelope(sheet: CueSheet) -> CueEnvelope:
	var segs := sheet.all_segments()
	var dur := sheet.duration()
	if segs.is_empty() or dur <= 0.0:
		return null
	var rate := CueEnvelopeBuilder.DEFAULT_RATE
	var out := CueEnvelope.new()
	out.rate = rate
	out.duration = dur
	var vals := PackedFloat32Array()
	vals.resize(maxi(int(ceil(dur * rate)), 1))
	for seg in segs:
		if not seg.has_waveform():
			continue
		var part := CueEnvelopeBuilder.from_cache(seg.waveform, rate)
		var base := int(round(seg.offset * rate))
		for i in part.values.size():
			var j := base + i
			if j < 0 or j >= vals.size():
				continue
			# 片段重叠时取较大者,而不是相加 —— 相加会让重叠处虚高
			vals[j] = maxf(vals[j], part.values[i])
	out.values = vals
	if segs.size() > 0 and segs[0].waveform != null:
		out.source_hash = segs[0].waveform.source_hash
	return CueEnvelopeBuilder.normalized(out)


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
	var track := state.active_track
	if track == &"" or not sheet.track_names().has(track):
		track = sheet.track_names()[0]
	var m := CueMarker.new(sheet.unique_name(StringName(String(track))), t, track)
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


# ── 导入 ────────────────────────────────────────────────────────────

func _import_dialog_show() -> void:
	if state.sheet == null:
		push_error("Cue:先打开一个 CueSheet 再导入。")
		return
	if _import_dialog == null:
		_import_dialog = EditorFileDialog.new()
		_import_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_import_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_import_dialog.add_filter("*.json", "Rhubarb JSON / Cue 导出的标记 JSON")
		_import_dialog.add_filter("*.TextGrid,*.textgrid", "Praat / MFA TextGrid")
		_import_dialog.title = "导入口型 / 对齐数据"
		_import_dialog.file_selected.connect(import_file)
		add_child(_import_dialog)
	_import_dialog.popup_centered_ratio(0.6)


## 解析并作为[b]一次[/b] undo 动作写入 —— 导入 200 个口型标记后按一次
## Ctrl+Z 就该全部消失,而不是按 200 次。
func import_file(path: String) -> void:
	var sheet := state.sheet
	if sheet == null or _undo == null:
		return
	var res: CueImportResult
	if path.get_extension().to_lower() == "json":
		# Cue 自己导出的标记 JSON 和 Rhubarb 的都是 .json,
		# 靠顶层字段区分:有 cue_format 就是自己人。
		res = _sniff_json(path)
	else:
		res = CueTextGridImporter.parse(path)
	if not res.ok():
		push_error(res.error)
		return

	# 重名在导入这一步就解决掉,保证 sheet 内名字唯一(PLAN 4.3)。
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

	_undo.create_action("Cue:导入 %s(%d 个标记)" % [path.get_file(), res.markers.size()],
		UndoRedo.MERGE_DISABLE, sheet)
	for m in res.markers:
		_undo.add_do_method(sheet, "add_marker", m)
	# 撤销时倒着删,顺序才对得上
	for i in range(res.markers.size() - 1, -1, -1):
		_undo.add_undo_method(sheet, "remove_marker", res.markers[i])
	_undo.add_do_method(sheet, "touch")
	_undo.add_undo_method(sheet, "touch")
	_undo.commit_action()

	_ensure_tracks(res.tracks)
	print("Cue:", res.summary())


## 分辨 .json 是 Cue 自己导出的还是 Rhubarb 的。
func _sniff_json(path: String) -> CueImportResult:
	if FileAccess.file_exists(path):
		var head := FileAccess.get_file_as_string(path).substr(0, 400)
		if head.contains("\"cue_format\""):
			return CueMarkerExport.from_json(path)
	return CueRhubarbImporter.parse(path)


## 导入带进来的新轨道要有个颜色,否则全挤在默认色上分不清。
func _ensure_tracks(names: PackedStringArray) -> void:
	var sheet := state.sheet
	var existing := {}
	for t in sheet.tracks:
		existing[t.name] = true
	var palette := [
		Color(0.40, 0.70, 1.00), Color(1.00, 0.65, 0.30), Color(0.55, 0.90, 0.55),
		Color(0.90, 0.55, 0.90), Color(0.95, 0.85, 0.40),
	]
	for n in names:
		var sn := StringName(n)
		if existing.has(sn):
			continue
		sheet.tracks.append(CueTrack.new(sn, palette[sheet.tracks.size() % palette.size()]))
	state.notify_sheet_edited()


# ── 生成剧本骨架 ────────────────────────────────────────────────────

## 五种导出共用一个保存对话框,靠 _export_kind 记住这次要写什么。
func _export_requested(kind: int) -> void:
	if state.sheet == null:
		push_error("Cue:先打开一个 CueSheet 再导出。")
		return
	if kind in [CueTransport.Export.ENVELOPE_JSON, CueTransport.Export.ENVELOPE_CSV] \
			and (state.sheet.envelope == null or not state.sheet.envelope.is_valid()):
		push_error("Cue:这个 CueSheet 还没有振幅包络。请先点「分析波形」。")
		return

	_export_kind = kind
	if _script_dialog == null:
		_script_dialog = EditorFileDialog.new()
		_script_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		_script_dialog.access = EditorFileDialog.ACCESS_RESOURCES
		_script_dialog.file_selected.connect(_do_export)
		add_child(_script_dialog)

	var base := state.sheet.resource_path.get_basename()
	if base == "":
		base = "res://cue"
	_script_dialog.clear_filters()
	match kind:
		CueTransport.Export.MARKERS_JSON:
			_script_dialog.title = "导出标记(JSON)"
			_script_dialog.add_filter("*.json", "JSON")
			_script_dialog.current_path = base + "_markers.json"
		CueTransport.Export.MARKERS_CSV:
			_script_dialog.title = "导出标记(CSV)"
			_script_dialog.add_filter("*.csv", "CSV")
			_script_dialog.current_path = base + "_markers.csv"
		CueTransport.Export.ENVELOPE_JSON:
			_script_dialog.title = "导出振幅包络(JSON)"
			_script_dialog.add_filter("*.json", "JSON")
			_script_dialog.current_path = base + "_envelope.json"
		CueTransport.Export.ENVELOPE_CSV:
			_script_dialog.title = "导出振幅包络(CSV)"
			_script_dialog.add_filter("*.csv", "CSV")
			_script_dialog.current_path = base + "_envelope.csv"
		CueTransport.Export.SCRIPT:
			_script_dialog.title = "生成剧本骨架"
			_script_dialog.add_filter("*.gd", "GDScript")
			_script_dialog.current_path = base + "_shot.gd"
	_script_dialog.popup_centered_ratio(0.6)


func _do_export(path: String) -> void:
	var sheet := state.sheet
	if sheet == null:
		return
	var err := OK
	match _export_kind:
		CueTransport.Export.MARKERS_JSON:
			err = CueMarkerExport.save_json(sheet, path)
		CueTransport.Export.MARKERS_CSV:
			err = CueMarkerExport.save_csv(sheet, path)
		CueTransport.Export.ENVELOPE_JSON:
			err = sheet.envelope.export_json(path)
		CueTransport.Export.ENVELOPE_CSV:
			err = sheet.envelope.export_csv(path)
		CueTransport.Export.SCRIPT:
			generate_script(path)
			return
		_:
			return
	if err != OK:
		push_error("Cue:写入 %s 失败(错误码 %d)。" % [path, err])
		return
	if path.begins_with("res://"):
		EditorInterface.get_resource_filesystem().update_file(path)
	print("Cue:已导出 → %s" % path)


## 只生成当前展开的轨道 —— 折叠一条轨等于"这条我现在不关心",
## 那它多半也不该出现在剧本里。口型轨几百个标记尤其不该进。
func generate_script(path: String) -> void:
	var sheet := state.sheet
	if sheet == null:
		return
	var opts := CueScriptGenerator.Options.new()
	var visible := PackedStringArray()
	for n in state.track_list():
		if not state.is_collapsed(n):
			visible.append(String(n))
	if visible.size() < state.track_list().size():
		opts.tracks = visible
	var err := CueScriptGenerator.save(sheet, path, opts)
	if err != OK:
		push_error("Cue:写入 %s 失败(错误码 %d)。" % [path, err])
		return
	EditorInterface.get_resource_filesystem().update_file(path)
	print("Cue:剧本骨架已生成 → %s" % path)


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
