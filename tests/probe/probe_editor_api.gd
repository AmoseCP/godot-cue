extends SceneTree

func _init() -> void:
	for cls in ["EditorPlugin", "EditorUndoRedoManager", "EditorInterface", "EditorInspectorPlugin"]:
		print("=== ", cls, " ===")
		var want: Array = {
			"EditorPlugin": ["add_control_to_bottom_panel", "remove_control_from_bottom_panel",
				"add_autoload_singleton", "remove_autoload_singleton", "get_undo_redo",
				"add_inspector_plugin", "remove_inspector_plugin", "make_bottom_panel_item_visible",
				"hide_bottom_panel", "_handles", "_edit", "_make_visible"],
			"EditorUndoRedoManager": ["create_action", "commit_action", "add_do_method",
				"add_undo_method", "add_do_property", "add_undo_property", "add_do_reference",
				"add_undo_reference"],
			"EditorInterface": ["get_editor_theme", "get_base_control", "get_selection",
				"get_editor_settings", "get_resource_filesystem", "save_resource",
				"get_editor_scale", "edit_resource", "inspect_object"],
			"EditorInspectorPlugin": ["_can_handle", "_parse_begin", "_parse_property", "add_custom_control"],
		}[cls]
		for m in want:
			print("  %s%s" % [m, "" if ClassDB.class_has_method(cls, m, true) else "   <<< 缺失"])
	print("=== 枚举/其他 ===")
	print("  UndoRedo.MERGE_ENDS=", UndoRedo.MERGE_ENDS, " MERGE_ALL=", UndoRedo.MERGE_ALL, " MERGE_DISABLE=", UndoRedo.MERGE_DISABLE)
	print("  Engine.get_frames_drawn 存在=", ClassDB.class_has_method("Engine", "get_frames_drawn", true))
	print("  AudioServer.get_time_since_last_mix=", ClassDB.class_has_method("AudioServer", "get_time_since_last_mix", true))
	print("  AudioStreamPlayer.get_playback_position=", ClassDB.class_has_method("AudioStreamPlayer", "get_playback_position", true))
	quit()
