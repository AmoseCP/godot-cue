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

# 注意:折叠状态[b]不[/b]存在这里。它是纯视图状态,存进 .tres 只会让
# 一次 UI 折叠产生一条 git diff,而且得为它走一遍 undo。
# 实际存放位置是 CueViewState。


func _init(p_name: StringName = &"dialogue", p_color: Color = Color(0.4, 0.7, 1.0)) -> void:
	name = p_name
	color = p_color
