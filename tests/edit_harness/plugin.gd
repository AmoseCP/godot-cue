@tool
extends EditorPlugin

## M3 验收:连续 20 次混合编辑 → 逐步撤销到底 → 逐步重做到底 → 存盘重载比对。
## 必须跑在真实编辑器里,因为 EditorUndoRedoManager 只有编辑器才有。

const SHEET_PATH := "user://cue_m3_test.tres"
const EDITS := 20

var _pass := 0
var _fail := 0


func _enter_tree() -> void:
	call_deferred("_run")


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("EDIT FAIL  ", what)


func _run() -> void:
	await get_tree().process_frame
	var undo := get_undo_redo()

	var sheet := CueSheet.new()
	sheet.fps = 30
	sheet.audio_path = "res://tests/probe/tone_1s.wav"
	sheet.waveform = CueWaveformBuilder.new().build(
		CuePcmReader.read_wav_file(sheet.audio_path), 256)
	ResourceSaver.save(sheet, SHEET_PATH)
	sheet.take_over_path(SHEET_PATH)

	var panel := CuePanel.new()
	panel.setup(undo)
	EditorInterface.get_base_control().add_child(panel)
	await get_tree().process_frame
	panel.open_sheet(sheet)
	await get_tree().process_frame

	var hid := undo.get_object_history_id(sheet)
	var ur := undo.get_history_undo_redo(hid)
	print("EDIT history_id(sheet)=", hid, " (GLOBAL=", EditorUndoRedoManager.GLOBAL_HISTORY, ")")
	var probe_marker := CueMarker.new(&"probe", 1.0)
	print("EDIT history_id(新建 CueMarker)=", undo.get_object_history_id(probe_marker))
	print("EDIT history_id(panel 节点)=", undo.get_object_history_id(panel))
	print("EDIT history_id(WaveformCache)=", undo.get_object_history_id(sheet.waveform))
	print("EDIT sheet.resource_path=", sheet.resource_path)

	# ── 20 次混合编辑 ────────────────────────────────────────────────
	# 只在 undo 栈真的长高了之后才拍快照 —— 否则"没提交成功的编辑"
	# 会让快照数和 undo 步数对不上,撤销比对整体错位一格。
	var snaps: Array = [_snapshot(sheet)]
	var names: Array[StringName] = []

	for i in EDITS:
		var depth_before := ur.get_history_count()
		match i % 5:
			0:      # 加
				panel.call("_add_marker", 0.05 * float(i + 1))
				panel.call("_cancel_rename")
				names.append(sheet.markers[sheet.markers.size() - 1].name)
			1:      # 再加一个,保证删除后不会清空
				panel.call("_add_marker", 0.05 * float(i + 1) + 0.011)
				panel.call("_cancel_rename")
				names.append(sheet.markers[sheet.markers.size() - 1].name)
			2:      # 改名(名字保证不重复,一定能提交)
				var m1 := sheet.find(names[names.size() - 1])
				var nn := StringName("轨_%d" % i)
				panel.call("_rename_marker", m1, nn)
				names[names.size() - 1] = nn
			3:      # 移动
				var m2 := sheet.find(names[0])
				panel.call("_move_marker", m2, m2.time, m2.time + 0.11)
			4:      # 删
				var m3 := sheet.find(names[0])
				panel.call("_delete_marker", m3)
				names.remove_at(0)
		await get_tree().process_frame
		var grew := ur.get_history_count() > depth_before
		_ok(grew, "第 %d 次编辑(类型 %d)应该产生一条 undo 记录" % [i, i % 5])
		if grew:
			snaps.append(_snapshot(sheet))

	var committed: int = snaps.size() - 1
	print("EDIT 提交了 %d 次编辑,最终 %d 个标记" % [committed, sheet.markers.size()])
	_ok(committed == EDITS, "应有 %d 次编辑,实际 %d" % [EDITS, committed])
	_ok(sheet.markers.size() > 0, "编辑后还有标记")

	# ── 逐步撤销到底 ────────────────────────────────────────────────
	var undone := 0
	while ur.has_undo() and undone < committed:
		ur.undo()
		await get_tree().process_frame
		undone += 1
		var expect: Array = snaps[committed - undone]
		var got: Array = _snapshot(sheet)
		_ok(got == expect, "撤销第 %d 步后状态应为 %s,实际 %s" % [undone, expect, got])
	print("EDIT 撤销了 %d 步" % undone)
	_ok(undone == committed, "应能撤销全部 %d 步,实际 %d" % [committed, undone])
	_ok(_snapshot(sheet) == snaps[0], "全部撤销后回到初始空状态")

	# ── 逐步重做到底 ────────────────────────────────────────────────
	var redone := 0
	while ur.has_redo() and redone < committed:
		ur.redo()
		await get_tree().process_frame
		redone += 1
		var expect: Array = snaps[redone]
		var got: Array = _snapshot(sheet)
		_ok(got == expect, "重做第 %d 步后状态应为 %s,实际 %s" % [redone, expect, got])
	print("EDIT 重做了 %d 步" % redone)
	_ok(redone == committed, "应能重做全部 %d 步,实际 %d" % [committed, redone])
	_ok(_snapshot(sheet) == snaps[committed], "全部重做后回到编辑终点")

	# ── 存盘 → 重载 → 逐条比对 ──────────────────────────────────────
	var before: Array = _snapshot(sheet)
	panel.call("save_sheet")
	await get_tree().process_frame
	var reloaded: CueSheet = ResourceLoader.load(SHEET_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	_ok(reloaded != null, "重载 .tres 成功")
	if reloaded != null:
		var after: Array = _snapshot(reloaded)
		_ok(after == before, "重载后标记逐条一致\n  存前 %s\n  存后 %s" % [before, after])
		_ok(reloaded.fps == sheet.fps, "fps 往返一致")
		_ok(reloaded.waveform != null and reloaded.waveform.is_valid(), "波形缓存随 .tres 一起存下来了")

	# ── 重名必须被拒绝 ──────────────────────────────────────────────
	if sheet.markers.size() >= 2:
		var a := sheet.sorted()[0]
		var b := sheet.sorted()[1]
		var n_before: int = sheet.markers.size()
		var snapshot_before: Array = _snapshot(sheet)
		panel.call("_rename_marker", b, a.name)
		await get_tree().process_frame
		_ok(_snapshot(sheet) == snapshot_before, "改成已存在的名字被拒绝,数据未变")
		_ok(not sheet.validate().is_empty() == false, "拒绝后数据仍然健康")

	panel.queue_free()
	print("EDIT RESULT ", "PASS" if _fail == 0 else "FAIL", "  %d 通过 / %d 失败" % [_pass, _fail])


## 标记集合的确定性快照:排序后的 (名字, 毫秒, 轨道) 三元组。
func _snapshot(sheet: CueSheet) -> Array:
	sheet.invalidate()
	var out: Array = []
	for m in sheet.sorted():
		out.append("%s@%d/%s" % [m.name, int(round(m.time * 1000.0)), m.track])
	return out
