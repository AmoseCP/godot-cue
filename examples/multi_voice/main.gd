extends Node2D

## 多角色分轨示例(D10′)。
##
## Peter 和 John 分开录音,是两个独立的 .wav,在 sheet 里各占一个
## [CueAudioSegment],John 那段带 1.9 秒的偏移。
##
## 关键在于:**标记时间轴是统一的**。
## [code]await Cue.at(&"john_line_1")[/code] 不必关心那句话录在哪个文件里,
## 也不必关心它在自己那段音频里的第几秒。分镜脚本只看一条时间轴。

const SHEET := preload("res://examples/multi_voice/scene_01.tres")

var _peter := {"x": 200.0, "scale": 1.0, "lit": 0.0}
var _john := {"x": 520.0, "scale": 1.0, "lit": 0.0}
var _log: Array[String] = []


func _ready() -> void:
	Cue.load_sheet(SHEET)
	Cue.play()
	_scene()
	# 离线渲染时按[b]固定帧号[/b]收尾,不用 Cue.finished 信号 ——
	# 信号触发的时刻和"已经写出多少帧"之间没有硬绑定,
	# 收尾帧数会浮动,逐帧比对就不稳。帧号是确定的,信号不是。
	if Cue.is_movie_mode():
		set_process(true)


func _scene() -> void:
	await Cue.at(&"peter_line_1")
	_beat("Peter:第一句", _peter)
	await Cue.at(&"peter_line_2")
	_beat("Peter:第二句", _peter)
	await Cue.at(&"john_line_1")
	_beat("John:接话", _john)
	await Cue.at(&"john_line_2")
	_beat("John:第二句", _john)


func _beat(line: String, who: Dictionary) -> void:
	_log.append("f%03d  %s" % [Cue.frame(), line])
	var t := create_tween()
	t.tween_method(func(v: float) -> void: who["scale"] = v, 1.0, 1.18, 0.10)
	t.tween_method(func(v: float) -> void: who["scale"] = v, 1.18, 1.0, 0.25)


const LAST_FRAME := 102


func _process(_delta: float) -> void:
	if Cue.is_movie_mode() and Engine.get_frames_drawn() >= LAST_FRAME:
		get_tree().quit()
	# 高亮"这一刻哪段音频在响" —— segment_at() 是纯查询,不读播放器状态
	var t: float = Cue.time()
	var seg := SHEET.segment_at(t)
	_peter["lit"] = 1.0 if (seg != null and seg.name == &"Peter") else 0.0
	_john["lit"] = 1.0 if (seg != null and seg.name == &"John") else 0.0
	queue_redraw()


func _draw() -> void:
	var vp := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.12, 0.12, 0.15))
	var font := ThemeDB.fallback_font

	_actor(_peter, Vector2(200, 210), Color(0.40, 0.70, 1.00), "Peter", font)
	_actor(_john, Vector2(520, 210), Color(1.00, 0.65, 0.30), "John", font)

	draw_string(font, Vector2(16, 28),
		"多角色分轨 —— 两个独立 .wav,一条统一的标记时间轴",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.75, 0.8, 0.9))
	var t: float = Cue.time()
	draw_string(font, Vector2(16, 52),
		"t = %.2fs   frame = %d   总长 %.2fs" % [t, Cue.frame(), SHEET.duration()],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.6, 0.65, 0.75))
	for i in _log.size():
		draw_string(font, Vector2(700, 90 + float(i) * 20.0), _log[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.82, 0.86, 0.92))

	_draw_segments(Rect2(16.0, vp.y - 130.0, vp.x - 32.0, 100.0))


func _actor(who: Dictionary, pos: Vector2, col: Color, name: String, font: Font) -> void:
	var r: float = 78.0 * float(who["scale"])
	var lit: float = who["lit"]
	draw_circle(pos, r + 6.0 * lit, Color(col, 0.18 + 0.35 * lit))
	draw_circle(pos, r, Color(0.95, 0.84, 0.72).lerp(col, 0.15 + 0.25 * lit))
	draw_string(font, pos + Vector2(-30, 110), name,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, col)


## 把两段音频画成上下两条带,一眼看出各自覆盖的时间范围和偏移。
func _draw_segments(area: Rect2) -> void:
	var dur := SHEET.duration()
	if dur <= 0.0:
		return
	var segs := SHEET.all_segments()
	var font := ThemeDB.fallback_font
	var h := area.size.y / float(maxi(segs.size(), 1))
	for i in segs.size():
		var seg := segs[i]
		var band := Rect2(area.position.x, area.position.y + h * float(i), area.size.x, h - 4.0)
		draw_rect(band, Color(0.08, 0.08, 0.10))
		var x0 := area.position.x + seg.offset / dur * area.size.x
		var x1 := area.position.x + seg.end() / dur * area.size.x
		var col := Color(0.40, 0.70, 1.00) if i == 0 else Color(1.00, 0.65, 0.30)
		draw_rect(Rect2(x0, band.position.y, x1 - x0, band.size.y), Color(col, 0.20))

		# 每段自己的波形,从自己的缓存里读
		var wf: WaveformCache = seg.waveform
		if wf != null and wf.is_valid():
			var mid := band.position.y + band.size.y * 0.5
			var half := band.size.y * 0.5 - 2.0
			var w := int(x1 - x0)
			if w > 1:
				var pts := PackedVector2Array()
				pts.resize(w * 2)
				for k in w:
					var b := int(float(k) / float(w) * float(wf.bucket_count()))
					b = clampi(b, 0, wf.bucket_count() - 1)
					pts[k * 2] = Vector2(x0 + float(k), mid - wf.maxs[b] * half)
					pts[k * 2 + 1] = Vector2(x0 + float(k), mid - wf.mins[b] * half)
				draw_multiline(pts, col)
		draw_string(font, Vector2(area.position.x + 4.0, band.position.y + 14.0),
			"%s  offset %.2fs" % [seg.label(), seg.offset],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.7, 0.75, 0.82))

	var px := area.position.x + Cue.time() / dur * area.size.x
	draw_line(Vector2(px, area.position.y), Vector2(px, area.end.y), Color(1, 0.35, 0.35), 2.0)
