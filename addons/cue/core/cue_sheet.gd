@tool
class_name CueSheet extends Resource

## 一条统一的时间轴:若干段音频([CueAudioSegment])+ 它们上面的所有命名标记。
##
## 多角色配音通常分开录,每段带自己的 [member CueAudioSegment.offset]。
## 标记时间轴跨全部片段,所以 [code]Cue.at()[/code] 不必关心那句话录在哪个文件里。
## (原 PLAN D10「一个 sheet 一个音频」已于 2026-08-25 推翻为 D10′,见 NOTES.md。)
##
## 存为 .tres 文本资源,可以 git diff、可以外部脚本生成、可以手工修补(PLAN D5)。

## 音频片段,按 offset 排列。这是权威存储。
@export var segments: Array[CueAudioSegment] = []:
	set(v):
		segments = v
		_seg_cache.clear()
		emit_changed()

## 兼容字段(D10 时代的单音频模型)。[member segments] 为空时,
## [method all_segments] 会用这三个字段合成一个片段返回,所以旧 .tres 不改也能用。
## 点一次「分析波形」会把它们就地升级进 segments。
@export var audio: AudioStream = null:
	set(v):
		audio = v
		if audio != null and audio_path == "":
			audio_path = audio.resource_path
		_seg_cache.clear()
		emit_changed()

@export_file("*.wav") var audio_path: String = "":
	set(v):
		audio_path = v
		_seg_cache.clear()
		emit_changed()

@export var markers: Array[CueMarker] = []:
	set(v):
		markers = v
		_dirty = true
		emit_changed()

@export var tracks: Array[CueTrack] = []:
	set(v):
		tracks = v
		emit_changed()

## 兼容字段,同上。新数据放在 [member CueAudioSegment.waveform] 里。
@export var waveform: WaveformCache = null:
	set(v):
		waveform = v
		_seg_cache.clear()

## 振幅包络。没有口型数据时的降级方案(见 [CueEnvelope])。
## 和波形缓存一起在「分析波形」时生成。
@export var envelope: CueEnvelope = null

## 用于帧吸附和帧标尺。与项目实际渲染帧率一致才有意义。
@export_range(1, 240, 1) var fps: int = 30:
	set(v):
		fps = maxi(v, 1)
		emit_changed()

var _sorted: Array[CueMarker] = []
var _dirty: bool = true
## 旧字段合成出来的临时片段,避免每次调用都新建一个。
var _seg_cache: Array[CueAudioSegment] = []

## 被 [method remove_marker] 摘下来的标记暂存在这里,免得没人引用就被释放 ——
## undo 栈里还指着它。不是 @export,不会写进 .tres。
##
## 本来这该由 [code]EditorUndoRedoManager.add_do_reference()[/code] 负责,但
## 4.7.2 实测 [code]add_*_reference()[/code] 也会按对象自身的历史归属做校验,
## 而没有 res:// 路径的 CueMarker 归属"当前编辑场景"历史(1),
## 与 CueSheet 的 GLOBAL(0) 冲突,每次增删都刷一条
## [code]UndoRedo history mismatch[/code]。让 sheet 自己拿着引用就绕开了。
var _retained: Array[CueMarker] = []


## 按名字查找。名字在一个 sheet 内唯一(见 [method validate])。
func find(marker_name: StringName) -> CueMarker:
	for m in markers:
		if m != null and m.name == marker_name:
			return m
	return null


func has(marker_name: StringName) -> bool:
	return find(marker_name) != null


func in_track(track: StringName) -> Array[CueMarker]:
	var out: Array[CueMarker] = []
	for m in sorted():
		if m.track == track:
			out.append(m)
	return out


## 按 time 升序;time 相同时按名字排序,保证是全序 —— 否则同一份数据
## 在两次运行中可能产生不同顺序,离线渲染就不再是纯函数(见 CLAUDE.md 确定性要求)。
func sorted() -> Array[CueMarker]:
	if _dirty:
		_rebuild_sorted()
	return _sorted


## 标记被外部修改后调用。编辑器每次改动都会调它。
func invalidate() -> void:
	_dirty = true


## 通知外部"这个 sheet 变了":排序缓存失效 + 发 changed 信号。
##
## undo 动作里[b]只能[/b]操作资源,不能塞编辑器节点进去 —— 4.7.2 实测会报
## [code]UndoRedo history mismatch: expected 0, got 1[/code]:
## 节点属于场景历史,资源属于全局历史,一个 action 里混用两种就会不一致。
## 所以面板改成监听本信号来刷新,而不是把自己挂进 undo 栈。
func touch() -> void:
	_dirty = true
	_seg_cache.clear()
	emit_changed()


func add_marker(m: CueMarker) -> void:
	_retained.erase(m)
	markers.append(m)
	_dirty = true
	emit_changed()


func remove_marker(m: CueMarker) -> void:
	var i := markers.find(m)
	if i >= 0:
		markers.remove_at(i)
		if not _retained.has(m):
			_retained.append(m)
		_dirty = true
		emit_changed()


## 插入到指定下标。undo 需要它来精确还原顺序。
func insert_marker(m: CueMarker, index: int) -> void:
	_retained.erase(m)
	markers.insert(clampi(index, 0, markers.size()), m)
	_dirty = true
	emit_changed()


## 以下两个 setter 存在是为了 undo。
##
## 4.7.2 实测:没有 resource_path 的 CueMarker,
## [code]EditorUndoRedoManager.get_object_history_id()[/code] 返回的是
## [b]当前编辑场景[/b]的历史(1),而不是 GLOBAL(0);而已存盘的 CueSheet 是 0。
## 于是 [code]add_do_property(marker, ...)[/code] 配上
## [code]create_action(..., sheet)[/code] 会报
## [code]UndoRedo history mismatch: expected 0, got 1[/code]。
## 把目标对象统一成 sheet(marker 只作为参数传递,参数不参与历史判定)就没这个问题。
func set_marker_time(m: CueMarker, t: float) -> void:
	if m != null:
		m.time = t
		touch()


func set_marker_name(m: CueMarker, n: StringName) -> void:
	if m != null:
		m.name = n
		touch()


func index_of(m: CueMarker) -> int:
	return markers.find(m)


## 全部音频片段。[member segments] 为空时用兼容字段合成一个。
func all_segments() -> Array[CueAudioSegment]:
	if not segments.is_empty():
		return segments
	# 只有 waveform 没有音频也算数 —— 时长信息在缓存里,足以支撑
	# duration() / window() 这些纯时间轴查询。
	if audio_path == "" and audio == null and waveform == null:
		return []
	if _seg_cache.is_empty():
		var seg := CueAudioSegment.new(&"", audio_path, 0.0)
		seg.stream = audio
		seg.waveform = waveform
		_seg_cache = [seg] as Array[CueAudioSegment]
	return _seg_cache


## 把兼容字段就地升级成 segments[0]。已经是 segments 形式时是空操作。
## 由面板在「分析波形」时调用 —— 一次性、显式、可 undo。
func migrate_legacy() -> bool:
	if not segments.is_empty():
		return false
	if audio_path == "" and audio == null:
		return false
	var seg := CueAudioSegment.new(&"", audio_path, 0.0)
	seg.stream = audio
	seg.waveform = waveform
	segments = [seg] as Array[CueAudioSegment]
	audio = null
	audio_path = ""
	waveform = null
	_seg_cache.clear()
	emit_changed()
	return true


func segment_count() -> int:
	return all_segments().size()


## 覆盖 [param t] 的片段;没有则返回 null。重叠时取第一个。
func segment_at(t: float) -> CueAudioSegment:
	for seg in all_segments():
		if seg.covers(t):
			return seg
	return null


## 整条时间轴的长度 = 最靠后的片段结束时刻。
func duration() -> float:
	var d := 0.0
	for seg in all_segments():
		d = maxf(d, seg.end())
	return d


## 把时间吸附到帧边界。
func snap(t: float) -> float:
	return round(t * float(fps)) / float(fps)


## 本 sheet 涉及的所有轨道名,有序:先按 [member tracks] 的声明顺序,
## 再补上只在标记里出现、但没有声明 CueTrack 的轨道(手写 .tres 时很常见)。
func track_names() -> Array[StringName]:
	var out: Array[StringName] = []
	for t in tracks:
		if t != null and not out.has(t.name):
			out.append(t.name)
	for m in sorted():
		if not out.has(m.track):
			out.append(m.track)
	if out.is_empty():
		out.append(&"dialogue")
	return out


func count_in_track(track_name: StringName) -> int:
	var n := 0
	for m in markers:
		if m != null and m.track == track_name:
			n += 1
	return n


func add_segment(seg: CueAudioSegment) -> void:
	segments.append(seg)
	_seg_cache.clear()
	touch()


func remove_segment(seg: CueAudioSegment) -> void:
	var i := segments.find(seg)
	if i >= 0:
		segments.remove_at(i)
		_seg_cache.clear()
		touch()


func insert_segment(seg: CueAudioSegment, index: int) -> void:
	segments.insert(clampi(index, 0, segments.size()), seg)
	_seg_cache.clear()
	touch()


func index_of_segment(seg: CueAudioSegment) -> int:
	return segments.find(seg)


## 供 undo 使用,理由同 [method set_marker_time]。
func set_segment_offset(seg: CueAudioSegment, v: float) -> void:
	if seg != null:
		seg.offset = v
		touch()


func track_color(track_name: StringName, fallback: Color) -> Color:
	for t in tracks:
		if t != null and t.name == track_name:
			return t.color
	return fallback


## 返回问题列表(空数组 = 数据健康)。重名会让 [method find] 有歧义,
## 因此在编辑和导入两处都必须拒绝。
func validate() -> PackedStringArray:
	var issues := PackedStringArray()
	var seen := {}
	for m in markers:
		if m == null:
			issues.append("存在空标记条目。")
			continue
		if m.name == &"":
			issues.append("有标记未命名(时间 %.3fs)。" % m.time)
			continue
		if seen.has(m.name):
			issues.append("标记名重复:「%s」。" % m.name)
		seen[m.name] = true

	for seg in all_segments():
		if seg.path == "" and seg.stream == null:
			issues.append("片段「%s」既没有 path 也没有 stream。" % seg.label())
	return issues


## 生成一个在本 sheet 内不重复的名字。
func unique_name(base: StringName = &"cue") -> StringName:
	if not has(base):
		return base
	var i := 1
	while has(StringName("%s_%d" % [base, i])):
		i += 1
	return StringName("%s_%d" % [base, i])


func _rebuild_sorted() -> void:
	var arr: Array[CueMarker] = []
	for m in markers:
		if m != null:
			arr.append(m)
	arr.sort_custom(_compare)
	_sorted = arr
	_dirty = false


static func _compare(a: CueMarker, b: CueMarker) -> bool:
	if a.time == b.time:
		return String(a.name) < String(b.name)
	return a.time < b.time
