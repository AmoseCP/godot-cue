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
