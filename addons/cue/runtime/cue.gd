extends Node

## Cue 运行时单例(Autoload 名 "Cue")。
##
## 典型用法:
## [codeblock]
## Cue.load_sheet(preload("res://audio/shot_03.tres"))
## Cue.play()
## await Cue.at(&"peter_arrives")
## await peter.walk_to(400)
## [/codeblock]
##
## 本文件[b]不得[/b]引用 addons/cue/editor/ 下的任何东西 —— 它必须能在
## 导出的项目和 headless 渲染中运行(PLAN D9)。

## 每个标记到点时发出。[method at] 内部就是等它。
signal marker_reached(marker_name: StringName)
## 播放到音频末尾。
signal finished()

var _sheet: CueSheet = null
var _clock: CueClock = null
var _player: AudioStreamPlayer = null
## 按时间排好序的标记,配一个只前进的指针 —— 每帧开销与标记总数无关。
var _queue: Array[CueMarker] = []
var _next: int = 0
var _playing: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = AudioStreamPlayer.new()
	_player.name = "CuePlayer"
	add_child(_player)
	_player.finished.connect(_on_stream_finished)
	set_process(false)


func load_sheet(sheet: CueSheet) -> void:
	if sheet == null:
		push_error("Cue:load_sheet() 收到 null。")
		return
	var issues := sheet.validate()
	if not issues.is_empty():
		for i in issues:
			push_error("Cue:sheet 数据有问题 —— %s" % i)
	stop()
	_sheet = sheet
	_player.stream = sheet.audio
	_clock = CueClock.new(float(sheet.fps), _player)
	_queue = sheet.sorted()
	_next = 0


func sheet() -> CueSheet:
	return _sheet


func clock() -> CueClock:
	return _clock


func is_movie_mode() -> bool:
	return _clock != null and _clock.is_movie_mode()


func play(from: float = 0.0) -> void:
	if _sheet == null:
		push_error("Cue:还没有 load_sheet(),play() 无效。")
		return
	_seek_queue(from)
	_playing = true
	if _player.stream != null:
		_player.play(from)
	_clock.start(from)
	set_process(true)


func pause() -> void:
	if not _playing:
		return
	_playing = false
	_player.stream_paused = true
	_clock.stop()
	set_process(false)


func resume() -> void:
	if _playing or _sheet == null:
		return
	_playing = true
	_player.stream_paused = false
	_clock.resume()
	set_process(true)


func stop() -> void:
	var was := _playing
	_playing = false
	if _player != null:
		_player.stop()
		_player.stream_paused = false
	if _clock != null:
		_clock.stop()
	set_process(false)
	if was:
		# 唤醒所有还挂在 at() 上的协程,否则它们会永远等下去。
		marker_reached.emit(&"")


## 跳转到指定时间。已经过去的标记不会补触发。
func seek(t: float) -> void:
	if _sheet == null:
		return
	var was := _playing
	stop()
	if was:
		play(t)
	else:
		_seek_queue(t)
		_clock.start(t)
		_clock.stop()


## 当前 sheet 时间(秒)。运行时逻辑要取时间[b]只能[/b]走这里(见 CLAUDE.md 确定性要求)。
func time() -> float:
	if _clock == null:
		return 0.0
	return _clock.now()


func frame() -> int:
	if _clock == null:
		return 0
	return _clock.frame_of(_clock.now())


## 等待标记到点。
##
## 标记不存在 → 报错并立即返回(不会死锁)。
## 标记时间已过 → 立即返回。
## 播放中途被 stop() → 返回,不会永远挂着。
func at(marker_name: StringName) -> void:
	var m := _require(marker_name)
	if m == null:
		return
	if time() >= m.time:
		return
	while _playing:
		var reached: StringName = await marker_reached
		if reached == marker_name:
			return
	# 走到这里说明播放已经停了。


## 等到标记之后再多等 [param delay] 秒。
func after(marker_name: StringName, delay: float) -> void:
	await at(marker_name)
	if delay <= 0.0:
		return
	var target := time() + delay
	while _playing and time() < target:
		await get_tree().process_frame


## 标记覆盖的时间窗 —— 从它自己到同轨的下一个标记。
## 返回 [code]{start: float, end: float}[/code];没有下一个标记时 end 是音频总长。
func window(marker_name: StringName) -> Dictionary:
	var m := _require(marker_name)
	if m == null:
		return {"start": 0.0, "end": 0.0}
	var end := _sheet.duration()
	for other in _sheet.sorted():
		if other.track == m.track and other.time > m.time:
			end = other.time
			break
	return {"start": m.time, "end": end}


## 标记 payload 里的口型序列,形如 [code][{t: float, shape: String}, ...][/code]。
## 由 Rhubarb / TextGrid 导入器写入。
func phonemes(marker_name: StringName) -> Array:
	var m := _require(marker_name)
	if m == null:
		return []
	var p: Variant = m.payload.get("phonemes", [])
	return p if p is Array else []


func markers_in(track: StringName) -> Array[CueMarker]:
	if _sheet == null:
		return []
	return _sheet.in_track(track)


func _require(marker_name: StringName) -> CueMarker:
	if _sheet == null:
		push_error("Cue:还没有 load_sheet()。")
		return null
	var m := _sheet.find(marker_name)
	if m == null:
		push_error("Cue:找不到标记「%s」。" % marker_name)
		return null
	return m


func _seek_queue(t: float) -> void:
	_queue = _sheet.sorted()
	_next = 0
	while _next < _queue.size() and _queue[_next].time < t:
		_next += 1


func _process(_delta: float) -> void:
	if not _playing:
		return
	var t := time()
	# 一帧内可能跨过多个标记(低帧率或密集口型轨),必须全部补发,
	# 且顺序与排序一致 —— 这是离线渲染可复现的前提。
	while _next < _queue.size() and _queue[_next].time <= t:
		var m := _queue[_next]
		_next += 1
		marker_reached.emit(m.name)
	if _sheet != null:
		var dur := _sheet.duration()
		if dur > 0.0 and t >= dur:
			_finish()


func _on_stream_finished() -> void:
	# 离线渲染时音频流的 finished 与帧时钟无关,一律以帧时钟为准。
	if _clock != null and _clock.is_movie_mode():
		return
	_finish()


func _finish() -> void:
	if not _playing:
		return
	_playing = false
	_clock.stop()
	set_process(false)
	marker_reached.emit(&"")
	finished.emit()
