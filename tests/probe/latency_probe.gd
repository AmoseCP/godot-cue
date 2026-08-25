extends Node

func _ready() -> void:
	var p := AudioStreamPlayer.new()
	add_child(p)
	p.stream = load("res://tests/determinism/tone_3s.wav")
	p.play()
	await get_tree().create_timer(0.4).timeout
	print("LAT driver=", AudioServer.get_driver_name() if AudioServer.has_method("get_driver_name") else ProjectSettings.get_setting("audio/driver/driver", "?"))
	print("LAT output_latency=", AudioServer.get_output_latency())
	print("LAT time_since_last_mix=", AudioServer.get_time_since_last_mix())
	print("LAT mix_rate=", AudioServer.get_mix_rate())
	print("LAT playback_position=", p.get_playback_position())
	var compensated := p.get_playback_position() + AudioServer.get_time_since_last_mix() - AudioServer.get_output_latency()
	print("LAT 补偿后=", compensated, "  差值=", compensated - p.get_playback_position())
	get_tree().quit()
