@tool
class_name CueImportResult extends RefCounted

## 导入器的统一返回值。导入器只**解析**,不碰 sheet ——
## 实际写入由面板包成一次 undo 动作完成。

var markers: Array[CueMarker] = []
## 源文件里的条目总数(含被跳过的静音段)。用于"数量对得上吗"的核对。
var source_entries: int = 0
## 解析出的轨道名,按出现顺序。
var tracks: PackedStringArray = PackedStringArray()
var error: String = ""
## 非致命的提示,比如"跳过了 12 个静音段"。
var notes: PackedStringArray = PackedStringArray()


func ok() -> bool:
	return error == ""


func summary() -> String:
	if not ok():
		return error
	var s := "解析出 %d 个标记(源文件 %d 条目)" % [markers.size(), source_entries]
	if tracks.size() > 0:
		s += ",轨道:%s" % ", ".join(tracks)
	if notes.size() > 0:
		s += "\n" + "\n".join(notes)
	return s
