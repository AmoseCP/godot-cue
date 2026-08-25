extends SceneTree

## M5 验收:导入器解析正确性。
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_import.gd

const RHUBARB := "res://tests/fixtures/sample_rhubarb.json"
const MFA := "res://tests/fixtures/sample_mfa.TextGrid"
const SHORT := "res://tests/fixtures/sample_short.TextGrid"

var _pass := 0
var _fail := 0


func _init() -> void:
	_test_rhubarb()
	_test_rhubarb_errors()
	_test_textgrid_long()
	_test_textgrid_short()
	_test_textgrid_errors()
	_test_frame_accuracy()
	_test_no_duplicate_names_on_reimport()
	_test_phoneme_attach()
	print("\n=== %d 通过 / %d 失败 ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func ok(c: bool, w: String) -> void:
	if c: _pass += 1; print("  PASS  ", w)
	else: _fail += 1; print("  FAIL  ", w)

func eq(a: Variant, b: Variant, w: String) -> void:
	ok(a == b, "%s (得到 %s,期望 %s)" % [w, a, b])

func near(a: float, b: float, tol: float, w: String) -> void:
	ok(absf(a - b) <= tol, "%s (得到 %.4f,期望 %.4f)" % [w, a, b])


func _test_rhubarb() -> void:
	print("\n[Rhubarb] 解析")
	var r := CueRhubarbImporter.parse(RHUBARB)
	ok(r.ok(), "解析成功:%s" % r.error)
	# M5 验收:标记数量与源文件条目数一致
	eq(r.source_entries, 12, "源文件 mouthCues 条目数")
	eq(r.markers.size(), 12, "标记数量与条目数一致")
	eq(String(r.markers[0].name), "m_0000", "命名规则")
	near(r.markers[0].time, 0.0, 1e-6, "第 0 个标记时间")
	eq(String(r.markers[0].track), "mouth", "落在 mouth 轨")
	eq(r.markers[0].payload["shape"], "X", "第 0 个口型是 X")
	eq(r.markers[1].payload["shape"], "B", "第 1 个口型是 B")
	near(r.markers[1].time, 0.21, 1e-6, "第 1 个标记时间")
	near(float(r.markers[1].payload["end"]), 0.30, 1e-6, "payload 带 end")
	eq(r.markers[11].payload["shape"], "X", "最后一个回到闭嘴")
	ok(r.summary().contains("2.85"), "摘要里带上了源文件时长")

	# 时间必须单调不减
	var mono := true
	for i in range(1, r.markers.size()):
		if r.markers[i].time < r.markers[i - 1].time:
			mono = false
	ok(mono, "时间单调不减")

	# 自定义轨道名和前缀
	var r2 := CueRhubarbImporter.parse(RHUBARB, &"嘴型", "口")
	eq(String(r2.markers[0].track), "嘴型", "可指定轨道名")
	eq(String(r2.markers[0].name), "口_0000", "可指定名字前缀")


func _test_rhubarb_errors() -> void:
	print("\n[Rhubarb] 坏输入")
	var miss := CueRhubarbImporter.parse("res://tests/fixtures/没有这个.json")
	ok(not miss.ok() and miss.error.contains("找不到"), "文件不存在 → 中文错误")

	var f := FileAccess.open("user://bad.json", FileAccess.WRITE)
	f.store_string("{ 这不是 json ")
	f.close()
	var bad := CueRhubarbImporter.parse("user://bad.json")
	ok(not bad.ok() and bad.error.contains("JSON"), "坏 JSON → 中文错误:%s" % bad.error)

	f = FileAccess.open("user://wrong.json", FileAccess.WRITE)
	f.store_string('{"somethingElse": []}')
	f.close()
	var wrong := CueRhubarbImporter.parse("user://wrong.json")
	ok(not wrong.ok() and wrong.error.contains("mouthCues"), "缺 mouthCues → 说明该用什么命令:%s" % wrong.error)


func _test_textgrid_long() -> void:
	print("\n[TextGrid] 长格式(MFA 输出)")
	var r := CueTextGridImporter.parse(MFA)
	ok(r.ok(), "解析成功:%s" % r.error)
	eq(r.source_entries, 11, "两条 tier 共 11 个区间")
	# words 有 2 个非空,phones 有 4 个非空;空区间共 5 个
	eq(r.markers.size(), 6, "跳过 5 个空区间后剩 6 个标记")
	eq(Array(r.tracks), ["words", "phones"], "解析出两条轨道")

	var words: Array = r.markers.filter(func(m: CueMarker) -> bool: return m.track == &"words")
	var phones: Array = r.markers.filter(func(m: CueMarker) -> bool: return m.track == &"phones")
	eq(words.size(), 2, "词级标记数")
	eq(phones.size(), 4, "音素级标记数")
	near(words[0].time, 0.21, 1e-6, "第一个词的起点")
	eq(words[0].payload["text"], "你好", "中文文本正确读出")
	near(float(words[0].payload["end"]), 0.71, 1e-6, "词的结束时间")
	eq(words[1].payload["text"], "世界", "第二个词")
	eq(phones[0].payload["text"], "n i3", "音素串")
	ok(r.notes.size() > 0 and r.notes[0].contains("5"), "提示跳过了 5 个空区间:%s" % r.notes)

	# 不跳过空区间时,数量应等于源条目数
	var keep := CueTextGridImporter.parse(MFA, false)
	eq(keep.markers.size(), 11, "保留空区间时标记数 = 源条目数")


func _test_textgrid_short() -> void:
	print("\n[TextGrid] 短格式(Praat 手动导出)")
	var r := CueTextGridImporter.parse(SHORT)
	ok(r.ok(), "解析成功:%s" % r.error)
	eq(r.source_entries, 3, "3 个区间")
	eq(r.markers.size(), 2, "跳过 1 个空区间")
	eq(r.markers[0].payload["text"], "hello", "第一个词")
	near(r.markers[0].time, 0.2, 1e-6, "第一个词起点")
	eq(r.markers[1].payload["text"], "world", "第二个词")
	near(r.markers[1].time, 0.9, 1e-6, "第二个词起点")


func _test_textgrid_errors() -> void:
	print("\n[TextGrid] 坏输入")
	var f := FileAccess.open("user://notgrid.txt", FileAccess.WRITE)
	f.store_string("just some text")
	f.close()
	var r := CueTextGridImporter.parse("user://notgrid.txt")
	ok(not r.ok() and r.error.contains("TextGrid"), "非 TextGrid → 中文错误:%s" % r.error)
	var miss := CueTextGridImporter.parse("res://没有.TextGrid")
	ok(not miss.ok(), "文件不存在 → 被拒绝")


func _test_frame_accuracy() -> void:
	print("\n[M5 验收] 时间戳误差 < 1 帧")
	var sheet := CueSheet.new()
	sheet.fps = 30
	var one_frame := 1.0 / 30.0
	var r := CueRhubarbImporter.parse(RHUBARB)
	var expect := [0.00, 0.21, 0.30, 0.42, 0.55, 0.71, 0.99, 1.24, 1.50, 1.83, 2.10, 2.44]
	var worst := 0.0
	for i in r.markers.size():
		worst = maxf(worst, absf(r.markers[i].time - float(expect[i])))
	ok(worst < one_frame, "Rhubarb 时间戳最大误差 %.6fs < 1 帧(%.4fs)" % [worst, one_frame])
	ok(worst == 0.0, "实际上是精确值(误差 %.9f)" % worst)


func _test_no_duplicate_names_on_reimport() -> void:
	print("\n[M5 验收] 重复导入不产生重名")
	var sheet := CueSheet.new()
	sheet.fps = 30
	for round in 2:
		var r := CueRhubarbImporter.parse(RHUBARB)
		for m in r.markers:
			m.name = sheet.unique_name(m.name)
			sheet.add_marker(m)
	eq(sheet.markers.size(), 24, "导入两次共 24 个标记")
	var issues := sheet.validate()
	ok(issues.is_empty(), "无重名(%s)" % issues)
	ok(sheet.has(&"m_0000") and sheet.has(&"m_0000_1"), "第二次导入自动加后缀")


func _test_phoneme_attach() -> void:
	print("\n[Rhubarb] 口型序列挂到对白标记上")
	var r := CueRhubarbImporter.parse(RHUBARB)
	var host := CueMarker.new(&"line_1", 0.21, &"dialogue")
	CueRhubarbImporter.attach_to(host, r.markers, 1.50)
	var seq: Array = host.payload["phonemes"]
	ok(seq.size() > 0, "挂上了 %d 个口型" % seq.size())
	near(float(seq[0]["t"]), 0.0, 1e-6, "第一个口型相对宿主是 0")
	eq(seq[0]["shape"], "B", "第一个口型是 B")
	# 相对时间意味着整句被挪动时口型跟着走
	var last_t := float(seq[seq.size() - 1]["t"])
	near(last_t, 1.50 - 0.21, 1e-6, "最后一个口型的相对时间")

	var sheet := CueSheet.new()
	sheet.add_marker(host)
	var cue: Node = preload("res://addons/cue/runtime/cue.gd").new()
	root.add_child(cue)
	cue.load_sheet(sheet)
	eq(cue.phonemes(&"line_1").size(), seq.size(), "Cue.phonemes() 读回同一串")
	cue.queue_free()
