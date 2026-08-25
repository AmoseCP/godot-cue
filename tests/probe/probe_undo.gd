extends SceneTree

func _init() -> void:
	print("=== EditorUndoRedoManager 方法 ===")
	for m in ["create_action","commit_action","is_committing_action","get_history_undo_redo",
			"get_object_history_id","add_do_method","add_undo_method","undo","redo",
			"add_do_reference","add_undo_reference","clear_history"]:
		print("  ", m, " = ", ClassDB.class_has_method("EditorUndoRedoManager", m, true))
	print("=== 常量 ===")
	print(ClassDB.class_get_integer_constant_list("EditorUndoRedoManager"))
	for c in ClassDB.class_get_integer_constant_list("EditorUndoRedoManager"):
		print("  ", c, " = ", ClassDB.class_get_integer_constant("EditorUndoRedoManager", c))
	print("=== UndoRedo 方法 ===")
	for m in ["undo","redo","has_undo","has_redo","get_action_name","get_history_count","clear_history"]:
		print("  ", m, " = ", ClassDB.class_has_method("UndoRedo", m, true))
	quit()
