@tool
extends EditorScript

func _run() -> void:
	var t := EditorInterface.get_editor_theme()
	print("=== 有 font 的类型 ===")
	var types := t.get_font_type_list()
	print(types)
	for ty in types:
		print("  ", ty, " -> ", t.get_font_list(ty))
	print("=== font_size 类型 ===")
	for ty in t.get_font_size_type_list():
		print("  ", ty, " -> ", t.get_font_size_list(ty))
	var base := EditorInterface.get_base_control()
	print("=== base control 回退 ===")
	print("has_theme_font('font','Label')=", base.has_theme_font("font", "Label"))
	print("get_theme_font('font','Label')=", base.get_theme_font("font", "Label"))
	print("get_theme_font_size('font_size','Label')=", base.get_theme_font_size("font_size", "Label"))
	print("=== 用到的颜色是否存在 ===")
	for c in [["dark_color_1","Editor"],["dark_color_2","Editor"],["accent_color","Editor"],
			["font_color","Editor"],["warning_color","Editor"],["error_color","Editor"],
			["property_color_z","Editor"]]:
		print("  ", c, " -> ", t.has_color(c[0], c[1]))
	print("=== 用到的图标是否存在 ===")
	for i in ["Load","Save","MainPlay","Pause","Stop","Add","AudioStreamPlayer","ZoomLess","ZoomMore"]:
		print("  ", i, " -> ", t.has_icon(i, "EditorIcons"))
