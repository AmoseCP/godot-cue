@tool
class_name CueRhubarbImporter

## Rhubarb Lip Sync 的 JSON 输出 → 口型轨标记。
##
## Rhubarb 用 `rhubarb -f json -o out.json voice.wav` 生成:
## [codeblock]
## {
##   "metadata": { "soundFile": "voice.wav", "duration": 3.44 },
##   "mouthCues": [
##     { "start": 0.00, "end": 0.28, "value": "X" },
##     { "start": 0.28, "end": 0.35, "value": "B" }
##   ]
## }
## [/codeblock]
##
## `value` 是 Preston Blair 口型代号 A~H 加静止的 X。

const DEFAULT_TRACK := &"mouth"
## Rhubarb 用 X 表示闭嘴/静止。默认保留 —— 嘴什么时候合上和什么时候张开一样重要。
const REST_SHAPE := "X"


static func parse(path: String, track: StringName = DEFAULT_TRACK,
		name_prefix: String = "m") -> CueImportResult:
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
		res.error = "Cue:%s 的顶层不是一个 JSON 对象,不像 Rhubarb 的输出。" % path.get_file()
		return res

	var cues: Variant = (data as Dictionary).get("mouthCues", null)
	if not cues is Array:
		res.error = "Cue:%s 里没有 mouthCues 数组。确认用的是 `rhubarb -f json` 的输出。" \
			% path.get_file()
		return res

	res.tracks = PackedStringArray([String(track)])
	res.source_entries = (cues as Array).size()

	var i := 0
	for c in cues as Array:
		if not c is Dictionary:
			continue
		var cue := c as Dictionary
		if not cue.has("start") or not cue.has("value"):
			continue
		var m := CueMarker.new(
			StringName("%s_%04d" % [name_prefix, i]),
			float(cue["start"]),
			track)
		m.payload = {
			"shape": String(cue["value"]),
			"end": float(cue.get("end", cue["start"])),
		}
		res.markers.append(m)
		i += 1

	if res.markers.is_empty():
		res.error = "Cue:%s 的 mouthCues 是空的。" % path.get_file()
		return res

	var meta: Variant = (data as Dictionary).get("metadata", null)
	if meta is Dictionary and (meta as Dictionary).has("duration"):
		res.notes.append("源文件时长 %.3fs" % float((meta as Dictionary)["duration"]))
	return res


## 把一段口型序列压进某个标记的 payload,供 [method Cue.phonemes] 读取。
## 时间转成相对 [param host] 的偏移,这样整句被挪动时口型跟着走。
static func attach_to(host: CueMarker, mouth_markers: Array[CueMarker],
		until: float = INF) -> void:
	var seq: Array = []
	for m in mouth_markers:
		if m.time < host.time or m.time > until:
			continue
		seq.append({"t": m.time - host.time, "shape": String(m.payload.get("shape", REST_SHAPE))})
	host.payload["phonemes"] = seq
