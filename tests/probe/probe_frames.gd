extends SceneTree

func _init() -> void:
	_run.call_deferred()

func _adv_void(n: int) -> void:
	for i in n:
		await process_frame

func _adv_ret(n: int) -> bool:
	for i in n:
		await process_frame
	return true

func _run() -> void:
	print("A 起始 frames_drawn=", Engine.get_frames_drawn())
	var f0 := Engine.get_frames_drawn()
	for i in 6:
		await process_frame
	print("B 直接循环 6 次后 frames_drawn 增量=", Engine.get_frames_drawn() - f0)

	f0 = Engine.get_frames_drawn()
	await _adv_void(6)
	print("C await 一个 -> void 协程 6 次后增量=", Engine.get_frames_drawn() - f0)

	f0 = Engine.get_frames_drawn()
	await _adv_ret(6)
	print("D await 一个 -> bool 协程 6 次后增量=", Engine.get_frames_drawn() - f0)

	print("=== 闭包捕获语义 ===")
	var flag := false
	var arr: Array = []
	var lam := func() -> void:
		flag = true
		arr.append("x")
	lam.call()
	print("E 赋值局部 bool 后,外部 flag=", flag, "(false = 按值捕获)")
	print("F 修改局部 Array 后,外部 arr=", arr, "(有内容 = 按引用)")
	quit()
