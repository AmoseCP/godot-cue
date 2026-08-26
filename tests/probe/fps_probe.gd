extends Node2D
func _ready() -> void:
	print("PROBE has_setting=", ProjectSettings.has_setting("editor/movie_writer/fps"),
		" value=", ProjectSettings.get_setting("editor/movie_writer/fps", "缺失"))
	print("PROBE Engine.max_fps=", Engine.max_fps,
		" physics_ticks=", Engine.physics_ticks_per_second)
	print("PROBE movie=", OS.has_feature("movie"))
func _process(_d: float) -> void:
	queue_redraw()
	if Engine.get_frames_drawn() >= 20:
		print("PROBE 到第 20 帧,已用时间步 = ", Engine.get_frames_drawn())
		get_tree().quit()
func _draw() -> void:
	draw_rect(Rect2(0, 0, 32, 32), Color(0.5, 0, 0))
