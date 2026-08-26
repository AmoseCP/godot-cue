@tool
class_name CueAudioSegment extends Resource

## sheet 时间轴上的一段音频。
##
## 多角色配音通常是分开录的:Peter 一条、John 一条,各自有起始偏移。
## 一个 sheet 装下全部片段,标记时间轴跨片段统一 —— 这样
## [code]await Cue.at(&"john_looks_up")[/code] 不必关心那句话录在哪个文件里。
##
## 每段持有[b]自己的[/b] [WaveformCache]:改一个角色的配音只需重算那一段,
## 不用重扫整集(这是原 D10「资源粒度小、便于局部重渲」诉求的落点)。

## 显示用的标签,通常是角色名。
@export var name: StringName = &"":
	set(v):
		name = v
		emit_changed()

## 导入后的音频资源,运行时播放用。
@export var stream: AudioStream = null:
	set(v):
		stream = v
		if stream != null and path == "":
			path = stream.resource_path
		emit_changed()

## 源 WAV 的 res:// 路径。波形分析优先读它,以绕过导入压缩。
@export_file("*.wav") var path: String = "":
	set(v):
		path = v
		emit_changed()

## 这段音频在 sheet 时间轴上的起点(秒)。
@export var offset: float = 0.0:
	set(v):
		offset = maxf(v, 0.0)
		emit_changed()

@export_range(-40.0, 12.0, 0.1) var gain_db: float = 0.0

## 静音这一段(只影响预览与运行时播放,不影响波形显示)。
@export var muted: bool = false

@export var waveform: WaveformCache = null


func _init(p_name: StringName = &"", p_path: String = "", p_offset: float = 0.0) -> void:
	name = p_name
	path = p_path
	offset = p_offset


## 这段音频自身的长度(秒)。
func length() -> float:
	if waveform != null and waveform.duration > 0.0:
		return waveform.duration
	if stream != null:
		return stream.get_length()
	return 0.0


## 在 sheet 时间轴上的结束时刻。
func end() -> float:
	return offset + length()


## [param t](sheet 时间)是否落在这一段内。
func covers(t: float) -> bool:
	return t >= offset and t < end()


## sheet 时间 → 这段音频内部的播放位置。
func local_time(t: float) -> float:
	return t - offset


func has_waveform() -> bool:
	return waveform != null and waveform.is_valid()


## 波形缓存是否还匹配源文件。
func waveform_stale() -> bool:
	if not has_waveform():
		return true
	if path == "":
		return false
	return not waveform.matches(path)


func label() -> String:
	if name != &"":
		return String(name)
	if path != "":
		return path.get_file()
	return "(未命名片段)"
