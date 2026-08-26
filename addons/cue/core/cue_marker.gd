@tool
@icon("res://addons/cue/icons/cue_marker.svg")
class_name CueMarker extends Resource

## 音频时间轴上的一个命名标记。
##
## 运行时通过 [code]Cue.at(&"名字")[/code] 等待它。

@export var name: StringName = &"":
	set(v):
		name = v
		emit_changed()

## 相对音频起点的秒数。
@export var time: float = 0.0:
	set(v):
		time = maxf(v, 0.0)
		emit_changed()

@export var track: StringName = &"dialogue":
	set(v):
		track = v
		emit_changed()

## 口型音素、字幕文本等附加数据。
@export var payload: Dictionary = {}


func _init(p_name: StringName = &"", p_time: float = 0.0, p_track: StringName = &"dialogue") -> void:
	name = p_name
	time = p_time
	track = p_track


func duplicate_marker() -> CueMarker:
	var m := CueMarker.new(name, time, track)
	m.payload = payload.duplicate(true)
	return m


func _to_string() -> String:
	return "CueMarker(%s @ %.3fs / %s)" % [name, time, track]
