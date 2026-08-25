extends Node2D

## M4 确定性测试场景。
##
## 动画状态[b]只[/b]由 Cue.time() 决定,不读 delta、不读随机数、不读系统时钟。
## 用 --write-movie 渲染两次,输出的 PNG 序列必须逐帧字节一致。

const SHEET := preload("res://tests/determinism/test_sheet.tres")
const LOG_PATH := "res://tests/determinism/fire_log.txt"

var _fired: Array[String] = []
var _color := Color(0.1, 0.1, 0.15)
var _boxes: Array[Vector2] = []


func _ready() -> void:
	print("MODE movie=", OS.has_feature("movie"),
		" cmdline=", OS.get_cmdline_args(),
		" fixed_fps=", Engine.max_fps)
	Cue.load_sheet(SHEET)
	print("MODE Cue.is_movie_mode()=", Cue.is_movie_mode())
	Cue.play()
	_run()
	Cue.finished.connect(_on_done)


func _run() -> void:
	# 每个标记记录"在第几帧触发" —— 两次渲染必须完全相同。
	for name in [&"start", &"beat_a", &"beat_b", &"beat_c", &"beat_d", &"tail"]:
		await Cue.at(name)
		_fired.append("%s@f%d" % [name, Cue.frame()])
		_boxes.append(Vector2(float(_boxes.size()) * 90.0 + 40.0, 300.0))
		_color = Color.from_hsv(fmod(float(_fired.size()) * 0.17, 1.0), 0.6, 0.35)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), _color)
	var t := Cue.time()
	# 位置是 t 的纯函数
	var x := 60.0 + fmod(t, 3.0) * 180.0
	var y := 200.0 + sin(t * 3.0) * 80.0
	draw_circle(Vector2(x, y), 34.0, Color(1.0, 0.85, 0.3))
	for b in _boxes:
		draw_rect(Rect2(b, Vector2(60, 60)), Color(0.9, 0.95, 1.0))
	# 帧号条:每帧宽度不同,任何帧数偏差都会体现在像素上
	draw_rect(Rect2(0, 0, float(Cue.frame()) * 6.0, 12.0), Color(1, 0, 0))


func _on_done() -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	f.store_line("movie_mode=%s" % Cue.is_movie_mode())
	for line in _fired:
		f.store_line(line)
	f.close()
	print("MODE 触发记录 ", _fired)
	get_tree().quit()
