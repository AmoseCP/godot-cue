extends SceneTree

## 生成确定性测试用的音频和 CueSheet。

const DUR := 3.0
const RATE := 44100
const WAV := "res://tests/determinism/tone_3s.wav"
const SHEET := "res://tests/determinism/test_sheet.tres"

func _init() -> void:
	var n := int(RATE * DUR)
	var pcm := PackedByteArray(); pcm.resize(n * 2)
	for i in n:
		var t := float(i) / RATE
		var v := sin(TAU * 330.0 * t) * 0.7 * (0.5 + 0.5 * sin(TAU * 1.5 * t))
		pcm.encode_s16(i * 2, int(v * 32767.0))
	var f := FileAccess.open(WAV, FileAccess.WRITE)
	var ds := pcm.size()
	f.store_buffer("RIFF".to_ascii_buffer()); f.store_32(36 + ds)
	f.store_buffer("WAVEfmt ".to_ascii_buffer()); f.store_32(16)
	f.store_16(1); f.store_16(1); f.store_32(RATE)
	f.store_32(RATE * 2); f.store_16(2); f.store_16(16)
	f.store_buffer("data".to_ascii_buffer()); f.store_32(ds)
	f.store_buffer(pcm); f.close()

	var sheet := CueSheet.new()
	sheet.fps = 30
	sheet.audio_path = WAV
	sheet.waveform = CueWaveformBuilder.new().build(CuePcmReader.read_wav_file(WAV), 256)
	sheet.envelope = CueEnvelopeBuilder.normalized(
		CueEnvelopeBuilder.from_cache(sheet.waveform))
	# 刻意用非帧对齐的时间,逼出"标记落在两帧之间"的情况
	for d in [[&"start", 0.05], [&"beat_a", 0.417], [&"beat_b", 0.933],
			[&"beat_c", 1.5], [&"beat_d", 2.017], [&"tail", 2.6]]:
		sheet.add_marker(CueMarker.new(d[0], d[1], &"dialogue"))
	print("保存 sheet: ", ResourceSaver.save(sheet, SHEET))
	quit()
