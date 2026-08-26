extends SceneTree

const CueScript := preload("res://addons/cue/runtime/cue.gd")
var _cue: Node

func _init() -> void:
	_cue = CueScript.new()
	_cue.name = "Cue"
	root.call_deferred("add_child", _cue)
	_run.call_deferred()

func _run() -> void:
	CueClock.force_mode = 1
	await process_frame

	var s := CueSheet.new()
	s.fps = 30
	for d in [[&"a", 0.20], [&"b", 0.60], [&"c", 1.00]]:
		s.add_marker(CueMarker.new(d[0], d[1]))
	var w := WaveformCache.new()
	w.mins = PackedFloat32Array([0.0]); w.maxs = PackedFloat32Array([0.0])
	w.mix_rate = 44100; w.duration = 10.0
	s.waveform = w
	_cue.load_sheet(s)

	var order: Array[String] = []
	var task := func() -> void:
		await _cue.at(&"a"); order.append("a")
		await _cue.at(&"b"); order.append("b")
		await _cue.at(&"c"); order.append("c")
	task.call()
	print("PROBE task.call() 之后 order=", order, " time=", _cue.time())

	_cue.play(0.0)
	print("PROBE play(0) 之后 time=", _cue.time(), " clock.render_fps=", _cue.clock().render_fps())
	for i in 8:
		await process_frame
		print("PROBE 第 %d 帧 time=%.3f order=%s" % [i, _cue.time(), order])
	quit()
