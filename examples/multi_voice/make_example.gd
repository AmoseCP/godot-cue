extends SceneTree

## 生成多角色分轨示例:两个角色分开录,各自带偏移,共用一条标记时间轴。
##   godot --headless --path . --script examples/multi_voice/make_example.gd

const RATE := 44100
const PETER := "res://examples/multi_voice/peter.wav"
const JOHN := "res://examples/multi_voice/john.wav"
const SHEET := "res://examples/multi_voice/scene_01.tres"

## [起点(段内), 时长, 基频]
const PETER_LINES := [[0.15, 0.50, 250.0], [0.85, 0.55, 230.0]]
const JOHN_LINES := [[0.10, 0.45, 150.0], [0.75, 0.60, 165.0]]

## John 这段录音在 sheet 时间轴上的起点 —— 他在 Peter 说完之后接话。
const JOHN_OFFSET := 1.9


func _init() -> void:
	_voice(PETER, 1.6, PETER_LINES)
	_voice(JOHN, 1.5, JOHN_LINES)
	_sheet()
	quit()


func _voice(path: String, dur: float, lines: Array) -> void:
	var n := int(RATE * dur)
	var pcm := PackedByteArray(); pcm.resize(n * 2)
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for L in lines:
			var s: float = L[0]
			var d: float = L[1]
			if t >= s and t < s + d:
				var env: float = sin((t - s) / d * PI)
				v += sin(TAU * float(L[2]) * t) * env * 0.55
				v += sin(TAU * float(L[2]) * 3.0 * t) * env * 0.12
		pcm.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32000.0))
	var f := FileAccess.open(path, FileAccess.WRITE)
	var ds := pcm.size()
	f.store_buffer("RIFF".to_ascii_buffer()); f.store_32(36 + ds)
	f.store_buffer("WAVEfmt ".to_ascii_buffer()); f.store_32(16)
	f.store_16(1); f.store_16(1); f.store_32(RATE)
	f.store_32(RATE * 2); f.store_16(2); f.store_16(16)
	f.store_buffer("data".to_ascii_buffer()); f.store_32(ds)
	f.store_buffer(pcm); f.close()
	print("写入 ", path)


func _sheet() -> void:
	var sheet := CueSheet.new()
	sheet.fps = 30
	sheet.tracks = [
		CueTrack.new(&"peter", Color(0.40, 0.70, 1.00)),
		CueTrack.new(&"john", Color(1.00, 0.65, 0.30)),
	]

	var p := CueAudioSegment.new(&"Peter", PETER, 0.0)
	p.stream = load(PETER)
	p.waveform = CueWaveformBuilder.new().build(CuePcmReader.read_wav_file(PETER), 256)

	var j := CueAudioSegment.new(&"John", JOHN, JOHN_OFFSET)
	j.stream = load(JOHN)
	j.waveform = CueWaveformBuilder.new().build(CuePcmReader.read_wav_file(JOHN), 256)

	sheet.segments = [p, j] as Array[CueAudioSegment]

	# 标记时间轴跨两段统一 —— 这正是 D10′ 的意义:
	# await Cue.at(&"john_line_1") 不必关心那句话录在哪个文件里。
	for d in [
		[&"peter_line_1", 0.15, &"peter"],
		[&"peter_line_2", 0.85, &"peter"],
		[&"john_line_1", JOHN_OFFSET + 0.10, &"john"],
		[&"john_line_2", JOHN_OFFSET + 0.75, &"john"],
	]:
		sheet.add_marker(CueMarker.new(d[0], d[1], d[2]))

	# 包络跨全部片段拼出来
	var env := CueEnvelope.new()
	env.rate = CueEnvelopeBuilder.DEFAULT_RATE
	env.duration = sheet.duration()
	var vals := PackedFloat32Array()
	vals.resize(int(ceil(env.duration * env.rate)))
	for seg in sheet.all_segments():
		var part := CueEnvelopeBuilder.from_cache(seg.waveform, env.rate)
		var base := int(round(seg.offset * env.rate))
		for i in part.values.size():
			var k := base + i
			if k >= 0 and k < vals.size():
				vals[k] = maxf(vals[k], part.values[i])
	env.values = vals
	sheet.envelope = CueEnvelopeBuilder.normalized(env)

	print("写入 %s(%d 段,%d 标记,总长 %.2fs)→ %d"
		% [SHEET, sheet.segments.size(), sheet.markers.size(), sheet.duration(),
			ResourceSaver.save(sheet, SHEET)])
