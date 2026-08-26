extends SceneTree

## 字幕文本与波形对照(P2)的测试。
##   godot --headless --path . --script tests/test_subtitles.gd

var _pass := 0
var _fail := 0


func _init() -> void:
	_test_text_tracks()
	_test_text_at()
	_test_from_textgrid()
	print("\n=== %d 通过 / %d 失败 ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func ok(c: bool, w: String) -> void:
	if c: _pass += 1; print("  PASS  ", w)
	else: _fail += 1; print("  FAIL  ", w)

func eq(a: Variant, b: Variant, w: String) -> void:
	ok(a == b, "%s (得到 「%s」,期望 「%s」)" % [w, a, b])


func _sheet() -> CueSheet:
	var s := CueSheet.new()
	s.fps = 30
	var a := CueMarker.new(&"w1", 0.20, &"words")
	a.payload = {"text": "你好", "end": 0.70}
	var b := CueMarker.new(&"w2", 1.00, &"words")
	b.payload = {"text": "世界", "end": 2.40}
	var c := CueMarker.new(&"p1", 0.20, &"phones")
	c.payload = {"text": "n i3", "end": 0.42}
	var d := CueMarker.new(&"beat", 0.50, &"action")      # 没有 text
	for m in [a, b, c, d]:
		s.add_marker(m)
	return s


func _test_text_tracks() -> void:
	print("\n[字幕] 哪些轨有文本")
	var s := _sheet()
	var tracks := s.text_tracks()
	eq(Array(tracks), [&"words", &"phones"], "只列出带 text 的轨,按出现顺序")
	ok(not tracks.has(&"action"), "没有 text 的轨不进字幕条")

	# 空字符串不算有文本
	var s2 := CueSheet.new()
	var m := CueMarker.new(&"x", 0.0, &"t")
	m.payload = {"text": "   "}
	s2.add_marker(m)
	ok(s2.text_tracks().is_empty(), "只有空白文本的轨不算文本轨")
	ok(CueSheet.new().text_tracks().is_empty(), "空 sheet 没有文本轨")


func _test_text_at() -> void:
	print("\n[字幕] 按时间查文本")
	var s := _sheet()
	eq(s.text_at(0.0, &"words"), "", "第一个词之前是空的")
	eq(s.text_at(0.20, &"words"), "你好", "词的起点")
	eq(s.text_at(0.50, &"words"), "你好", "词的中间")
	eq(s.text_at(0.70, &"words"), "你好", "正好在 end 上仍然显示")
	# 关键:越过 end 就要消失,否则 MFA 的词级切分会让上一个词一直挂着
	eq(s.text_at(0.85, &"words"), "", "越过 end 之后消失(不会一直挂着上一个词)")
	eq(s.text_at(1.50, &"words"), "世界", "下一个词")
	eq(s.text_at(2.40, &"words"), "世界", "第二个词的 end")
	eq(s.text_at(3.00, &"words"), "", "全部结束后是空的")

	eq(s.text_at(0.30, &"phones"), "n i3", "另一条轨独立查")
	eq(s.text_at(0.30, &"action"), "", "没有文本的轨返回空")
	eq(s.text_at(0.30, &"根本没这条轨"), "", "不存在的轨返回空而不是崩溃")

	# 没有 end 的标记会一直显示到下一个带文本的标记出现
	var s2 := CueSheet.new()
	var m1 := CueMarker.new(&"a", 0.0, &"t"); m1.payload = {"text": "一"}
	var m2 := CueMarker.new(&"b", 1.0, &"t"); m2.payload = {"text": "二"}
	s2.add_marker(m1); s2.add_marker(m2)
	eq(s2.text_at(0.5, &"t"), "一", "没有 end 时一直显示到下一条")
	eq(s2.text_at(99.0, &"t"), "二", "最后一条一直显示到结尾")


func _test_from_textgrid() -> void:
	print("\n[字幕] MFA TextGrid 导进来就能对照")
	var r := CueTextGridImporter.parse("res://tests/fixtures/sample_mfa.TextGrid")
	ok(r.ok(), "解析成功")
	var s := CueSheet.new()
	s.fps = 30
	for m in r.markers:
		s.add_marker(m)

	var tracks := s.text_tracks()
	ok(tracks.has(&"words") and tracks.has(&"phones"), "词级和音素级都成了文本轨:%s" % [tracks])
	eq(s.text_at(0.30, &"words"), "你好", "0.30s 的词")
	eq(s.text_at(0.80, &"words"), "", "词与词之间的静音处是空的")
	eq(s.text_at(1.50, &"words"), "世界", "第二个词")
	eq(s.text_at(0.30, &"phones"), "n i3", "同一时刻的音素")
	eq(s.text_at(0.50, &"phones"), "h ao3", "下一个音素")
