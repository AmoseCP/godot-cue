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
## 换了 sheet。依赖 sheet 数据的节点(比如 [CueMouthShape])靠它自动刷新,
## 免得每次 load_sheet() 之后都要手动去调一遍 rebuild()。
signal sheet_loaded(sheet: CueSheet)

var _sheet: CueSheet = null
var _clock: CueClock = null
## 每个音频片段一个播放器,下标与 [method CueSheet.all_segments] 对齐。
var _players: Array[AudioStreamPlayer] = []
var _segments: Array[CueAudioSegment] = []
var _started: Array[bool] = []
## 按时间排好序的标记,配一个只前进的指针 —— 每帧开销与标记总数无关。
var _queue: Array[CueMarker] = []
var _next: int = 0
var _playing: bool = false
## 播放轮次。stop() 和播放自然结束时 +1。
##
## [method at] 用它判断"这一轮播放是否已经作废",而[b]不是[/b]看
## [member _playing] —— `_playing` 在"还没调 play()"和"暂停中"这两种情况下
## 同样是 false,拿它当循环条件会让这两种情况下的 await [b]立刻返回[/b]:
## 先起协程再 play()、或者暂停期间新起的 await,整段分镜会在一帧里跑完。
var _generation: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


## 把每段音频摆到正确的播放位置:已经开始的从段内偏移处播,还没到的先不动。
func _start_segments_at(t: float) -> void:
	for i in _segments.size():
		var seg := _segments[i]
		var p := _players[i]
		p.stop()
		p.stream_paused = false
		if seg.muted or seg.stream == null or t >= seg.end():
			_started[i] = t >= seg.end()
			continue
		if seg.covers(t):
			p.play(seg.local_time(t))
			_started[i] = true
		else:
			_started[i] = false        # 还没轮到,等 _process 推到再起播


## 当前时刻该拿哪个播放器当时间锚点。没有片段覆盖(空隙)时返回 -1。
func _anchor_index(t: float) -> int:
	for i in _segments.size():
		if _segments[i].covers(t) and _players[i].playing:
			return i
	return -1


func _exit_tree() -> void:
	# 自动加载是最后才被拆掉的,退出时自己收个尾。
	#
	# 注意:这[b]不能[/b]消除进程退出时的
	# "1 resources still in use at exit" —— 那是引擎自身的关闭顺序问题,
	# 用一个裸 AudioStreamPlayer 播放 AudioStreamWAV 再退出即可复现,
	# 全程不涉及 Cue(见 NOTES.md M6)。这里做清理只是卫生习惯。
	for p in _players:
		if is_instance_valid(p):
			p.stop()
			p.stream = null
	_players.clear()
	_segments.clear()
	_sheet = null
	_queue.clear()


## 按片段重建播放器,一段一个。
##
## 自动加载之间的 _ready 顺序是按注册顺序来的,别的自动加载完全可能在
## Cue._ready() 之前就调 load_sheet(),所以这里不能依赖 _ready 已经跑过。
func _rebuild_players() -> void:
	for p in _players:
		if is_instance_valid(p):
			p.stop()
			p.queue_free()
	_players.clear()
	_started.clear()
	_segments = _sheet.all_segments() if _sheet != null else ([] as Array[CueAudioSegment])
	for i in _segments.size():
		var seg := _segments[i]
		var p := AudioStreamPlayer.new()
		p.name = "CuePlayer%d" % i
		p.stream = seg.stream
		p.volume_db = seg.gain_db
		add_child(p)
		_players.append(p)
		_started.append(false)


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
	_rebuild_players()
	_clock = CueClock.new(float(sheet.fps), null)
	_queue = sheet.sorted()
	_next = 0
	sheet_loaded.emit(sheet)


func sheet() -> CueSheet:
	return _sheet


func clock() -> CueClock:
	return _clock


func is_playing() -> bool:
	return _playing


func is_movie_mode() -> bool:
	return _clock != null and _clock.is_movie_mode()


func play(from: float = 0.0) -> void:
	if _sheet == null:
		push_error("Cue:还没有 load_sheet(),play() 无效。")
		return
	_seek_queue(from)
	_playing = true
	_clock.start(from)
	_start_segments_at(from)
	set_process(true)


func pause() -> void:
	if not _playing:
		return
	_playing = false
	for p in _players:
		p.stream_paused = true
	_clock.stop()
	set_process(false)


func resume() -> void:
	if _playing or _sheet == null:
		return
	_playing = true
	for p in _players:
		p.stream_paused = false
	_clock.resume()
	set_process(true)


func stop() -> void:
	var was := _playing
	_playing = false
	for p in _players:
		if is_instance_valid(p):
			p.stop()
			p.stream_paused = false
	for i in _started.size():
		_started[i] = false
	if _clock != null:
		_clock.player = null
		_clock.stop()
	set_process(false)
	if was:
		# 这一轮作废,唤醒所有还挂在 at() 上的协程,否则它们会永远等下去
		_generation += 1
		marker_reached.emit(&"")


## 跳转到指定时间。
##
## [b]不会打断挂在 [method at] 上的协程[/b] —— 拖播放头、跳到某个节拍
## 都是正常操作,不该让分镜脚本以为播放结束了。
##
## 向前跳时,被跨过去的标记按"已经过去"处理并逐个放行等待者 ——
## 这与 [method at] 的既有规则一致(标记时间已过就立即返回),
## 否则那些协程会永远等一个不会再来的信号。
func seek(t: float) -> void:
	if _sheet == null:
		return
	var from_t := time()
	var skipped: Array[StringName] = []
	if t > from_t:
		for m in _queue:
			if m.time > from_t and m.time <= t:
				skipped.append(m.name)

	# 先把时钟和队列摆到新位置,再放行 —— 顺序反了的话,
	# 被唤醒的协程紧接着调 at() 时读到的还是旧时间。
	_seek_queue(t)
	_clock.start(t)
	if _playing:
		_start_segments_at(t)
	else:
		_clock.stop()

	for n in skipped:
		marker_reached.emit(n)


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
## 播放中途被 [method stop] 或播放结束 → 返回,不会永远挂着。
##
## [b]可以在 play() 之前就 await[/b],也可以在暂停期间 await ——
## 判据是"这一轮播放有没有作废",不是"此刻是否正在播"。
func at(marker_name: StringName) -> void:
	var m := _require(marker_name)
	if m == null:
		return
	if time() >= m.time:
		return
	var gen := _generation
	while _generation == gen:
		var reached: StringName = await marker_reached
		if reached == marker_name:
			return
	# 走到这里说明这一轮播放已经作废(stop() 或播放结束)。


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


## 当前(或指定)时刻的振幅,0..1。没有包络数据时返回 0。
##
## 这是"按响度驱动嘴型"的降级方案入口,见 [CueEnvelope]。
## 是时间的纯函数,不破坏离线渲染的确定性。
func amplitude(t: float = -1.0) -> float:
	if _sheet == null or _sheet.envelope == null:
		return 0.0
	return _sheet.envelope.at(time() if t < 0.0 else t)


## 按阈值分档的响度,0..thresholds.size()。
func amplitude_level(thresholds: PackedFloat32Array, t: float = -1.0) -> int:
	if _sheet == null or _sheet.envelope == null:
		return 0
	return _sheet.envelope.level(time() if t < 0.0 else t, thresholds)


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


func _process(delta: float) -> void:
	if not _playing:
		return
	# 必须在读 time() 之前校准 —— 否则第一帧会用错的帧率算一次
	_clock.observe_delta(delta)
	var t := time()

	# 时间到了就把还没起播的片段拉起来
	for i in _segments.size():
		if _started[i]:
			continue
		var seg := _segments[i]
		if seg.muted or seg.stream == null:
			continue
		if t >= seg.offset and t < seg.end():
			_players[i].play(seg.local_time(t))
			_started[i] = true

	# 时钟锚点跟着"当前正在响的那一段"走
	var ai := _anchor_index(t)
	if ai >= 0:
		_clock.player = _players[ai]
		_clock.anchor_offset = _segments[ai].offset
	else:
		_clock.player = null

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


func _finish() -> void:
	if not _playing:
		return
	_playing = false
	_clock.stop()
	set_process(false)
	# 后面的标记不会再来了,放行所有还挂着的协程
	_generation += 1
	marker_reached.emit(&"")
	finished.emit()
