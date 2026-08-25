extends SceneTree

func _init() -> void:
	print("--- 枚举值 ---")
	print("FORMAT_8_BITS=", AudioStreamWAV.FORMAT_8_BITS,
		" FORMAT_16_BITS=", AudioStreamWAV.FORMAT_16_BITS,
		" FORMAT_IMA_ADPCM=", AudioStreamWAV.FORMAT_IMA_ADPCM,
		" FORMAT_QOA=", AudioStreamWAV.FORMAT_QOA)

	var w: AudioStreamWAV = load("res://tests/probe/tone_1s.wav")
	print("--- 默认导入(compress/mode=2)---")
	print("class=", w.get_class(), " format=", w.format, " stereo=", w.stereo,
		" mix_rate=", w.mix_rate, " data_size=", w.data.size(),
		" length=", w.get_length())
	print("有 get_data 方法? ", w.has_method("get_data"))

	print("--- PackedByteArray 批量转换 ---")
	var pb := PackedByteArray([0x00, 0x80, 0xFF, 0x7F])   # -32768, 32767
	print("  decode_s16(0)=", pb.decode_s16(0), " decode_s16(2)=", pb.decode_s16(2))
	print("  to_int32_array()=", pb.to_int32_array())

	print("--- AudioServer(headless/Dummy)---")
	print("output_latency=", AudioServer.get_output_latency(),
		" time_since_last_mix=", AudioServer.get_time_since_last_mix(),
		" mix_rate=", AudioServer.get_mix_rate())

	print("--- Movie 特性 ---")
	print("OS.has_feature('movie')=", OS.has_feature("movie"))
	print("cmdline=", OS.get_cmdline_args())
	quit()
