@tool
class_name CueWaveformView extends Control

## 波形 + 轨道泳道 + 播放头的绘制与交互。
##
## 布局:上方是每条轨道一条泳道(可折叠),下方是波形。
## 标记画在自己的泳道里,同时向下引一条淡淡的辅助线穿过波形,
## 方便把标记对到具体的音上。
##
## 泳道几何全部从 [CueViewState] 读,和左侧 [CueTrackHeaders] 共用一份数字。
##
## 性能纪律:[method _draw] 里不做逐采样循环,也不分配新数组。
## 每列的线段坐标预先算好存在 [member _wave_lines] 里,视图变化时才重建。

signal marker_add_requested(time: float)
signal marker_delete_requested(marker: CueMarker)
signal marker_move_requested(marker: CueMarker, from_time: float, to_time: float)
signal marker_rename_requested(marker: CueMarker)
signal marker_selected(marker: CueMarker)
signal seek_requested(time: float)
signal segment_selected(segment: CueAudioSegment)
signal segment_move_requested(segment: CueAudioSegment, from_offset: float, to_offset: float)

const MARKER_HIT_PX := 7.0
## 每条片段带顶部这么高的一条是"把手":在这里拖动整段音频,
## 在带内其他地方点击仍然是移动播放头。分开之后没有歧义。
const SEG_HANDLE_H := 13.0
const MARKER_LABEL_PAD := 5.0

var state: CueViewState = null

var _wave_lines: PackedVector2Array = PackedVector2Array()
var _lines_dirty: bool = true
var _selected: CueMarker = null
var _drag_marker: CueMarker = null
var _drag_from_time: float = 0.0
var _panning: bool = false
var _selected_seg: CueAudioSegment = null
var _drag_seg: CueAudioSegment = null
var _drag_seg_from: float = 0.0
var _drag_seg_grab_dt: float = 0.0
## 片段下标 → 已经算好的频谱贴图。由面板填,视图只负责画。
var _spectra: Dictionary = {}
var _spectra_pending: bool = false

# 主题色。全部取自编辑器主题,不硬编码(见 CLAUDE.md 编辑器插件纪律)。
var _c_bg: Color = Color(0.12, 0.12, 0.14)
var _c_lane: Color = Color(0.16, 0.16, 0.19)
var _c_lane_alt: Color = Color(0.18, 0.18, 0.21)
var _c_wave: Color = Color(0.45, 0.62, 0.85)
var _c_mid: Color = Color(1, 1, 1, 0.12)
var _c_marker: Color = Color(1.0, 0.75, 0.2)
var _c_selected: Color = Color(1.0, 0.95, 0.5)
var _c_playhead: Color = Color(1.0, 0.35, 0.35)
var _c_text: Color = Color(0.9, 0.9, 0.9)
var _font: Font = null
var _font_size: int = 12


func setup(p_state: CueViewState) -> void:
	state = p_state
	state.view_changed.connect(_on_view_changed)
	state.sheet_changed.connect(_on_view_changed)
	state.lanes_changed.connect(_on_view_changed)
	state.playhead_moved.connect(queue_redraw)


func _ready() -> void:
	focus_mode = Control.FOCUS_CLICK
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_pull_theme()
	resized.connect(_on_resized)


func _pull_theme() -> void:
	if not Engine.is_editor_hint():
		return
	var t := EditorInterface.get_editor_theme()
	if t == null:
		return
	_c_bg = t.get_color("dark_color_2", "Editor")
	_c_lane = t.get_color("dark_color_1", "Editor")
	_c_lane_alt = t.get_color("dark_color_3", "Editor")
	_c_wave = t.get_color("accent_color", "Editor")
	_c_text = t.get_color("font_color", "Editor")
	_c_mid = Color(_c_text, 0.12)
	_c_marker = t.get_color("warning_color", "Editor")
	_c_selected = t.get_color("property_color_z", "Editor")
	_c_playhead = t.get_color("error_color", "Editor")
	# 4.7.2 实测:编辑器主题里没有 ("font", "Editor"),
	# 正确的键是 ("main", "EditorFonts") / ("main_size", "EditorFonts")。
	_font = t.get_font("main", "EditorFonts")
	_font_size = t.get_font_size("main_size", "EditorFonts")


## 面板把算好的频谱贴图交进来。
func set_spectrogram(index: int, tex: ImageTexture) -> void:
	_spectra[index] = tex
	queue_redraw()


func clear_spectrograms() -> void:
	_spectra.clear()
	queue_redraw()


func set_spectrogram_pending(v: bool) -> void:
	_spectra_pending = v
	queue_redraw()


func selected_marker() -> CueMarker:
	return _selected


func selected_segment() -> CueAudioSegment:
	return _selected_seg


func select_segment(seg: CueAudioSegment) -> void:
	_selected_seg = seg
	segment_selected.emit(seg)
	queue_redraw()


func select(m: CueMarker) -> void:
	_selected = m
	marker_selected.emit(m)
	queue_redraw()


func _on_resized() -> void:
	if state != null:
		state.view_width = size.x
	_lines_dirty = true
	queue_redraw()


func _on_view_changed() -> void:
	_lines_dirty = true
	queue_redraw()


# ── 几何 ────────────────────────────────────────────────────────────

## 泳道区总高。超过控件一半就截断 —— 轨道很多时不能把波形挤没了。
func _lanes_h() -> float:
	if state == null:
		return 0.0
	return minf(state.lanes_height(), size.y * 0.6)


func _wave_top() -> float:
	return _lanes_h()


func _wave_height() -> float:
	return maxf(size.y - _wave_top(), 1.0)


func _wave_center_y() -> float:
	return _wave_top() + _wave_height() * 0.5


# ── 绘制 ────────────────────────────────────────────────────────────

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _c_bg)
	if state == null or state.sheet == null:
		_draw_hint("把一个 CueSheet 拖到这里,或在文件系统中双击 .tres 打开")
		return

	_draw_lane_bands()

	if _lines_dirty:
		_rebuild_lines()
	_draw_segments()

	_draw_markers()
	_draw_playhead()


## 泳道底色,深浅交替,方便一眼分清是哪一条。
func _draw_lane_bands() -> void:
	var names := state.track_list()
	var y := 0.0
	var limit := _lanes_h()
	for i in names.size():
		var h := state.lane_height(names[i])
		if y >= limit:
			break
		var hh: float = minf(h, limit - y)
		draw_rect(Rect2(0.0, y, size.x, hh), _c_lane_alt if i % 2 else _c_lane)
		y += h
	if limit > 0.0:
		draw_line(Vector2(0, limit), Vector2(size.x, limit), _c_mid, 1.0)


## 每段音频占波形区里的一条横带。多角色分轨时一眼看得出谁在什么时候说话。
func _segment_band(index: int, total: int) -> Rect2:
	var top := _wave_top()
	var h := _wave_height() / float(maxi(total, 1))
	return Rect2(0.0, top + h * float(index), size.x, h)


## 每个像素列一条竖线,坐标一次性算好。一列覆盖的 bucket 数随缩放变化:
## 拉远时一列聚合很多 bucket(取包络的并集),拉近时若干列共用一个 bucket。
##
## 多段时把所有段的线段拼进[b]同一个[/b]数组,一次 draw_multiline 画完 ——
## 每段各调一次会让分轨多的 sheet 出现明显的绘制开销。
func _rebuild_lines() -> void:
	_lines_dirty = false
	if state != null and state.spectrogram:
		_wave_lines = PackedVector2Array()
		return
	var pts := PackedVector2Array()
	_wave_lines = pts
	if state == null or state.sheet == null:
		return
	var w := int(size.x)
	if w <= 0:
		return
	var segs := state.sheet.all_segments()
	if segs.is_empty():
		return

	pts.resize(w * 2 * segs.size())
	var used := 0
	for si in segs.size():
		var seg := segs[si]
		if not seg.has_waveform():
			continue
		var wf := seg.waveform
		var spb := wf.seconds_per_bucket()
		if spb <= 0.0:
			continue
		var band := _segment_band(si, segs.size())
		var mid := band.position.y + band.size.y * 0.5
		var half := band.size.y * 0.5 - 2.0
		var n := wf.bucket_count()
		var mins := wf.mins
		var maxs := wf.maxs

		for x in w:
			# x 是 sheet 时间轴上的像素,要减掉片段偏移才是段内时间
			var t0 := state.x_to_time(float(x)) - seg.offset
			var t1 := state.x_to_time(float(x) + 1.0) - seg.offset
			if t1 < 0.0:
				continue
			var b0 := int(floor(t0 / spb))
			var b1 := int(ceil(t1 / spb))
			if b1 <= b0:
				b1 = b0 + 1
			b0 = maxi(b0, 0)
			b1 = mini(b1, n)
			if b0 >= n or b1 <= 0:
				continue
			var lo := 1.0
			var hi := -1.0
			for b in range(b0, b1):
				var mn: float = mins[b]
				var mx: float = maxs[b]
				if mn < lo: lo = mn
				if mx > hi: hi = mx
			if hi < lo:
				continue
			var fx := float(x) + 0.5
			pts[used] = Vector2(fx, mid - hi * half)
			pts[used + 1] = Vector2(fx, mid - lo * half)
			used += 2
	pts.resize(used)
	_wave_lines = pts


func _draw_segments() -> void:
	var segs := state.sheet.all_segments()
	if segs.is_empty():
		_draw_hint("这个 CueSheet 还没有音频片段 —— 在 Inspector 里往 segments 加一段")
		return

	var any_wave := false
	for si in segs.size():
		var seg := segs[si]
		var band := _segment_band(si, segs.size())
		var mid := band.position.y + band.size.y * 0.5
		# 段落之间画一条分隔线,并标出这段音频实际覆盖的时间范围
		if si > 0:
			draw_line(band.position, Vector2(size.x, band.position.y), _c_mid, 1.0)
		var x0 := state.time_to_x(seg.offset)
		var x1 := state.time_to_x(seg.end())
		if x1 > 0.0 and x0 < size.x:
			draw_rect(Rect2(maxf(x0, 0.0), band.position.y,
				minf(x1, size.x) - maxf(x0, 0.0), band.size.y),
				Color(_c_wave, 0.05))
		draw_line(Vector2(0, mid), Vector2(size.x, mid), _c_mid, 1.0)
		if state.spectrogram:
			var tex: ImageTexture = _spectra.get(si, null)
			if tex != null:
				# 只填这段音频实际覆盖的横向范围,空白处保持底色
				var sx0 := maxf(state.time_to_x(seg.offset), 0.0)
				var sx1 := minf(state.time_to_x(seg.end()), size.x)
				if sx1 > sx0:
					draw_texture_rect(tex,
						Rect2(sx0, band.position.y, sx1 - sx0, band.size.y), false)
			any_wave = true
		elif seg.has_waveform():
			any_wave = true
		_draw_segment_handle(seg, band, si)

	if state.spectrogram:
		if _spectra.is_empty() and not _spectra_pending:
			_draw_hint("频谱图需要读源音频 —— 确认片段的 path 指向存在的文件")
		elif _spectra_pending:
			_draw_hint("正在计算频谱图…")
		return
	if _wave_lines.size() >= 2:
		draw_multiline(_wave_lines, _c_wave, 1.0)
	elif not any_wave:
		_draw_hint("还没有波形缓存 —— 点工具栏的「分析波形」")


func _draw_markers() -> void:
	var sheet := state.sheet
	var names := state.track_list()
	var limit := _lanes_h()
	var bottom := size.y

	for i in names.size():
		var tname := names[i]
		var top := state.lane_top(i)
		if top >= limit:
			break
		var h := state.lane_height(tname)
		var collapsed := state.is_collapsed(tname)
		var base := sheet.track_color(tname, _c_marker)

		for m in sheet.in_track(tname):
			var x := state.time_to_x(m.time)
			if x < -120.0 or x > size.x + 120.0:
				continue
			var is_sel := m == _selected
			var col := _c_selected if is_sel else base

			# 向下的辅助线,穿过波形,用来把标记对到具体的音上
			draw_line(Vector2(x, top + h), Vector2(x, bottom),
				Color(col, 0.9 if is_sel else 0.35), 2.0 if is_sel else 1.0)

			if collapsed:
				# 折叠时只留一个细刻度,仍然看得出标记密度
				draw_rect(Rect2(x - 1.0, top + 1.0, 2.0, h - 2.0), col)
				continue

			# 带 end 的标记(词级切分、口型区间)画出它覆盖的跨度
			if state.show_text and m.payload.has("end"):
				var xe := state.time_to_x(float(m.payload["end"]))
				if xe > x:
					draw_rect(Rect2(x, top + 1.0, xe - x, h - 2.0), Color(col, 0.16))

			# 泳道里的抓取块
			draw_rect(Rect2(x - 1.0, top + 1.0, 2.0, h - 2.0), col)
			var tri := PackedVector2Array([
				Vector2(x - 5.0, top + 1.0),
				Vector2(x + 5.0, top + 1.0),
				Vector2(x, top + 9.0),
			])
			draw_colored_polygon(tri, col)
			# 有文本就显示文本 —— 对着波形核字幕时,名字(m_0007)远不如
			# 内容("你好")有用
			var label := String(m.name)
			if state.show_text and m.payload.has("text"):
				var txt := String(m.payload["text"]).strip_edges()
				if txt != "":
					label = txt
			if _font != null and label != "":
				draw_string(_font, Vector2(x + MARKER_LABEL_PAD, top + h - 5.0),
					label, HORIZONTAL_ALIGNMENT_LEFT, -1,
					maxi(_font_size - 1, 8), col)


## 片段把手:一条横带,显示标签,拖它可以整体挪动这段音频。
func _draw_segment_handle(seg: CueAudioSegment, band: Rect2, index: int) -> void:
	var x0: float = maxf(state.time_to_x(seg.offset), 0.0)
	var x1: float = minf(state.time_to_x(seg.end()), size.x)
	if x1 <= x0:
		return
	var sel := seg == _selected_seg
	var col := _c_selected if sel else _c_wave
	var h := minf(SEG_HANDLE_H, band.size.y * 0.5)
	draw_rect(Rect2(x0, band.position.y, x1 - x0, h), Color(col, 0.30 if sel else 0.14))
	draw_line(Vector2(x0, band.position.y), Vector2(x0, band.position.y + band.size.y),
		Color(col, 0.55), 2.0 if sel else 1.0)
	if _font == null:
		return
	var label := seg.label()
	if state.sheet.segment_count() > 1 or sel:
		label += "  +%.2fs" % seg.offset
	draw_string(_font, Vector2(x0 + 4.0, band.position.y + h - 3.0), label,
		HORIZONTAL_ALIGNMENT_LEFT, x1 - x0 - 8.0,
		maxi(_font_size - 2, 8), Color(_c_text, 0.85 if sel else 0.45))


## 命中片段把手。返回 null 表示没点在任何把手上。
func _segment_handle_at(pos: Vector2) -> CueAudioSegment:
	if pos.y < _lanes_h():
		return null
	var segs := state.sheet.all_segments()
	for si in segs.size():
		var band := _segment_band(si, segs.size())
		var h := minf(SEG_HANDLE_H, band.size.y * 0.5)
		if pos.y < band.position.y or pos.y > band.position.y + h:
			continue
		var seg := segs[si]
		var x0 := state.time_to_x(seg.offset)
		var x1 := state.time_to_x(seg.end())
		if pos.x >= x0 and pos.x <= x1:
			return seg
	return null


func _draw_playhead() -> void:
	var x := state.time_to_x(state.playhead)
	if x < -2.0 or x > size.x + 2.0:
		return
	draw_line(Vector2(x, 0), Vector2(x, size.y), _c_playhead, 1.0)


func _draw_hint(msg: String) -> void:
	if _font == null:
		return
	var w := _font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x
	draw_string(_font, Vector2((size.x - w) * 0.5, size.y * 0.5),
		msg, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, Color(_c_text, 0.5))


# ── 交互 ────────────────────────────────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if state == null or state.sheet == null:
		return

	if event is InputEventMouseButton:
		_handle_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_motion(event as InputEventMouseMotion)
	elif event is InputEventKey and (event as InputEventKey).pressed:
		_handle_key(event as InputEventKey)


func _handle_button(e: InputEventMouseButton) -> void:
	match e.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if e.pressed:
				state.zoom_at(1.15 if not e.ctrl_pressed else 1.4, e.position.x)
				accept_event()
		MOUSE_BUTTON_WHEEL_DOWN:
			if e.pressed:
				state.zoom_at(1.0 / (1.15 if not e.ctrl_pressed else 1.4), e.position.x)
				accept_event()
		MOUSE_BUTTON_MIDDLE:
			_panning = e.pressed
			accept_event()
		MOUSE_BUTTON_LEFT:
			if e.pressed:
				_press(e)
			else:
				_release()
			accept_event()


## 泳道区里点 = 操作标记;波形区里点 = 移动播放头。
## 分开之后就没有"到底是想选标记还是想定位"的歧义了。
func _press(e: InputEventMouseButton) -> void:
	grab_focus()
	if e.position.y >= _lanes_h():
		# 先看是不是点在片段把手上 —— 是的话进入拖动片段,而不是移动播放头
		var seg := _segment_handle_at(e.position)
		if seg != null:
			select(null)
			select_segment(seg)
			_drag_seg = seg
			_drag_seg_from = seg.offset
			_drag_seg_grab_dt = state.x_to_time(e.position.x) - seg.offset
			return
		select(null)
		select_segment(null)
		seek_requested.emit(state.maybe_snap(state.x_to_time(e.position.x)))
		return

	var lane := state.lane_at(e.position.y)
	if lane != &"":
		state.set_active_track(lane)
	var hit := _marker_at(e.position)
	if hit == null:
		select(null)
		seek_requested.emit(state.maybe_snap(state.x_to_time(e.position.x)))
		return
	select(hit)
	if e.double_click:
		marker_rename_requested.emit(hit)
	else:
		_drag_marker = hit
		_drag_from_time = hit.time


func _release() -> void:
	if _drag_seg != null:
		var to_off := _drag_seg.offset
		# 和标记拖动同样的手法:先还原,再让 undo 系统设回去,
		# 撤销栈里存的是一次完整的移动
		if not is_equal_approx(to_off, _drag_seg_from):
			_drag_seg.offset = _drag_seg_from
			segment_move_requested.emit(_drag_seg, _drag_seg_from, to_off)
		_drag_seg = null
		return
	if _drag_marker == null:
		return
	var to_t := _drag_marker.time
	# 拖动过程中直接改了 time,这里先还原,再让 undo 系统把它设回去,
	# 这样撤销栈里存的是一次完整的移动,而不是几十次微调。
	if not is_equal_approx(to_t, _drag_from_time):
		_drag_marker.time = _drag_from_time
		marker_move_requested.emit(_drag_marker, _drag_from_time, to_t)
	_drag_marker = null


func _handle_motion(e: InputEventMouseMotion) -> void:
	if _panning or (e.button_mask & MOUSE_BUTTON_MASK_MIDDLE) != 0:
		state.pan_pixels(e.relative.x)
		accept_event()
		return
	if _drag_seg != null:
		var off: float = maxf(state.x_to_time(e.position.x) - _drag_seg_grab_dt, 0.0)
		if e.ctrl_pressed or state.snap_to_frame:
			off = state.sheet.snap(off)
		_drag_seg.offset = off
		state.notify_sheet_edited()
		_lines_dirty = true
		queue_redraw()
		accept_event()
		return
	if _drag_marker != null:
		# 拖动只改时间,不换轨 —— 换轨是另一回事,不该靠手抖触发
		var t: float = clampf(state.x_to_time(e.position.x), 0.0, maxf(state.duration(), 0.0))
		if e.ctrl_pressed or state.snap_to_frame:
			t = state.sheet.snap(t)
		_drag_marker.time = t
		state.notify_sheet_edited()
		queue_redraw()
		accept_event()


func _handle_key(e: InputEventKey) -> void:
	match e.keycode:
		KEY_M:
			marker_add_requested.emit(state.maybe_snap(state.playhead))
			accept_event()
		KEY_DELETE, KEY_BACKSPACE:
			if _selected != null:
				marker_delete_requested.emit(_selected)
				accept_event()
		KEY_F2:
			if _selected != null:
				marker_rename_requested.emit(_selected)
				accept_event()


## 只在鼠标所在的那条泳道里找 —— 不同轨上时间相近的标记
## (口型轨尤其密)才不会互相抢点击。
func _marker_at(pos: Vector2) -> CueMarker:
	var lane := state.lane_at(pos.y)
	if lane == &"":
		return null
	var best: CueMarker = null
	var best_d := MARKER_HIT_PX
	for m in state.sheet.in_track(lane):
		var d: float = absf(state.time_to_x(m.time) - pos.x)
		if d <= best_d:
			best_d = d
			best = m
	return best
