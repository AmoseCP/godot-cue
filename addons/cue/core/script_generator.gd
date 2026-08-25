@tool
class_name CueScriptGenerator

## 从标记生成 GDScript 剧本骨架 —— 一串 [code]await Cue.at(...)[/code]。
##
## 用途:把"这一镜有哪些节拍"从脑子里搬到文件里。分镜时先在波形上把标记
## 打完,生成骨架,再往每个 await 后面填实际动作。省掉手抄一遍标记名的
## 环节,也就没有抄错名字导致运行时 [code]push_error[/code] 的机会。
##
## 生成的是[b]骨架[/b],不是可维护的代码 —— 重新生成会覆盖整个文件,
## 所以自定义逻辑要写在别的文件里,或者生成一次之后就当普通脚本手工维护。

## 生成选项。
class Options extends RefCounted:
	## 只生成这些轨道的标记;空 = 全部。
	var tracks: PackedStringArray = PackedStringArray()
	## 场景根节点的基类。
	var extends_type: String = "Node2D"
	## 装 await 序列的函数名。
	var func_name: String = "_shot"
	## 每个 await 前面注明时间和帧号。
	var comments: bool = true
	## 生成 _ready() 里的 load_sheet + play。
	var include_ready: bool = true
	## sheet 的 res:// 路径;空则从 sheet.resource_path 取。
	var sheet_path: String = ""


static func generate(sheet: CueSheet, opts: Options = null) -> String:
	if opts == null:
		opts = Options.new()
	var path := opts.sheet_path if opts.sheet_path != "" else sheet.resource_path

	var picked: Array[CueMarker] = []
	for m in sheet.sorted():
		if opts.tracks.is_empty() or opts.tracks.has(String(m.track)):
			picked.append(m)

	var out := PackedStringArray()
	out.append("extends %s" % opts.extends_type)
	out.append("")
	out.append("## 由 Cue 生成 —— %d 个标记,%d fps。" % [picked.size(), sheet.fps])
	if path != "":
		out.append("## 来源:%s" % path)
	out.append("##")
	out.append("## 重新生成会覆盖整个文件。要加自己的逻辑,")
	out.append("## 要么写在别的脚本里,要么从此把这个文件当普通脚本手工维护。")
	out.append("")

	if opts.include_ready and path != "":
		out.append("const SHEET := preload(\"%s\")" % path)
		out.append("")
		out.append("")
		out.append("func _ready() -> void:")
		out.append("\tCue.load_sheet(SHEET)")
		out.append("\tCue.play()")
		out.append("\t%s()" % opts.func_name)
		out.append("")
		out.append("")

	out.append("func %s() -> void:" % opts.func_name)
	if picked.is_empty():
		out.append("\t# 这个 sheet 里没有标记(或者都被轨道过滤掉了)。")
		out.append("\tpass")
	else:
		var first := true
		for m in picked:
			if not first:
				out.append("")
			first = false
			if opts.comments:
				out.append("\t# %.3fs / f%d  [%s]"
					% [m.time, int(round(m.time * float(sheet.fps))), m.track])
			out.append("\tawait Cue.at(&\"%s\")" % _escape(String(m.name)))
			out.append("\t# TODO")
	out.append("")
	return "\n".join(out)


static func save(sheet: CueSheet, path: String, opts: Options = null) -> Error:
	var text := generate(sheet, opts)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	f.close()
	return OK


## 标记名进的是 GDScript 字符串字面量,必须转义 —— 否则一个名字里带引号
## 的标记就能生成出语法错误的文件。反斜杠要先处理,不然会把后面转义出来的
## 反斜杠又转一遍。
static func _escape(s: String) -> String:
	return s.replace("\\", "\\\\").replace("\"", "\\\"")
