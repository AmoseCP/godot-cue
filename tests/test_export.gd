extends SceneTree

## 振幅包络 + 剧本骨架生成的测试。
##   godot --headless --path . --script tests/test_export.gd

var _pass := 0
var _fail := 0


func _init() -> void:
	_test_envelope_build()
	_test_envelope_sampling()
	_test_envelope_levels()
	_test_envelope_normalize()
	_test_envelope_export_files()
	_test_generate_basic()
	_test_generate_filter_and_escape()
	_test_generated_script_compiles()
	_test_marker_json_roundtrip()
	_test_marker_csv()
	print("\n=== %d 通过 / %d 失败 ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func ok(c: bool, w: String) -> void:
	if c: _pass += 1; print("  PASS  ", w)
	else: _fail += 1; print("  FAIL  ", w)

func eq(a: Variant, b: Variant, w: String) -> void:
	ok(a == b, "%s (得到 %s,期望 %s)" % [w, a, b])

func near(a: float, b: float, tol: float, w: String) -> void:
	ok(absf(a - b) <= tol, "%s (得到 %.5f,期望 %.5f ±%.5f)" % [w, a, b, tol])


## 前半段幅度 0.2、后半段 0.8 的合成缓存,正好 1 秒。
func _cache(first: float = 0.2, second: float = 0.8) -> WaveformCache:
	var wf := WaveformCache.new()
	wf.mix_rate = 44100
	wf.samples_per_bucket = 256
	var n := int(round(44100.0 / 256.0))      # ≈172 个 bucket = 1 秒
	var mins := PackedFloat32Array(); mins.resize(n)
	var maxs := PackedFloat32Array(); maxs.resize(n)
	for i in n:
		var a: float = first if i < n / 2 else second
		mins[i] = -a
		maxs[i] = a
	wf.mins = mins
	wf.maxs = maxs
	wf.duration = 1.0
	return wf


func _test_envelope_build() -> void:
	print("\n[包络] 从峰值缓存生成")
	var env := CueEnvelopeBuilder.from_cache(_cache(), 10.0)
	ok(env.is_valid(), "包络有效")
	eq(env.count(), 10, "1 秒 @10Hz = 10 个点")
	near(env.rate, 10.0, 1e-6, "采样率")
	near(env.duration, 1.0, 1e-6, "时长")
	near(env.values[0], 0.2, 0.01, "前半段幅度")
	near(env.values[9], 0.8, 0.01, "后半段幅度")

	var empty := CueEnvelopeBuilder.from_cache(null, 10.0)
	ok(not empty.is_valid(), "空缓存给出无效包络而不是崩溃")
	var bad_rate := CueEnvelopeBuilder.from_cache(_cache(), 0.0)
	ok(not bad_rate.is_valid(), "非法采样率被拒绝")

	# 高采样率下相邻点共用 bucket,不能出现空洞
	var dense := CueEnvelopeBuilder.from_cache(_cache(), 600.0)
	eq(dense.count(), 600, "600Hz 下 600 个点")
	var zeros := 0
	for v in dense.values:
		if v <= 0.0:
			zeros += 1
	eq(zeros, 0, "高采样率下没有空洞点")


func _test_envelope_sampling() -> void:
	print("\n[包络] at() 取值与插值")
	var env := CueEnvelope.new()
	env.rate = 10.0
	env.duration = 0.5
	env.values = PackedFloat32Array([0.0, 0.5, 1.0, 0.5, 0.0])

	near(env.at(0.0), 0.0, 1e-6, "t=0")
	near(env.at(0.1), 0.5, 1e-6, "t=0.1 正好第 1 个点")
	near(env.at(0.05), 0.25, 1e-6, "两点之间线性插值")
	near(env.at(0.15), 0.75, 1e-6, "第 1、2 点之间")
	near(env.at(-5.0), 0.0, 1e-6, "负时间夹到第一个点")
	near(env.at(99.0), 0.0, 1e-6, "超出末尾夹到最后一个点")

	# 纯函数:反复问同一个 t 必须一样
	var stable := true
	for i in 50:
		if not is_equal_approx(env.at(0.137), env.at(0.137)):
			stable = false
	ok(stable, "at() 是纯函数")

	near(env.peak(), 1.0, 1e-6, "峰值")
	var blank := CueEnvelope.new()
	near(blank.at(1.0), 0.0, 1e-6, "空包络返回 0 而不是崩溃")


func _test_envelope_levels() -> void:
	print("\n[包络] 分档")
	var env := CueEnvelope.new()
	env.rate = 10.0
	env.values = PackedFloat32Array([0.0, 0.10, 0.25, 0.50, 0.90])
	var th := PackedFloat32Array([0.06, 0.18, 0.38])

	eq(env.level(0.0, th), 0, "静音 → 第 0 档")
	eq(env.level(0.1, th), 1, "0.10 越过第一个阈值 → 第 1 档")
	eq(env.level(0.2, th), 2, "0.25 → 第 2 档")
	eq(env.level(0.3, th), 3, "0.50 → 第 3 档")
	eq(env.level(0.4, th), 3, "0.90 仍是最高档(只有三个阈值)")
	eq(env.level(0.0, PackedFloat32Array()), 0, "没有阈值时恒为第 0 档")


func _test_envelope_normalize() -> void:
	print("\n[包络] 归一化")
	var env := CueEnvelopeBuilder.from_cache(_cache(0.1, 0.4), 10.0)
	near(env.peak(), 0.4, 0.01, "归一化前峰值")
	CueEnvelopeBuilder.normalized(env)
	near(env.peak(), 1.0, 0.01, "归一化后峰值为 1")
	near(env.values[0], 0.25, 0.02, "比例关系保持不变(0.1/0.4)")

	# 全静音不能除零
	var silent := CueEnvelopeBuilder.from_cache(_cache(0.0, 0.0), 10.0)
	CueEnvelopeBuilder.normalized(silent)
	near(silent.peak(), 0.0, 1e-6, "全静音归一化后仍是 0,不会除零")


func _test_envelope_export_files() -> void:
	print("\n[包络] 导出 JSON / CSV")
	var env := CueEnvelopeBuilder.from_cache(_cache(), 20.0)
	eq(env.export_json("user://env.json"), OK, "写 JSON")
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string("user://env.json"))
	ok(j is Dictionary, "JSON 可解析")
	eq(int(j["count"]), env.count(), "count 字段与实际条数一致")
	near(float(j["rate"]), 20.0, 1e-6, "rate 字段")
	eq((j["values"] as Array).size(), env.count(), "values 长度一致")
	near(float((j["values"] as Array)[0]), env.values[0], 1e-3, "第一个值(四舍五入到 4 位)")

	eq(env.export_csv("user://env.csv"), OK, "写 CSV")
	var lines := FileAccess.get_file_as_string("user://env.csv").split("\n", false)
	eq(lines[0], "time,amplitude", "CSV 表头")
	eq(lines.size(), env.count() + 1, "CSV 行数 = 表头 + 数据")
	ok(lines[1].begins_with("0.0000,"), "第一行时间是 0:%s" % lines[1])

	# 换音频后哈希不匹配 → 包络失效
	env.source_hash = "deadbeef"
	ok(not env.matches("res://tests/fixtures/sample_rhubarb.json"), "哈希不匹配 → 失效")


# ── 剧本骨架 ────────────────────────────────────────────────────────

func _sheet() -> CueSheet:
	var s := CueSheet.new()
	s.fps = 30
	s.add_marker(CueMarker.new(&"john_looks_up", 1.45, &"action"))
	s.add_marker(CueMarker.new(&"peter_enters", 0.30, &"action"))
	s.add_marker(CueMarker.new(&"peter_line_1", 0.85, &"dialogue"))
	s.add_marker(CueMarker.new(&"m_0001", 0.90, &"mouth"))
	return s


func _test_generate_basic() -> void:
	print("\n[剧本] 基本生成")
	var text := CueScriptGenerator.generate(_sheet())
	ok(text.begins_with("extends Node2D"), "以 extends 开头")
	eq(text.count("await Cue.at("), 4, "每个标记一个 await")
	ok(text.contains("await Cue.at(&\"peter_enters\")"), "包含标记名")
	ok(text.contains("func _shot() -> void:"), "生成了序列函数")
	ok(text.contains("# 0.300s / f9"), "注释里有时间和帧号")
	ok(text.contains("[action]"), "注释里有轨道名")

	# 顺序必须按时间排,不是按加入顺序
	var i_enter := text.find("peter_enters")
	var i_line := text.find("peter_line_1")
	var i_look := text.find("john_looks_up")
	ok(i_enter < i_line and i_line < i_look, "await 顺序按时间升序")

	# 没有标记时也要生成合法文件
	var blank := CueScriptGenerator.generate(CueSheet.new())
	ok(blank.contains("pass"), "空 sheet 生成 pass 占位")
	ok(not blank.contains("await Cue.at("), "空 sheet 没有 await")

	var opts := CueScriptGenerator.Options.new()
	opts.comments = false
	opts.extends_type = "Node"
	opts.func_name = "run"
	var plain := CueScriptGenerator.generate(_sheet(), opts)
	ok(plain.begins_with("extends Node\n"), "可指定基类")
	ok(plain.contains("func run() -> void:"), "可指定函数名")
	ok(not plain.contains("# 0.300s"), "可关闭注释")


func _test_generate_filter_and_escape() -> void:
	print("\n[剧本] 轨道过滤与转义")
	var opts := CueScriptGenerator.Options.new()
	opts.tracks = PackedStringArray(["action"])
	var text := CueScriptGenerator.generate(_sheet(), opts)
	eq(text.count("await Cue.at("), 2, "只生成 action 轨的两个标记")
	ok(not text.contains("peter_line_1"), "dialogue 轨被过滤掉")
	ok(not text.contains("m_0001"), "mouth 轨被过滤掉")

	# 名字里带引号和反斜杠不能生成出语法错误
	var s := CueSheet.new()
	s.add_marker(CueMarker.new(&'say_"hi"', 0.5))
	s.add_marker(CueMarker.new(&"back\\slash", 1.0))
	var t2 := CueScriptGenerator.generate(s)
	ok(t2.contains('&"say_\\"hi\\""'), "引号被转义:%s" % t2.substr(t2.find("say_"), 20))
	ok(t2.contains('back\\\\slash'), "反斜杠被转义")


func _test_generated_script_compiles() -> void:
	print("\n[剧本] 生成的代码必须真的能编译")
	# 这条是整组测试里最有价值的一条 —— 字符串拼出来的代码,
	# 只有真正丢给 GDScript 编译器才知道缩进、转义、字面量是不是都对。
	#
	# 但 --script 模式下引擎[b]不注册自动加载[/b],`Cue` 这个全局标识符
	# 解析不了(实测 "Compile Error: Identifier not found: Cue")。
	# 所以这里把 Cue 换成一个 Variant 桩再编译 —— 结构性错误照样能抓到,
	# 而"Cue 那几行在真实项目里对不对"由 tests/edit_harness/ 在编辑器里验。
	var opts := CueScriptGenerator.Options.new()
	opts.include_ready = false          # 不 preload,避免依赖具体资源路径
	for case in [_sheet(), CueSheet.new(), _tricky_sheet()]:
		var text := CueScriptGenerator.generate(case, opts)
		var gd := GDScript.new()
		gd.source_code = _stub_cue(text)
		var err := gd.reload()
		ok(err == OK, "生成的脚本编译通过(错误码 %d)" % err)

	var full := CueScriptGenerator.Options.new()
	full.sheet_path = "res://examples/hello_cue/shot_01.tres"
	var text2 := CueScriptGenerator.generate(_sheet(), full)
	ok(text2.contains("const SHEET := preload("), "包含 preload")
	ok(text2.contains("Cue.load_sheet(SHEET)"), "包含 load_sheet")
	ok(text2.contains("\tCue.play()"), "包含 play(),且缩进是制表符")


## 把全局的 Cue 换成一个 Variant 桩,好让脚本在没有自动加载的环境里也能编译。
func _stub_cue(text: String) -> String:
	var body := text.replace("Cue.", "_cue_stub.")
	# 插在 extends 行之后
	var nl := body.find("\n")
	return body.substr(0, nl + 1) + "\nvar _cue_stub: Variant = null\n" + body.substr(nl + 1)


func _tricky_sheet() -> CueSheet:
	var s := CueSheet.new()
	s.add_marker(CueMarker.new(&'quote_"x"', 0.1))
	s.add_marker(CueMarker.new(&"中文标记名", 0.2))
	s.add_marker(CueMarker.new(&"back\\slash", 0.3))
	s.add_marker(CueMarker.new(&"tab\there", 0.4))
	return s


# ── 标记导出 ────────────────────────────────────────────────────────

func _export_sheet() -> CueSheet:
	var s := CueSheet.new()
	s.fps = 30
	s.tracks = [CueTrack.new(&"dialogue", Color(1, 0, 0)),
		CueTrack.new(&"mouth", Color(0, 1, 0))]
	var seg := CueAudioSegment.new(&"Peter", "res://vo/peter.wav", 0.0)
	var w := WaveformCache.new()
	w.mins = PackedFloat32Array([-1.0]); w.maxs = PackedFloat32Array([1.0])
	w.mix_rate = 44100; w.duration = 3.0
	seg.waveform = w
	s.segments = [seg] as Array[CueAudioSegment]

	var m1 := CueMarker.new(&"line_1", 0.5, &"dialogue")
	m1.payload = {"text": "你好,世界", "end": 1.2}
	s.add_marker(m1)
	var m2 := CueMarker.new(&"m_0000", 0.55, &"mouth")
	m2.payload = {"shape": "B", "end": 0.7}
	s.add_marker(m2)
	# 名字和文本里带逗号、引号、换行 —— CSV 的经典雷区
	var m3 := CueMarker.new(&"tricky,name", 1.8, &"dialogue")
	m3.payload = {"text": "他说:\"走吧\",然后\n换行了"}
	s.add_marker(m3)
	return s


func _test_marker_json_roundtrip() -> void:
	print("\n[导出] 标记 JSON 往返")
	var sheet := _export_sheet()
	eq(CueMarkerExport.save_json(sheet, "user://mk.json"), OK, "写 JSON")

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("user://mk.json"))
	ok(parsed is Dictionary, "JSON 可解析")
	var d := parsed as Dictionary
	eq(int(d["cue_format"]), CueMarkerExport.FORMAT_VERSION, "带格式版本号")
	eq(int(d["fps"]), 30, "fps")
	near(float(d["duration"]), 3.0, 1e-4, "duration")
	eq((d["markers"] as Array).size(), 3, "三个标记")
	eq((d["tracks"] as Array).size(), 2, "两条轨道")
	eq((d["segments"] as Array).size(), 1, "一个音频片段")
	eq(((d["segments"] as Array)[0] as Dictionary)["name"], "Peter", "片段名")

	# 无损回读
	var back := CueMarkerExport.from_json("user://mk.json")
	ok(back.ok(), "读回成功:%s" % back.error)
	eq(back.markers.size(), 3, "回读三个标记")
	eq(back.source_entries, 3, "条目数")
	var by_name := {}
	for m in back.markers:
		by_name[String(m.name)] = m
	ok(by_name.has("line_1"), "普通名字回来了")
	ok(by_name.has("tricky,name"), "带逗号的名字回来了")
	near(by_name["line_1"].time, 0.5, 1e-6, "时间无损")
	eq(String(by_name["line_1"].track), "dialogue", "轨道无损")
	eq(by_name["line_1"].payload["text"], "你好,世界", "中文 payload 无损")
	eq(by_name["m_0000"].payload["shape"], "B", "口型 payload 无损")
	eq(by_name["tricky,name"].payload["text"], "他说:\"走吧\",然后\n换行了",
		"引号和换行都无损")

	# 排序后导出 → 回读顺序一致
	var order_out: Array[String] = []
	for m in sheet.sorted():
		order_out.append(String(m.name))
	var order_in: Array[String] = []
	for m in back.markers:
		order_in.append(String(m.name))
	ok(order_out == order_in, "导出顺序 = 排序顺序,回读保持:%s" % [order_in])

	# 坏输入
	var f := FileAccess.open("user://notcue.json", FileAccess.WRITE)
	f.store_string('{"somethingElse": 1}')
	f.close()
	var bad := CueMarkerExport.from_json("user://notcue.json")
	ok(not bad.ok() and bad.error.contains("markers"), "缺 markers 数组 → 中文错误")
	ok(not CueMarkerExport.from_json("res://没有.json").ok(), "文件不存在 → 被拒绝")


func _test_marker_csv() -> void:
	print("\n[导出] 标记 CSV")
	var sheet := _export_sheet()
	eq(CueMarkerExport.save_csv(sheet, "user://mk.csv"), OK, "写 CSV")
	var text := FileAccess.get_file_as_string("user://mk.csv")
	var lines := text.split("\n", false)
	eq(lines[0], CueMarkerExport.CSV_HEADER, "表头")
	eq(lines.size(), 4, "表头 + 3 行 —— 便利列里的换行被压平,一行一条记录")
	eq(text.count("\n"), 4, "整个文件只有 4 个裸换行(表头 + 3 条记录),没有把记录撑成两行的")

	# 第一行是时间最早的 line_1
	ok(lines[1].begins_with("line_1,0.500000,15,dialogue,"),
		"名字/时间/帧号/轨道:%s" % lines[1])
	ok(lines[1].contains("你好"), "text 便利列有内容")

	# 带逗号的名字必须被引号包起来,否则列会错位
	var tricky := ""
	for L in lines:
		if L.contains("tricky"):
			tricky = L
	ok(tricky.begins_with("\"tricky,name\","), "带逗号的名字被引号包住:%s" % tricky.substr(0, 40))
	ok(tricky.contains("\"\""), "内部引号被翻倍转义")
	# 多层转义容易写错,直接用 char(92) 拼一个反斜杠出来,意图更清楚
	var bs := char(92)
	ok(tricky.contains("然后" + bs + "n换行了"), "text 列里的换行压成了字面的 backslash-n")
	# payload 列里两套转义叠在一起:JSON 先把引号写成 \" ,CSV 再把 " 翻倍,
	# 于是最终是 反斜杠 + 两个引号。这个叠加关系正是最容易写错的地方。
	ok(tricky.contains(bs + '""'), "payload 列:JSON 转义之上再叠一层 CSV 引号翻倍")

	# 帧号 = round(time * fps)
	ok(lines[2].contains(",17,") or lines[2].contains(",16,"),
		"0.55s @30fps → f16/f17:%s" % lines[2])
