@tool
class_name CueTextGridImporter

## Praat / Montreal Forced Aligner 的 TextGrid → 词级 + 音素级轨。
##
## MFA 输出的是 Praat 的"长格式"(long form):
## [codeblock]
## File type = "ooTextFile"
## Object class = "TextGrid"
##
## xmin = 0
## xmax = 3.44
## tiers? <exists>
## size = 2
## item []:
##     item [1]:
##         class = "IntervalTier"
##         name = "words"
##         xmin = 0
##         xmax = 3.44
##         intervals: size = 5
##         intervals [1]:
##             xmin = 0
##             xmax = 0.42
##             text = ""
## [/codeblock]
##
## 也支持"短格式"(每行一个裸值,没有 `键 = ` 前缀)—— Praat 手动导出常是这种。
##
## 空 text 的区间是静音/停顿,默认跳过。

## tier 名 → 轨道名的映射。MFA 的中文/英文模型都用这两个名字。
const TIER_TO_TRACK := {
	"words": &"words",
	"word": &"words",
	"phones": &"phones",
	"phones ": &"phones",
	"phone": &"phones",
}


static func parse(path: String, skip_empty: bool = true) -> CueImportResult:
	var res := CueImportResult.new()

	if not FileAccess.file_exists(path):
		res.error = "Cue:找不到文件 %s。" % path
		return res
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		res.error = "Cue:无法打开 %s(错误码 %d)。" % [path, FileAccess.get_open_error()]
		return res
	var text := f.get_as_text()
	f.close()

	if not text.contains("TextGrid"):
		res.error = "Cue:%s 不像 TextGrid 文件(找不到 \"TextGrid\" 标识)。MFA 输出的应是 .TextGrid。" \
			% path.get_file()
		return res

	var lines := text.split("\n", false)
	var is_short := not text.contains("item [")

	var tiers: Array = _parse_short(lines) if is_short else _parse_long(lines)
	if tiers.is_empty():
		res.error = "Cue:%s 里没有解析出任何 IntervalTier。" % path.get_file()
		return res

	var skipped := 0
	for tier in tiers:
		var tier_name := String(tier["name"])
		var track: StringName = TIER_TO_TRACK.get(tier_name.strip_edges().to_lower(),
			StringName(tier_name.strip_edges()))
		if not res.tracks.has(String(track)):
			res.tracks.append(String(track))
		var idx := 0
		for iv in tier["intervals"] as Array:
			res.source_entries += 1
			var label := String(iv["text"]).strip_edges()
			if label == "" and skip_empty:
				skipped += 1
				continue
			var m := CueMarker.new(
				StringName("%s_%04d" % [track, idx]),
				float(iv["xmin"]),
				track)
			m.payload = {"text": label, "end": float(iv["xmax"])}
			res.markers.append(m)
			idx += 1

	if skipped > 0:
		res.notes.append("跳过了 %d 个空区间(静音/停顿)。" % skipped)
	if res.markers.is_empty():
		res.error = "Cue:%s 里所有区间都是空的。" % path.get_file()
	return res


## 长格式:靠 `键 = 值` 的行解析,忽略缩进。
static func _parse_long(lines: PackedStringArray) -> Array:
	var tiers: Array = []
	var cur: Dictionary = {}
	var iv: Dictionary = {}
	var in_intervals := false

	for raw in lines:
		var line := raw.strip_edges()
		if line.begins_with("class"):
			# 上一个 tier 收尾
			_flush_interval(cur, iv, in_intervals)
			iv = {}
			if _value_of(line).contains("IntervalTier"):
				cur = {"name": "", "intervals": []}
				tiers.append(cur)
			else:
				cur = {}          # PointTier 等,不支持,后续行全部丢弃
			in_intervals = false
		elif line.begins_with("name") and not cur.is_empty():
			cur["name"] = _value_of(line)
		elif line.begins_with("intervals ["):
			_flush_interval(cur, iv, in_intervals)
			iv = {}
			in_intervals = true
		elif in_intervals and line.begins_with("xmin"):
			iv["xmin"] = _value_of(line).to_float()
		elif in_intervals and line.begins_with("xmax"):
			iv["xmax"] = _value_of(line).to_float()
		elif in_intervals and line.begins_with("text"):
			iv["text"] = _value_of(line)
	_flush_interval(cur, iv, in_intervals)
	return tiers


## 短格式:一堆裸值,按位置解析。
## 结构是 [头 4 行] size,然后每个 tier:class / name / xmin / xmax / n,
## 接着 n 组 (xmin, xmax, text)。
static func _parse_short(lines: PackedStringArray) -> Array:
	var vals := PackedStringArray()
	for raw in lines:
		var line := raw.strip_edges()
		if line == "" or line.begins_with("File type") or line.begins_with("Object class"):
			continue
		vals.append(_unquote(line))

	var tiers: Array = []
	# vals: xmin, xmax, <exists>, tier_count, 然后每个 tier
	if vals.size() < 4:
		return tiers
	var n_tiers := vals[3].to_int()
	var p := 4
	for t in n_tiers:
		if p + 5 > vals.size():
			break
		var cls := vals[p]
		var tname := vals[p + 1]
		var n_iv := vals[p + 4].to_int()
		p += 5
		if not cls.contains("IntervalTier"):
			p += n_iv * 2          # PointTier 每项 2 个值
			continue
		var tier := {"name": tname, "intervals": []}
		for i in n_iv:
			if p + 3 > vals.size():
				break
			(tier["intervals"] as Array).append({
				"xmin": vals[p].to_float(),
				"xmax": vals[p + 1].to_float(),
				"text": vals[p + 2],
			})
			p += 3
		tiers.append(tier)
	return tiers


static func _flush_interval(cur: Dictionary, iv: Dictionary, in_intervals: bool) -> void:
	if in_intervals and not cur.is_empty() and iv.has("xmin") and iv.has("xmax"):
		if not iv.has("text"):
			iv["text"] = ""
		(cur["intervals"] as Array).append(iv)


## 取 `键 = 值` 里的值,去掉包裹的引号。
static func _value_of(line: String) -> String:
	var i := line.find("=")
	if i < 0:
		return ""
	return _unquote(line.substr(i + 1).strip_edges())


static func _unquote(s: String) -> String:
	if s.length() >= 2 and s.begins_with("\"") and s.ends_with("\""):
		return s.substr(1, s.length() - 2)
	return s
