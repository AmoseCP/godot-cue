@tool
class_name CueSheet extends Resource

## 一个音频文件 + 它上面的所有命名标记(见 PLAN D10:一个 sheet 对应一个音频)。
##
## 存为 .tres 文本资源,可以 git diff、可以外部脚本生成、可以手工修补(PLAN D5)。

## 导入后的音频资源,运行时播放用。
@export var audio: AudioStream = null:
	set(v):
		audio = v
		if audio != null and audio_path == "":
			audio_path = audio.resource_path
		emit_changed()

## 源 WAV 的 res:// 路径。波形分析优先读它,以绕过导入压缩。
@export_file("*.wav") var audio_path: String = "":
	set(v):
		audio_path = v
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

@export var waveform: WaveformCache = null

## 用于帧吸附和帧标尺。与项目实际渲染帧率一致才有意义。
@export_range(1, 240, 1) var fps: int = 30:
	set(v):
		fps = maxi(v, 1)
		emit_changed()

var _sorted: Array[CueMarker] = []
var _dirty: bool = true


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


func add_marker(m: CueMarker) -> void:
	markers.append(m)
	_dirty = true
	emit_changed()


func remove_marker(m: CueMarker) -> void:
	var i := markers.find(m)
	if i >= 0:
		markers.remove_at(i)
		_dirty = true
		emit_changed()


## 插入到指定下标。undo 需要它来精确还原顺序。
func insert_marker(m: CueMarker, index: int) -> void:
	markers.insert(clampi(index, 0, markers.size()), m)
	_dirty = true
	emit_changed()


func index_of(m: CueMarker) -> int:
	return markers.find(m)


func duration() -> float:
	if waveform != null and waveform.duration > 0.0:
		return waveform.duration
	if audio != null:
		return audio.get_length()
	return 0.0


## 把时间吸附到帧边界。
func snap(t: float) -> float:
	return round(t * float(fps)) / float(fps)


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
