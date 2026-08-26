extends SceneTree

## 多音频片段(D10′)的测试。
##   godot --headless --path . --script tests/test_segments.gd

var _pass := 0
var _fail := 0


func _init() -> void:
	_test_segment_basics()
	_test_all_segments_and_legacy()
	_test_migrate_legacy()
	_test_duration_and_lookup()
	_test_overlap_and_gap()
	_test_mutations()
	_test_validate()
	_test_sort_cache_invalidation()
	_test_navigation()
	print("\n=== %d 通过 / %d 失败 ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func ok(c: bool, w: String) -> void:
	if c: _pass += 1; print("  PASS  ", w)
	else: _fail += 1; print("  FAIL  ", w)

func eq(a: Variant, b: Variant, w: String) -> void:
	ok(a == b, "%s (得到 %s,期望 %s)" % [w, a, b])

func near(a: float, b: float, w: String) -> void:
	ok(absf(a - b) < 1e-5, "%s (得到 %.4f,期望 %.4f)" % [w, a, b])


## 造一段带已知时长的片段(靠合成 waveform 给出 duration)。
func _seg(name: StringName, offset: float, length: float) -> CueAudioSegment:
	var s := CueAudioSegment.new(name, "res://fake/%s.wav" % name, offset)
	var w := WaveformCache.new()
	w.mins = PackedFloat32Array([-0.5])
	w.maxs = PackedFloat32Array([0.5])
	w.mix_rate = 44100
	w.duration = length
	s.waveform = w
	return s


func _test_segment_basics() -> void:
	print("\n[片段] 基本几何")
	var s := _seg(&"peter", 2.0, 3.0)
	near(s.length(), 3.0, "自身长度")
	near(s.end(), 5.0, "结束时刻 = offset + 长度")
	ok(s.covers(2.0), "起点算覆盖")
	ok(s.covers(4.999), "结束前一刻算覆盖")
	ok(not s.covers(5.0), "结束时刻不算覆盖(左闭右开)")
	ok(not s.covers(1.999), "起点之前不算覆盖")
	near(s.local_time(3.5), 1.5, "sheet 时间 → 段内时间")
	eq(s.label(), "peter", "有名字就用名字")

	var anon := CueAudioSegment.new(&"", "res://a/voice_b.wav", 0.0)
	eq(anon.label(), "voice_b.wav", "没名字就用文件名")
	eq(CueAudioSegment.new().label(), "(未命名片段)", "都没有时的兜底")

	# offset 不能是负的
	var neg := CueAudioSegment.new(&"x", "", -3.0)
	near(neg.offset, 0.0, "负 offset 被夹到 0")

	ok(s.has_waveform(), "有波形")
	ok(not CueAudioSegment.new().has_waveform(), "没波形")


func _test_all_segments_and_legacy() -> void:
	print("\n[片段] all_segments() 与兼容字段")
	var sheet := CueSheet.new()
	eq(sheet.all_segments().size(), 0, "空 sheet 没有片段")

	# 旧的单音频写法:只设 audio_path + waveform
	sheet.audio_path = "res://old/voice.wav"
	var w := WaveformCache.new()
	w.mins = PackedFloat32Array([-1.0]); w.maxs = PackedFloat32Array([1.0])
	w.mix_rate = 44100; w.duration = 4.0
	sheet.waveform = w
	var synth := sheet.all_segments()
	eq(synth.size(), 1, "兼容字段合成出一个片段")
	eq(synth[0].path, "res://old/voice.wav", "路径来自 audio_path")
	near(synth[0].offset, 0.0, "合成片段的 offset 是 0")
	near(sheet.duration(), 4.0, "duration 仍然正确")
	ok(sheet.all_segments() == synth, "重复调用返回同一份缓存,不反复新建")

	# 一旦有了 segments,兼容字段就不再参与
	sheet.segments = [_seg(&"new", 0.0, 9.0)] as Array[CueAudioSegment]
	eq(sheet.all_segments().size(), 1, "改用 segments")
	eq(sheet.all_segments()[0].path, "res://fake/new.wav", "返回的是 segments 里的")
	near(sheet.duration(), 9.0, "duration 跟着 segments 走")

	# 只有 waveform 没有音频也要能给出时长(window() 这类纯时间轴查询依赖它)
	var only_wave := CueSheet.new()
	only_wave.waveform = w
	near(only_wave.duration(), 4.0, "只有 waveform 时 duration 仍可用")


func _test_migrate_legacy() -> void:
	print("\n[片段] 兼容字段就地升级")
	var sheet := CueSheet.new()
	sheet.audio_path = "res://old/voice.wav"
	var w := WaveformCache.new()
	w.mins = PackedFloat32Array([-1.0]); w.maxs = PackedFloat32Array([1.0])
	w.mix_rate = 44100; w.duration = 4.0
	sheet.waveform = w

	ok(sheet.migrate_legacy(), "升级成功")
	eq(sheet.segments.size(), 1, "产生了一个片段")
	eq(sheet.segments[0].path, "res://old/voice.wav", "路径搬过去了")
	ok(sheet.segments[0].waveform == w, "波形缓存搬过去了(不重算)")
	eq(sheet.audio_path, "", "旧字段被清空")
	ok(sheet.waveform == null, "旧波形字段被清空")
	near(sheet.duration(), 4.0, "升级前后时长不变")

	ok(not sheet.migrate_legacy(), "已经是 segments 形式时是空操作")
	ok(not CueSheet.new().migrate_legacy(), "什么都没有时不产生空片段")


func _test_duration_and_lookup() -> void:
	print("\n[片段] 时长与查找")
	var sheet := CueSheet.new()
	sheet.segments = [
		_seg(&"peter", 0.0, 2.0),
		_seg(&"john", 3.0, 2.5),
		_seg(&"mary", 1.0, 1.0),
	] as Array[CueAudioSegment]

	near(sheet.duration(), 5.5, "时长 = 最靠后片段的结束时刻(3.0+2.5)")
	eq(sheet.segment_count(), 3, "片段数")
	eq(String(sheet.segment_at(0.5).name), "peter", "查 0.5s")
	eq(String(sheet.segment_at(3.5).name), "john", "查 3.5s")
	ok(sheet.segment_at(2.5) == null, "空隙里查不到片段")
	ok(sheet.segment_at(99.0) == null, "超出末尾查不到")

	# 数组顺序不必按 offset 排,duration 也要对
	sheet.segments = [_seg(&"late", 10.0, 1.0), _seg(&"early", 0.0, 1.0)] as Array[CueAudioSegment]
	near(sheet.duration(), 11.0, "乱序时 duration 仍取最大值")


func _test_overlap_and_gap() -> void:
	print("\n[片段] 重叠与空隙")
	var sheet := CueSheet.new()
	# 两个角色同时说话(重叠),中间还有一段谁都不说
	sheet.segments = [
		_seg(&"a", 0.0, 3.0),
		_seg(&"b", 2.0, 3.0),      # 与 a 重叠 1 秒
		_seg(&"c", 7.0, 1.0),      # 与 b 之间空 2 秒
	] as Array[CueAudioSegment]

	near(sheet.duration(), 8.0, "总时长")
	eq(String(sheet.segment_at(2.5).name), "a", "重叠处返回第一个匹配的片段")
	ok(sheet.segment_at(6.0) == null, "空隙里没有片段")
	eq(String(sheet.segment_at(7.5).name), "c", "空隙之后的片段照常查到")

	# 重叠区确实被两段同时覆盖
	var covering := 0
	for s in sheet.all_segments():
		if s.covers(2.5):
			covering += 1
	eq(covering, 2, "2.5s 被两段同时覆盖")


func _test_mutations() -> void:
	print("\n[片段] 增删改(undo 用的那几个)")
	var sheet := CueSheet.new()
	var a := _seg(&"a", 0.0, 1.0)
	var b := _seg(&"b", 2.0, 1.0)
	sheet.add_segment(a)
	sheet.add_segment(b)
	eq(sheet.segments.size(), 2, "加了两段")
	eq(sheet.index_of_segment(b), 1, "index_of_segment")

	sheet.remove_segment(a)
	eq(sheet.segments.size(), 1, "删掉一段")
	near(sheet.duration(), 3.0, "删除后时长重算")

	sheet.insert_segment(a, 0)
	eq(sheet.index_of_segment(a), 0, "按下标插回去(undo 要精确还原顺序)")

	sheet.set_segment_offset(b, 5.0)
	near(b.offset, 5.0, "改 offset")
	near(sheet.duration(), 6.0, "改 offset 后时长跟着变")

	# touch() 必须让 duration 的片段缓存失效
	sheet.audio_path = "res://x.wav"
	sheet.touch()
	eq(sheet.all_segments().size(), 2, "有 segments 时兼容字段不参与")


func _test_validate() -> void:
	print("\n[片段] 校验")
	var sheet := CueSheet.new()
	sheet.segments = [_seg(&"ok", 0.0, 1.0)] as Array[CueAudioSegment]
	sheet.add_marker(CueMarker.new(&"m", 0.5))
	ok(sheet.validate().is_empty(), "健康数据无告警")

	sheet.segments.append(CueAudioSegment.new(&"broken", "", 0.0))
	sheet.touch()
	var issues := sheet.validate()
	ok(issues.size() == 1 and issues[0].contains("broken"),
		"既没 path 也没 stream 的片段被检出:%s" % issues)

func _test_sort_cache_invalidation() -> void:
	print("\n[缓存] 直接改标记属性后,排序缓存必须失效")
	# 编辑器走的是 CueSheet.set_marker_time(),会 touch()。
	# 但用户脚本完全可能直接写 sheet.find(&"x").time = 5.0 ——
	# 那时 CueSheet 不知道自己脏了,sorted() 会返回陈旧顺序,
	# Cue 的触发队列跟着错序。
	var sheet := CueSheet.new()
	sheet.fps = 30
	sheet.add_marker(CueMarker.new(&"a", 1.0))
	sheet.add_marker(CueMarker.new(&"b", 2.0))
	sheet.add_marker(CueMarker.new(&"c", 3.0))
	eq(_names(sheet), ["a", "b", "c"], "初始顺序")

	# 不经过任何 sheet 方法,直接改标记
	sheet.find(&"c").time = 0.5
	eq(_names(sheet), ["c", "a", "b"], "直接改 time 之后 sorted() 立刻反映新顺序")

	# 改名也影响排序(同时间按名字做全序)
	var m := CueSheet.new()
	m.add_marker(CueMarker.new(&"z", 1.0))
	m.add_marker(CueMarker.new(&"y", 1.0))
	eq(_names(m), ["y", "z"], "同时间按名字排")
	m.find(&"z").name = &"a"
	eq(_names(m), ["a", "y"], "直接改名之后重新排序")

	# 改轨道要让 in_track 立刻反映
	var t := CueSheet.new()
	t.add_marker(CueMarker.new(&"p", 1.0, &"one"))
	eq(t.in_track(&"one").size(), 1, "初始在 one 轨")
	t.find(&"p").track = &"two"
	eq(t.in_track(&"one").size(), 0, "直接改轨道后 one 轨空了")
	eq(t.in_track(&"two").size(), 1, "出现在 two 轨")

	# 整批替换 markers 数组之后同样要生效
	var b := CueSheet.new()
	b.add_marker(CueMarker.new(&"old", 1.0))
	var fresh: Array[CueMarker] = [CueMarker.new(&"n2", 2.0), CueMarker.new(&"n1", 1.0)]
	b.markers = fresh
	eq(_names(b), ["n1", "n2"], "整批替换后按新数据排序")
	b.find(&"n2").time = 0.5
	eq(_names(b), ["n2", "n1"], "替换进来的标记也被盯着")


func _names(sheet: CueSheet) -> Array:
	var out: Array = []
	for m in sheet.sorted():
		out.append(String(m.name))
	return out

func _test_navigation() -> void:
	print("\n[导航] next / prev / search")
	var sheet := CueSheet.new()
	sheet.fps = 30
	sheet.add_marker(CueMarker.new(&"peter_line_1", 1.0, &"dialogue"))
	sheet.add_marker(CueMarker.new(&"m_0001", 1.2, &"mouth"))
	sheet.add_marker(CueMarker.new(&"john_line_1", 2.0, &"dialogue"))
	sheet.add_marker(CueMarker.new(&"m_0002", 2.4, &"mouth"))
	sheet.add_marker(CueMarker.new(&"peter_line_2", 3.0, &"dialogue"))
	var withtext := CueMarker.new(&"w_0007", 3.5, &"words")
	withtext.payload = {"text": "你好世界"}
	sheet.add_marker(withtext)

	# next:严格大于,否则站在标记上按「下一个」会原地不动
	eq(String(sheet.next_marker(0.0).name), "peter_line_1", "开头之后的第一个")
	eq(String(sheet.next_marker(1.0).name), "m_0001", "正好站在标记上时跳到下一个,不原地不动")
	eq(String(sheet.next_marker(1.1).name), "m_0001", "两个标记之间")
	ok(sheet.next_marker(99.0) == null, "末尾之后没有下一个")

	# prev:严格小于
	ok(sheet.prev_marker(0.0) == null, "开头之前没有上一个")
	ok(sheet.prev_marker(1.0) == null, "正好站在第一个标记上时没有上一个")
	eq(String(sheet.prev_marker(2.5).name), "m_0002", "2.5s 之前的最后一个")
	eq(String(sheet.prev_marker(99.0).name), "w_0007", "末尾之后的上一个是最后那个")

	# 限定轨道 —— 口型轨几千个标记时,按对白轨跳才有意义
	eq(String(sheet.next_marker(1.0, &"dialogue").name), "john_line_1",
		"限定 dialogue 轨时跳过中间的口型标记")
	eq(String(sheet.prev_marker(2.5, &"dialogue").name), "john_line_1",
		"限定轨道的 prev")
	ok(sheet.next_marker(1.0, &"根本没这条轨") == null, "不存在的轨返回 null")

	# search
	eq(sheet.search("peter").size(), 2, "按名字搜到两个 peter")
	eq(String(sheet.search("peter")[0].name), "peter_line_1", "搜索结果按时间排序")
	eq(sheet.search("PETER").size(), 2, "不区分大小写")
	eq(sheet.search("").size(), sheet.markers.size(), "空查询返回全部")
	eq(sheet.search("你好").size(), 1, "payload.text 也参与匹配")
	eq(String(sheet.search("你好")[0].name), "w_0007", "按内容找到了那条")
	eq(sheet.search("m_", &"mouth").size(), 2, "可以限定轨道")
	eq(sheet.search("不存在的东西").size(), 0, "搜不到就是空")

	# 空 sheet 不能崩
	var empty := CueSheet.new()
	ok(empty.next_marker(0.0) == null, "空 sheet 的 next")
	ok(empty.prev_marker(0.0) == null, "空 sheet 的 prev")
	eq(empty.search("x").size(), 0, "空 sheet 的 search")
