@tool
class_name CueMarkerExport

## 标记的 CSV / JSON 导出与回读。
##
## **JSON 是无损的**,可以再导回来(`from_json`),所以它同时也是
## "用外部脚本生成标记"的入口 —— 这正是 PLAN D5 选文本资源的初衷,
## 只是换了个更适合别的语言处理的格式。
##
## **CSV 是给人看的**:丢进表格排序、筛选、和字幕稿对照。
## 它带 `text` / `shape` 两个便利列(从 payload 里抽出来),
## 同时保留完整的 `payload` 列,所以也能无损回读。

const FORMAT_VERSION := 1
const CSV_HEADER := "name,time,frame,track,text,shape,payload"


static func to_json(sheet: CueSheet, pretty: bool = true) -> String:
	var markers: Array = []
	for m in sheet.sorted():
		markers.append({
			"name": String(m.name),
			"time": snappedf(m.time, 0.000001),
			"track": String(m.track),
			"payload": m.payload,
		})
	var tracks: Array = []
	for t in sheet.tracks:
		if t != null:
			tracks.append({"name": String(t.name), "color": t.color.to_html(false)})
	var segments: Array = []
	for s in sheet.all_segments():
		segments.append({
			"name": String(s.name),
			"path": s.path,
			"offset": snappedf(s.offset, 0.000001),
			"length": snappedf(s.length(), 0.000001),
		})

	var data := {
		"cue_format": FORMAT_VERSION,
		"fps": sheet.fps,
		"duration": snappedf(sheet.duration(), 0.000001),
		"segments": segments,
		"tracks": tracks,
		"markers": markers,
	}
	return JSON.stringify(data, "  " if pretty else "")


static func to_csv(sheet: CueSheet) -> String:
	var lines := PackedStringArray([CSV_HEADER])
	var fps := float(sheet.fps)
	for m in sheet.sorted():
		var payload_json := JSON.stringify(m.payload) if not m.payload.is_empty() else ""
		lines.append(",".join([
			_csv(String(m.name)),
			"%.6f" % m.time,
			str(int(round(m.time * fps))),
			_csv(String(m.track)),
			_csv(_inline(String(m.payload.get("text", "")))),
			_csv(_inline(String(m.payload.get("shape", "")))),
			_csv(payload_json),
		]))
	return "\n".join(lines) + "\n"


static func save_json(sheet: CueSheet, path: String) -> Error:
	return _write(path, to_json(sheet))


static func save_csv(sheet: CueSheet, path: String) -> Error:
	return _write(path, to_csv(sheet))


## 读回 [method to_json] 写出的文件。返回值与导入器同构,
## 所以面板可以用同一条 undo 路径把它们写进 sheet。
static func from_json(path: String) -> CueImportResult:
	var res := CueImportResult.new()
	if not FileAccess.file_exists(path):
		res.error = "Cue:找不到文件 %s。" % path
		return res
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		res.error = "Cue:无法打开 %s(错误码 %d)。" % [path, FileAccess.get_open_error()]
		return res
	var json := JSON.new()
	var err := json.parse(f.get_as_text())
	f.close()
	if err != OK:
		res.error = "Cue:%s 不是合法的 JSON(第 %d 行:%s)。" \
			% [path.get_file(), json.get_error_line(), json.get_error_message()]
		return res

	var data: Variant = json.data
	if not data is Dictionary:
		res.error = "Cue:%s 的顶层不是 JSON 对象。" % path.get_file()
		return res
	var dict := data as Dictionary
	var raw: Variant = dict.get("markers", null)
	if not raw is Array:
		res.error = "Cue:%s 里没有 markers 数组。这不像 Cue 导出的 JSON。" % path.get_file()
		return res

	res.source_entries = (raw as Array).size()
	for e in raw as Array:
		if not e is Dictionary:
			continue
		var d := e as Dictionary
		if not d.has("name") or not d.has("time"):
			continue
		var track := StringName(String(d.get("track", "dialogue")))
		var m := CueMarker.new(StringName(String(d["name"])), float(d["time"]), track)
		var pl: Variant = d.get("payload", {})
		if pl is Dictionary:
			m.payload = (pl as Dictionary).duplicate(true)
		res.markers.append(m)
		if not res.tracks.has(String(track)):
			res.tracks.append(String(track))

	if res.markers.is_empty():
		res.error = "Cue:%s 里没有可用的标记。" % path.get_file()
	return res


static func _write(path: String, text: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	f.close()
	return OK


## 便利列里的换行压平成字面的 \n。
##
## RFC 4180 允许带引号的字段内部含真换行,表格软件也认,但这样一来
## "一行一条记录"就不成立了,任何按行切分的脚本(awk / split / head)
## 都会被这一条撑爆。便利列本来就是给人看的,压平不损失信息 ——
## 无损的那份在 payload 列里(JSON 自己会把换行转义成 \n)。
static func _inline(s: String) -> String:
	return s.replace("\r\n", "\\n").replace("\n", "\\n").replace("\r", "\\n")


## CSV 字段转义:含逗号、引号、换行的一律加引号,内部引号翻倍。
static func _csv(s: String) -> String:
	if s == "":
		return ""
	if s.contains(",") or s.contains("\"") or s.contains("\n") or s.contains("\r"):
		return "\"%s\"" % s.replace("\"", "\"\"")
	return s
