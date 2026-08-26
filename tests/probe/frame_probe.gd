extends Node2D

## 实测:Movie Maker 下 Engine.get_process_frames() 与
## Engine.get_frames_drawn() 是不是一一对应。
## CueClock 用的是前者,而输出的 PNG 帧数对应的是后者。

var _rows: Array[String] = []

func _process(_d: float) -> void:
	var drawn := Engine.get_frames_drawn()
	var proc := Engine.get_process_frames()
	_rows.append("%d,%d,%d" % [drawn, proc, proc - drawn])
	queue_redraw()
	if drawn > 90:
		var diffs := {}
		for r in _rows:
			var d := r.split(",")[2]
			diffs[d] = int(diffs.get(d, 0)) + 1
		print("PROBE movie=", OS.has_feature("movie"),
			" 采样 ", _rows.size(), " 帧;proc-drawn 的取值分布 = ", diffs)
		print("PROBE 头 3 行 = ", _rows.slice(0, 3))
		print("PROBE 尾 3 行 = ", _rows.slice(_rows.size() - 3))
		get_tree().quit()

func _draw() -> void:
	draw_rect(Rect2(0, 0, 64, 64), Color(float(Engine.get_frames_drawn() % 255) / 255.0, 0, 0))
