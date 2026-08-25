@tool
extends EditorPlugin

## M0 验收:反复启用/禁用 Cue,断言底部面板按钮数和 autoload 数每轮都回到原点。

const ROUNDS := 10


func _enter_tree() -> void:
	call_deferred("_run")


func _run() -> void:
	var base := EditorInterface.get_base_control()
	var before_nodes := _count_nodes(base)
	var ok := true

	for i in ROUNDS:
		EditorInterface.set_plugin_enabled("cue", false)
		await get_tree().process_frame
		var off_autoload := ProjectSettings.has_setting("autoload/Cue")
		EditorInterface.set_plugin_enabled("cue", true)
		await get_tree().process_frame
		var on_autoload := ProjectSettings.has_setting("autoload/Cue")
		if off_autoload:
			print("TOGGLE FAIL 第 %d 轮:禁用后 autoload/Cue 仍在" % i)
			ok = false
		if not on_autoload:
			print("TOGGLE FAIL 第 %d 轮:启用后 autoload/Cue 缺失" % i)
			ok = false

	EditorInterface.set_plugin_enabled("cue", false)
	await get_tree().process_frame
	var after_nodes := _count_nodes(base)
	print("TOGGLE 节点数 前=%d 后=%d 差=%d" % [before_nodes, after_nodes, after_nodes - before_nodes])
	if after_nodes > before_nodes:
		print("TOGGLE FAIL:禁用后残留 %d 个节点" % (after_nodes - before_nodes))
		ok = false
	EditorInterface.set_plugin_enabled("cue", true)
	await get_tree().process_frame
	print("TOGGLE RESULT ", "PASS" if ok else "FAIL", " (", ROUNDS, " 轮)")


func _count_nodes(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count_nodes(ch)
	return c
