class_name CueMouthShape extends Node

## 把 Cue 的口型数据变成实际的嘴型切换。
##
## 两种数据来源:
##
## [b]TRACK[/b] —— 直接读某条轨道上的标记,每个标记的
## [code]payload.shape[/code] 就是那一刻的嘴型。Rhubarb 导入器默认产出这种。
##
## [b]MARKER_PAYLOAD[/b] —— 读某个对白标记 [code]payload.phonemes[/code] 里的
## 序列(相对该标记的偏移),即 [method Cue.phonemes] 返回的东西。
## 整句被挪动时口型会跟着走。
##
## [b]确定性[/b]:[method shape_at] 是时间的[b]纯函数[/b] —— 不累加 delta、
## 不记忆上一帧状态。所以拖动播放头能正确预览,离线渲染两次结果一致。
##
## 典型用法:
## [codeblock]
## var mouth := CueMouthShape.new()
## mouth.track = &"mouth"
## mouth.sprite = $Peter/Mouth               # 一个 Sprite2D
## mouth.shape_textures = {&"A": tex_a, &"B": tex_b, ...}
## add_child(mouth)
## [/codeblock]
##
## 不想用贴图的话,连 [signal shape_changed] 自己画也行。

signal shape_changed(shape: StringName)

enum Source {
	TRACK,            ## 读整条轨道上的标记
	MARKER_PAYLOAD,   ## 读某个标记 payload 里的 phonemes 序列
	AMPLITUDE,        ## 没有口型数据时的降级方案:按响度分档开合
}

@export var source: Source = Source.TRACK:
	set(v):
		source = v
		rebuild()

## [code]Source.TRACK[/code] 时读哪条轨。
@export var track: StringName = &"mouth":
	set(v):
		track = v
		if source == Source.TRACK:
			rebuild()

## [code]Source.MARKER_PAYLOAD[/code] 时读哪个标记。
@export var marker: StringName = &"":
	set(v):
		marker = v
		if source == Source.MARKER_PAYLOAD:
			rebuild()

## 目标节点。支持 [Sprite2D] / [TextureRect](换 texture)
## 和 [AnimatedSprite2D](换 animation,没有同名动画就当帧号用)。
## 留空则只发 [signal shape_changed]。
@export var sprite: Node = null

## 嘴型代号 → 贴图。Rhubarb 用 Preston Blair 的 A~H 加静止的 X。
@export var shape_textures: Dictionary = {}

## 序列开始之前显示哪个嘴型。
@export var rest_shape: StringName = &"X"

## [code]Source.AMPLITUDE[/code] 时:各档位对应的嘴型,从静到响。
## 长度必须比 [member amplitude_thresholds] 多一个。
@export var amplitude_shapes: Array[StringName] = [&"X", &"B", &"C", &"D"]

## [code]Source.AMPLITUDE[/code] 时的分档阈值,升序,0..1。
@export var amplitude_thresholds: PackedFloat32Array = PackedFloat32Array([0.06, 0.18, 0.38])

## Cue 自动加载的路径。做成可配置是为了让这个脚本
## [b]不必[/b]在解析期引用全局的 Cue 标识符 —— 插件扫描顺序早于
## 自动加载注册,直接写 Cue 会在全新项目里报 "Cannot infer the type"。
@export var cue_path: NodePath = ^"/root/Cue"

var _times: PackedFloat32Array = PackedFloat32Array()
var _shapes: Array[StringName] = []
var _current: StringName = &""
var _cue: Node = null


func _ready() -> void:
	_cue = get_node_or_null(cue_path)
	if _cue == null:
		push_error("Cue:CueMouthShape 找不到 Cue 自动加载(%s)。" % cue_path)
		set_process(false)
		return
	# 换 sheet 时自动重建,不必调用方记得手动调
	if _cue.has_signal("sheet_loaded") and not _cue.sheet_loaded.is_connected(_on_sheet_loaded):
		_cue.sheet_loaded.connect(_on_sheet_loaded)
	rebuild()
	set_process(true)


func _exit_tree() -> void:
	if _cue != null and _cue.has_signal("sheet_loaded") \
			and _cue.sheet_loaded.is_connected(_on_sheet_loaded):
		_cue.sheet_loaded.disconnect(_on_sheet_loaded)


func _on_sheet_loaded(_sheet: CueSheet) -> void:
	rebuild()


## 从当前 sheet 重新抓取口型序列。
##
## 换 sheet 时会由 [signal Cue.sheet_loaded] 自动触发,通常不用手动调 ——
## 只有在运行中改了 [member track] / [member marker] / [member source]
## 之外的东西(比如直接往 sheet 里塞标记)才需要。
func rebuild() -> void:
	_times = PackedFloat32Array()
	_shapes = []
	_current = &""
	if _cue == null:
		return
	var sheet: CueSheet = _cue.call("sheet")
	if sheet == null:
		return

	if source == Source.AMPLITUDE:
		# 响度模式不预先展开成序列 —— shape_at() 直接查包络,
		# 这样内存占用与音频长度无关,而且仍然是纯函数。
		if sheet.envelope == null or not sheet.envelope.is_valid():
			push_error("Cue:CueMouthShape 用的是响度模式,但这个 CueSheet 还没有振幅包络。请在 Cue 面板里点「分析波形」。")
		return

	var entries: Array = []
	if source == Source.TRACK:
		for m in sheet.in_track(track):
			entries.append([m.time, StringName(String(m.payload.get("shape", rest_shape)))])
	else:
		var host := sheet.find(marker)
		if host == null:
			push_error("Cue:CueMouthShape 找不到标记「%s」。" % marker)
			return
		for e in _cue.call("phonemes", marker) as Array:
			if e is Dictionary:
				entries.append([host.time + float(e.get("t", 0.0)),
					StringName(String(e.get("shape", rest_shape)))])

	# in_track() 已经排好序了,但 payload 里的序列不保证,统一再排一次。
	# 时间相同时按嘴型代号排,保证是全序 —— 否则同一份数据两次渲染
	# 可能挑到不同的嘴型(见 CLAUDE.md 确定性要求)。
	entries.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0] == b[0]:
			return String(a[1]) < String(b[1])
		return a[0] < b[0])

	_times.resize(entries.size())
	_shapes.resize(entries.size())
	for i in entries.size():
		_times[i] = entries[i][0]
		_shapes[i] = entries[i][1]


## [param t] 时刻应该显示的嘴型。[b]纯函数[/b] —— 同样的 t 永远给同样的结果。
func shape_at(t: float) -> StringName:
	if source == Source.AMPLITUDE:
		return _shape_from_amplitude(t)
	if _times.is_empty():
		return rest_shape
	# before=false:相等时返回它们之后的位置,于是 i-1 就是"最后一个 <= t"
	var i := _times.bsearch(t, false)
	if i <= 0:
		return rest_shape
	return _shapes[i - 1]


## 响度 → 档位 → 嘴型。档位数由阈值个数决定,超出 shapes 长度就取最后一个。
func _shape_from_amplitude(t: float) -> StringName:
	if _cue == null or amplitude_shapes.is_empty():
		return rest_shape
	var lv: int = _cue.call("amplitude_level", amplitude_thresholds, t)
	return amplitude_shapes[clampi(lv, 0, amplitude_shapes.size() - 1)]


func current_shape() -> StringName:
	return _current


func entry_count() -> int:
	return _times.size()


## 响度模式下没有预展开的序列,用这个判断数据是否就绪。
func is_ready() -> bool:
	if source != Source.AMPLITUDE:
		return not _times.is_empty()
	if _cue == null:
		return false
	var sheet: CueSheet = _cue.call("sheet")
	return sheet != null and sheet.envelope != null and sheet.envelope.is_valid()


func _process(_delta: float) -> void:
	if _cue == null:
		return
	var t: float = _cue.call("time")
	var s := shape_at(t)
	if s == _current:
		return
	_current = s
	_apply(s)
	shape_changed.emit(s)


func _apply(s: StringName) -> void:
	if sprite == null:
		return
	if sprite is AnimatedSprite2D:
		var a := sprite as AnimatedSprite2D
		if a.sprite_frames != null and a.sprite_frames.has_animation(String(s)):
			a.animation = String(s)
		return
	if shape_textures.has(s):
		var tex: Texture2D = shape_textures[s]
		if sprite is Sprite2D:
			(sprite as Sprite2D).texture = tex
		elif sprite is TextureRect:
			(sprite as TextureRect).texture = tex
