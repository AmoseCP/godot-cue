extends SceneTree

## 生成口型示例用的 Rhubarb JSON 和 CueSheet。
## 仓库里带了生成结果,这个脚本留着是为了说明这些数据是怎么来的。
##   godot --headless --path . --script examples/mouth_sync/make_example.gd

const WAV := "res://examples/hello_cue/voice.wav"
const JSON_PATH := "res://examples/mouth_sync/voice.rhubarb.json"
const SHEET := "res://examples/mouth_sync/shot_mouth.tres"

## 和 hello_cue 的合成配音一致:起点、时长。
const SYLLABLES := [
	[0.30, 0.45], [0.85, 0.40], [1.45, 0.35],
	[2.10, 0.50], [2.80, 0.40], [3.35, 0.45],
]
## 每个音节内部的嘴型走向:闭 → 张开 → 收拢。
const ARCS := [
	["B", "D", "C"], ["B", "C", "E"], ["G", "C", "B"],
	["B", "D", "E"], ["F", "C", "B"], ["B", "D", "C"],
]


func _init() -> void:
	_write_json()
	_write_sheet()
	quit()


## 写一份格式与 `rhubarb -f json` 输出一致的文件。
func _write_json() -> void:
	var cues: Array = []
	var t := 0.0
	for i in SYLLABLES.size():
		var start: float = SYLLABLES[i][0]
		var dur: float = SYLLABLES[i][1]
		# 音节之间闭嘴
		if start > t:
			cues.append({"start": _r(t), "end": _r(start), "value": "X"})
		var arc: Array = ARCS[i]
		var step := dur / float(arc.size())
		for k in arc.size():
			cues.append({
				"start": _r(start + step * float(k)),
				"end": _r(start + step * float(k + 1)),
				"value": arc[k],
			})
		t = start + dur
	cues.append({"start": _r(t), "end": 4.0, "value": "X"})

	var data := {
		"metadata": {"soundFile": "voice.wav", "duration": 4.0},
		"mouthCues": cues,
	}
	var f := FileAccess.open(JSON_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	print("写入 %s(%d 个 mouthCue)" % [JSON_PATH, cues.size()])


func _r(v: float) -> float:
	return snappedf(v, 0.001)


func _write_sheet() -> void:
	var sheet := CueSheet.new()
	sheet.fps = 30
	sheet.audio_path = WAV
	sheet.audio = load(WAV)
	sheet.tracks = [
		CueTrack.new(&"dialogue", Color(0.40, 0.70, 1.00)),
		CueTrack.new(&"mouth", Color(1.00, 0.65, 0.30)),
	]
	for i in SYLLABLES.size():
		sheet.add_marker(CueMarker.new(
			StringName("syl_%d" % (i + 1)), SYLLABLES[i][0], &"dialogue"))

	# 走真正的导入器,而不是手搓 —— 这样示例数据和用户自己导入的完全同构
	var res := CueRhubarbImporter.parse(JSON_PATH)
	if not res.ok():
		push_error(res.error)
		return
	for m in res.markers:
		m.name = sheet.unique_name(m.name)
		sheet.add_marker(m)

	sheet.waveform = CueWaveformBuilder.new().build(CuePcmReader.read_wav_file(WAV), 256)
	print("写入 %s(%d 个标记)→ %d" % [SHEET, sheet.markers.size(),
		ResourceSaver.save(sheet, SHEET)])
