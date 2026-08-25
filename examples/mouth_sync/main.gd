extends Node2D

## CueMouthShape 示例:口型跟着配音动。左右两张脸对比两种驱动方式。
##
## [b]左边 —— 真口型同步[/b]:
##   Rhubarb JSON → CueRhubarbImporter → mouth 轨 → CueMouthShape → Sprite2D
##
## [b]右边 —— 响度降级方案[/b]:
##   振幅包络 → 按阈值分四档 → 同一套嘴型贴图
##   没有 Rhubarb / MFA 的时候(临时配音、非英语素材、赶工)用这个。
##   明显更糙,但零外部依赖,而且比嘴不动强得多。
##
## 嘴型贴图是运行时画出来的,所以这个示例不需要任何美术素材。
## 换成你自己的嘴型图,只要填 [member CueMouthShape.shape_textures] 就行。

const SHEET := preload("res://examples/mouth_sync/shot_mouth.tres")

## Preston Blair 的 9 个嘴型,用 (宽, 高, 是否露齿) 近似。
## A 闭嘴 / X 静止,D 最张开,F 收拢。
const SHAPES := {
	&"A": [0.62, 0.06, false],
	&"B": [0.55, 0.22, true],
	&"C": [0.66, 0.40, false],
	&"D": [0.72, 0.68, false],
	&"E": [0.46, 0.34, false],
	&"F": [0.30, 0.26, false],
	&"G": [0.52, 0.16, true],
	&"H": [0.58, 0.44, false],
	&"X": [0.50, 0.05, false],
}

var _mouth: CueMouthShape = null
var _sprite: Sprite2D = null
var _amp_mouth: CueMouthShape = null
var _amp_sprite: Sprite2D = null
var _log: Array[String] = []


func _ready() -> void:
	_build_face()

	Cue.load_sheet(SHEET)

	var textures := _make_textures()

	_mouth = CueMouthShape.new()
	_mouth.track = &"mouth"
	_mouth.rest_shape = &"X"
	_mouth.sprite = _sprite
	_mouth.shape_textures = textures
	add_child(_mouth)
	_mouth.shape_changed.connect(_on_shape_changed)

	# 同一段音频,改用响度驱动,四档开合
	_amp_mouth = CueMouthShape.new()
	_amp_mouth.source = CueMouthShape.Source.AMPLITUDE
	_amp_mouth.amplitude_shapes = [&"X", &"B", &"C", &"D"]
	_amp_mouth.amplitude_thresholds = PackedFloat32Array([0.06, 0.18, 0.38])
	_amp_mouth.sprite = _amp_sprite
	_amp_mouth.shape_textures = textures
	add_child(_amp_mouth)

	Cue.play()
	# rebuild() 要在 load_sheet() 之后调 —— 它是从当前 sheet 抓数据的
	_mouth.rebuild()
	_amp_mouth.rebuild()
	_report()

	if Cue.is_movie_mode():
		Cue.finished.connect(func() -> void: get_tree().quit())


func _report() -> void:
	print("[口型示例] mouth 轨共 %d 条口型;响度模式就绪 = %s"
		% [_mouth.entry_count(), _amp_mouth.is_ready()])


func _build_face() -> void:
	_sprite = Sprite2D.new()
	_sprite.position = Vector2(200, 250)
	add_child(_sprite)
	_amp_sprite = Sprite2D.new()
	_amp_sprite.position = Vector2(520, 250)
	add_child(_amp_sprite)


func _on_shape_changed(shape: StringName) -> void:
	_log.append("f%03d  %s" % [Cue.frame(), shape])
	if _log.size() > 14:
		_log.remove_at(0)


## 每个嘴型画成一张 128×128 的贴图。纯程序生成,结果确定。
func _make_textures() -> Dictionary:
	var out := {}
	for shape in SHAPES:
		out[shape] = _draw_mouth(SHAPES[shape][0], SHAPES[shape][1], SHAPES[shape][2])
	return out


func _draw_mouth(w: float, h: float, teeth: bool) -> ImageTexture:
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := float(size) * 0.5
	var cy := float(size) * 0.5
	var rx: float = maxf(w * float(size) * 0.5, 2.0)
	var ry: float = maxf(h * float(size) * 0.5, 1.5)

	for y in size:
		for x in size:
			var dx := (float(x) - cx) / rx
			var dy := (float(y) - cy) / ry
			var d := dx * dx + dy * dy
			if d > 1.0:
				continue
			# 上排牙齿:嘴张开时露出来的一条
			if teeth and float(y) < cy - ry * 0.25:
				img.set_pixel(x, y, Color(0.95, 0.95, 0.92))
			else:
				# 越靠中间越深,像口腔的进深
				var k: float = 1.0 - d
				img.set_pixel(x, y, Color(0.30 - 0.18 * k, 0.07, 0.10, 1.0))
	return ImageTexture.create_from_image(img)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var vp := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.13, 0.12, 0.15))

	var font := ThemeDB.fallback_font
	# 两张极简的脸,只是为了让嘴有个上下文
	_face(Vector2(200, 220))
	_face(Vector2(520, 220))
	draw_string(font, Vector2(118, 400), "口型轨(Rhubarb)",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1.0, 0.78, 0.45))
	draw_string(font, Vector2(444, 400), "响度降级方案",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.55, 0.85, 0.95))
	draw_string(font, Vector2(118, 422), "shape = %s" % _mouth.current_shape(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.7, 0.7, 0.75))
	draw_string(font, Vector2(444, 422),
		"shape = %s   振幅 %.2f" % [_amp_mouth.current_shape(), Cue.amplitude()],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.7, 0.7, 0.75))

	draw_string(font, Vector2(16, 28),
		"CueMouthShape —— 左:Rhubarb 口型轨   右:振幅包络降级方案",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.75, 0.8, 0.9))
	var t: float = Cue.time()
	draw_string(font, Vector2(700, 60), "口型轨切换记录",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.5, 0.55, 0.62))
	draw_string(font, Vector2(16, 52),
		"t = %.2fs   frame = %d" % [t, Cue.frame()],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.6, 0.65, 0.75))
	for i in _log.size():
		draw_string(font, Vector2(700, 84 + float(i) * 18.0), _log[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.8, 0.84, 0.9))

	_draw_envelope(Rect2(16.0, vp.y - 118.0, vp.x - 32.0, 44.0))

	_draw_mouth_track(Rect2(16.0, vp.y - 64.0, vp.x - 32.0, 44.0))


func _face(c: Vector2) -> void:
	draw_circle(c, 130.0, Color(0.96, 0.83, 0.70))
	draw_circle(c + Vector2(-44, -45), 14.0, Color(1, 1, 1))
	draw_circle(c + Vector2(44, -45), 14.0, Color(1, 1, 1))
	draw_circle(c + Vector2(-44, -43), 6.0, Color(0.15, 0.12, 0.10))
	draw_circle(c + Vector2(44, -43), 6.0, Color(0.15, 0.12, 0.10))


## 把振幅包络画成一条曲线,顺便标出四档的阈值线。
func _draw_envelope(area: Rect2) -> void:
	var env: CueEnvelope = SHEET.envelope
	if env == null or not env.is_valid():
		return
	draw_rect(area, Color(0.09, 0.09, 0.11))
	for th in _amp_mouth.amplitude_thresholds:
		var y := area.end.y - th * area.size.y
		draw_line(Vector2(area.position.x, y), Vector2(area.end.x, y),
			Color(1, 1, 1, 0.12), 1.0)
	var pts := PackedVector2Array()
	var w := int(area.size.x)
	pts.resize(w)
	for x in w:
		var tt := float(x) / float(w) * env.duration
		pts[x] = Vector2(area.position.x + float(x), area.end.y - env.at(tt) * area.size.y)
	draw_polyline(pts, Color(0.55, 0.85, 0.95), 1.0)
	var px := area.position.x + Cue.time() / env.duration * area.size.x
	draw_line(Vector2(px, area.position.y), Vector2(px, area.end.y), Color(1, 0.35, 0.35), 2.0)


## 底部把 mouth 轨画成一条色带,能直观看出口型的疏密和当前位置。
func _draw_mouth_track(area: Rect2) -> void:
	var dur := SHEET.duration()
	if dur <= 0.0:
		return
	draw_rect(area, Color(0.09, 0.09, 0.11))
	var mouth_markers := SHEET.in_track(&"mouth")
	for i in mouth_markers.size():
		var m := mouth_markers[i]
		var next_t: float = mouth_markers[i + 1].time if i + 1 < mouth_markers.size() else dur
		var x0 := area.position.x + m.time / dur * area.size.x
		var x1 := area.position.x + next_t / dur * area.size.x
		var shape := String(m.payload.get("shape", "X"))
		var hue := float(String("ABCDEFGHX").find(shape)) / 9.0
		var col := Color.from_hsv(hue, 0.55, 0.75) if shape != "X" else Color(0.25, 0.25, 0.3)
		draw_rect(Rect2(x0, area.position.y, maxf(x1 - x0 - 1.0, 1.0), area.size.y), col)
	var px := area.position.x + Cue.time() / dur * area.size.x
	draw_line(Vector2(px, area.position.y), Vector2(px, area.end.y), Color(1, 0.35, 0.35), 2.0)
