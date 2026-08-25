@tool
class_name CueInspectorPlugin extends EditorInspectorPlugin

## 在 CueSheet 的 Inspector 顶部加一排按钮,省掉"先打开面板再打开文件"两步。

signal open_requested(sheet: CueSheet)


func _can_handle(object: Object) -> bool:
	return object is CueSheet


func _parse_begin(object: Object) -> void:
	var sheet := object as CueSheet
	var box := VBoxContainer.new()

	var open_btn := Button.new()
	open_btn.text = "在 Cue 面板中打开"
	open_btn.pressed.connect(func() -> void: open_requested.emit(sheet))
	box.add_child(open_btn)

	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_font_size_override("font_size", 11)
	info.text = _describe(sheet)
	box.add_child(info)

	add_custom_control(box)


func _describe(sheet: CueSheet) -> String:
	var lines := PackedStringArray()
	lines.append("标记 %d 个 · 轨道 %d 条 · %d fps" % [sheet.markers.size(), sheet.tracks.size(), sheet.fps])
	var wf := sheet.waveform
	if wf == null or not wf.is_valid():
		lines.append("波形:未分析")
	else:
		var path := sheet.audio_path
		var stale := path != "" and not wf.matches(path)
		lines.append("波形:%d 个峰值桶 · %.2fs · %d Hz%s"
			% [wf.bucket_count(), wf.duration, wf.mix_rate, "(音频已变,建议重新分析)" if stale else ""])
	var issues := sheet.validate()
	if not issues.is_empty():
		lines.append("⚠ " + "; ".join(issues))
	return "\n".join(lines)
