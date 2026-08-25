extends SceneTree

## 生成示例用的音频和 CueSheet。仓库里已经带了生成结果,
## 这个脚本留着是为了让你能看到 CueSheet 也可以完全由脚本产出。
##   godot --headless --path . --script examples/hello_cue/make_example.gd

const WAV := "res://examples/hello_cue/voice.wav"
const SHEET := "res://examples/hello_cue/shot_01.tres"
const RATE := 44100
const DUR := 4.0

## 假装这是一段配音:六个"音节",每个是一小段有包络的音。
const SYLLABLES := [
	[0.30, 0.45, 300.0], [0.85, 0.40, 260.0], [1.45, 0.35, 340.0],
	[2.10, 0.50, 220.0], [2.80, 0.40, 380.0], [3.35, 0.45, 290.0],
]


func _init() -> void:
	_write_wav()
	_write_sheet()
	quit()


func _write_wav() -> void:
	var n := int(RATE * DUR)
	var pcm := PackedByteArray(); pcm.resize(n * 2)
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for syl in SYLLABLES:
			var s: float = syl[0]
			var d: float = syl[1]
			if t >= s and t < s + d:
				var u := (t - s) / d
				var env: float = sin(u * PI)          # 淡入淡出,像一个音节
				v += sin(TAU * float(syl[2]) * t) * env * 0.6
				v += sin(TAU * float(syl[2]) * 2.0 * t) * env * 0.15
		pcm.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32000.0))

	var f := FileAccess.open(WAV, FileAccess.WRITE)
	var ds := pcm.size()
	f.store_buffer("RIFF".to_ascii_buffer()); f.store_32(36 + ds)
	f.store_buffer("WAVEfmt ".to_ascii_buffer()); f.store_32(16)
	f.store_16(1); f.store_16(1); f.store_32(RATE)
	f.store_32(RATE * 2); f.store_16(2); f.store_16(16)
	f.store_buffer("data".to_ascii_buffer()); f.store_32(ds)
	f.store_buffer(pcm); f.close()
	print("写入 ", WAV)


func _write_sheet() -> void:
	var sheet := CueSheet.new()
	sheet.fps = 30
	sheet.audio_path = WAV
	sheet.audio = load(WAV)
	sheet.tracks = [
		CueTrack.new(&"dialogue", Color(0.40, 0.70, 1.00)),
		CueTrack.new(&"action", Color(1.00, 0.65, 0.30)),
	]
	for d in [
		[&"peter_enters", 0.30, &"action"],
		[&"peter_line_1", 0.85, &"dialogue"],
		[&"john_looks_up", 1.45, &"action"],
		[&"john_line_1", 2.10, &"dialogue"],
		[&"peter_line_2", 2.80, &"dialogue"],
		[&"both_exit", 3.35, &"action"],
	]:
		sheet.add_marker(CueMarker.new(d[0], d[1], d[2]))
	sheet.waveform = CueWaveformBuilder.new().build(CuePcmReader.read_wav_file(WAV), 256)
	sheet.envelope = CueEnvelopeBuilder.normalized(
		CueEnvelopeBuilder.from_cache(sheet.waveform))
	print("写入 ", SHEET, " → ", ResourceSaver.save(sheet, SHEET))
