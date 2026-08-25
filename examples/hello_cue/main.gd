extends Node2D

## Cue 的最小可运行示例。
##
## 两个"角色"(就是两个圆)按配音上的命名标记行动。
## 全部动作都挂在 [code]await Cue.at(&"标记名")[/code] 上,
## 没有一个写死的秒数 —— 这就是 Cue 存在的理由。
##
## 想改时间点?打开底部的 Cue 面板拖标记,代码一行都不用动。

const SHEET := preload("res://examples/hello_cue/shot_01.tres")

var _log: Array[String] = []
var _peter := {"x": -120.0, "y": 300.0, "r": 34.0, "color": Color(0.35, 0.65, 1.0)}
var _john := {"x": 640.0, "y": 300.0, "r": 34.0, "color": Color(1.0, 0.72, 0.35)}


func _ready() -> void:
	Cue.load_sheet(SHEET)
	Cue.play()
	_shot()
	# 离线渲染时放完就退出,这样 --write-movie 能自己收尾;
	# 实时预览下留着窗口,方便反复看。
	if Cue.is_movie_mode():
		Cue.finished.connect(func() -> void: get_tree().quit())


## 分镜脚本。读起来就是一条时间线。
func _shot() -> void:
	await Cue.at(&"peter_enters")
	_say("Peter 入场")
	_move(_peter, 180.0)

	await Cue.at(&"peter_line_1")
	_say("Peter:第一句")
	_pulse(_peter)

	await Cue.at(&"john_looks_up")
	_say("John 抬头")
	_move(_john, 430.0)

	await Cue.at(&"john_line_1")
	_say("John:回话")
	_pulse(_john)

	await Cue.at(&"peter_line_2")
	_say("Peter:第二句")
	_pulse(_peter)

	await Cue.at(&"both_exit")
	_say("两人退场")
	_move(_peter, -120.0)
	_move(_john, 760.0)


func _say(line: String) -> void:
	# Cue.frame() 是相对 sheet 的帧号,离线渲染时两次跑出来一模一样
	_log.append("f%03d  %s" % [Cue.frame(), line])
	print("[Cue 示例] ", _log[_log.size() - 1])


func _move(who: Dictionary, to_x: float) -> void:
	var t := create_tween()
	t.tween_method(func(v: float) -> void: who["x"] = v, who["x"], to_x, 0.35) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _pulse(who: Dictionary) -> void:
	var t := create_tween()
	t.tween_method(func(v: float) -> void: who["r"] = v, 34.0, 46.0, 0.10)
	t.tween_method(func(v: float) -> void: who["r"] = v, 46.0, 34.0, 0.22)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var vp := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.11, 0.12, 0.16))

	# 底部画一条波形,顺便展示 WaveformCache 可以直接拿来用
	_draw_waveform(Rect2(0.0, vp.y - 90.0, vp.x, 80.0))

	for who in [_peter, _john]:
		draw_circle(Vector2(who["x"], who["y"]), who["r"], who["color"])

	var font := ThemeDB.fallback_font
	var size := 15
	draw_string(font, Vector2(16, 28),
		"Cue 示例 —— 全部动作由标记驱动,没有写死的秒数",
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0.75, 0.8, 0.9))
	draw_string(font, Vector2(16, 52),
		"t = %.2fs   frame = %d   %s" % [Cue.time(), Cue.frame(),
			"离线渲染模式" if Cue.is_movie_mode() else "实时预览"],
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0.6, 0.65, 0.75))
	for i in _log.size():
		draw_string(font, Vector2(16, 90 + float(i) * 20.0), _log[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0.85, 0.88, 0.95))


func _draw_waveform(area: Rect2) -> void:
	var wf: WaveformCache = SHEET.waveform
	if wf == null or not wf.is_valid():
		return
	var dur := SHEET.duration()
	if dur <= 0.0:
		return
	var mid := area.position.y + area.size.y * 0.5
	var half := area.size.y * 0.5
	var n := wf.bucket_count()
	var pts := PackedVector2Array()
	var w := int(area.size.x)
	pts.resize(w * 2)
	for x in w:
		var b := int(float(x) / float(w) * float(n))
		if b >= n:
			break
		pts[x * 2] = Vector2(float(x), mid - wf.maxs[b] * half)
		pts[x * 2 + 1] = Vector2(float(x), mid - wf.mins[b] * half)
	draw_multiline(pts, Color(0.3, 0.4, 0.55))
	var px: float = Cue.time() / dur * area.size.x
	draw_line(Vector2(px, area.position.y), Vector2(px, area.end.y), Color(1.0, 0.4, 0.4), 2.0)
