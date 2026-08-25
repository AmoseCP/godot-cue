@tool
class_name CueTrack extends Resource

## 一条标记轨道的元数据。轨道只是分组标签,不影响运行时查找。

@export var name: StringName = &"dialogue":
	set(v):
		name = v
		emit_changed()

@export var color: Color = Color(0.4, 0.7, 1.0):
	set(v):
		color = v
		emit_changed()

## 折叠状态由编辑器面板读写,不参与运行时逻辑。
@export var collapsed: bool = false


func _init(p_name: StringName = &"dialogue", p_color: Color = Color(0.4, 0.7, 1.0)) -> void:
	name = p_name
	color = p_color
