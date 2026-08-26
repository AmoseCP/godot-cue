@tool
class_name CueViewState extends RefCounted

## 波形视图、标尺、传输条共用的一份视图状态。
## 单独抽出来是为了避免三个控件各存一份缩放/滚动值然后互相不同步。

signal view_changed()          ## 缩放或滚动变了
signal sheet_changed()         ## 换了 sheet,或 sheet 内容被编辑
signal playhead_moved()
signal lanes_changed()         ## 轨道折叠状态或活动轨道变了

const MIN_PX_PER_SEC := 2.0
const MAX_PX_PER_SEC := 24000.0

## 展开时一条轨道泳道的高度。
const LANE_H := 22.0
## 折叠时的高度 —— 仍然留一条能看见标记密度的细带,而不是完全消失。
const LANE_H_COLLAPSED := 9.0

var sheet: CueSheet = null
var px_per_sec: float = 100.0
## 视图左边缘对应的时间(秒)。
var scroll_sec: float = 0.0
var playhead: float = 0.0
var snap_to_frame: bool = false
## 泳道里画 payload.text 而不是标记名,并显示文本覆盖的时间跨度。
var show_text: bool = true
## 波形区画频谱图而不是波形。
var spectrogram: bool = false
var view_width: float = 1000.0
## 按 M 加标记时落在哪条轨上。
var active_track: StringName = &"dialogue"

## 轨道名 → 是否折叠。刻意[b]不[/b]存进资源:折叠是视图状态,
## 写进 .tres 会让一次 UI 折叠产生 git diff,还得为它走 undo。
var _collapsed: Dictionary = {}


func set_sheet(s: CueSheet) -> void:
	sheet = s
	scroll_sec = 0.0
	playhead = 0.0
	sheet_changed.emit()
	view_changed.emit()


func notify_sheet_edited() -> void:
	if sheet != null:
		sheet.invalidate()
	sheet_changed.emit()


func duration() -> float:
	return sheet.duration() if sheet != null else 0.0


# ── 轨道泳道 ────────────────────────────────────────────────────────
# 泳道几何放在这里,是为了让轨道头和波形视图读的是[b]同一份[/b]数字。
# 两边各算一遍必然会错位。

func track_list() -> Array[StringName]:
	if sheet == null:
		return []
	return sheet.track_names()


func is_collapsed(track_name: StringName) -> bool:
	return _collapsed.get(track_name, false)


func set_collapsed(track_name: StringName, v: bool) -> void:
	if is_collapsed(track_name) == v:
		return
	_collapsed[track_name] = v
	lanes_changed.emit()


func toggle_collapsed(track_name: StringName) -> void:
	set_collapsed(track_name, not is_collapsed(track_name))


func set_all_collapsed(v: bool) -> void:
	for n in track_list():
		_collapsed[n] = v
	lanes_changed.emit()


func set_active_track(track_name: StringName) -> void:
	if active_track == track_name:
		return
	active_track = track_name
	lanes_changed.emit()


func lane_height(track_name: StringName) -> float:
	return LANE_H_COLLAPSED if is_collapsed(track_name) else LANE_H


## 第 [param index] 条泳道的顶部 y(相对泳道区起点)。
func lane_top(index: int) -> float:
	var y := 0.0
	var names := track_list()
	for i in mini(index, names.size()):
		y += lane_height(names[i])
	return y


func lanes_height() -> float:
	var y := 0.0
	for n in track_list():
		y += lane_height(n)
	return y


## 落在 [param y](相对泳道区起点)上的轨道名;不在任何泳道内返回空。
func lane_at(y: float) -> StringName:
	var acc := 0.0
	for n in track_list():
		var h := lane_height(n)
		if y >= acc and y < acc + h:
			return n
		acc += h
	return &""


func time_to_x(t: float) -> float:
	return (t - scroll_sec) * px_per_sec


func x_to_time(x: float) -> float:
	return scroll_sec + x / px_per_sec


func visible_seconds() -> float:
	return view_width / px_per_sec


## 以 [param anchor_x] 处的时间为锚点缩放,鼠标底下的那一点不会跑掉。
func zoom_at(factor: float, anchor_x: float) -> void:
	var t := x_to_time(anchor_x)
	var target: float = clampf(px_per_sec * factor, MIN_PX_PER_SEC, MAX_PX_PER_SEC)
	if is_equal_approx(target, px_per_sec):
		return
	px_per_sec = target
	scroll_sec = t - anchor_x / px_per_sec
	_clamp_scroll()
	view_changed.emit()


func zoom_fit() -> void:
	var d := duration()
	if d <= 0.0 or view_width <= 0.0:
		return
	px_per_sec = clampf(view_width / d, MIN_PX_PER_SEC, MAX_PX_PER_SEC)
	scroll_sec = 0.0
	view_changed.emit()


func pan_pixels(dx: float) -> void:
	scroll_sec -= dx / px_per_sec
	_clamp_scroll()
	view_changed.emit()


func scroll_to(t: float) -> void:
	scroll_sec = t
	_clamp_scroll()
	view_changed.emit()


## 播放头跑出视野时把视图推过去。留 10% 余量,免得播放头贴着边缘抖。
func follow_playhead() -> void:
	var vis := visible_seconds()
	var margin := vis * 0.1
	if playhead < scroll_sec + margin or playhead > scroll_sec + vis - margin:
		scroll_sec = playhead - vis * 0.5
		_clamp_scroll()
		view_changed.emit()


func set_playhead(t: float) -> void:
	playhead = clampf(t, 0.0, maxf(duration(), 0.0))
	playhead_moved.emit()


func maybe_snap(t: float) -> float:
	if snap_to_frame and sheet != null:
		return sheet.snap(t)
	return t


func _clamp_scroll() -> void:
	var d := duration()
	var vis := visible_seconds()
	if d <= 0.0:
		scroll_sec = 0.0
		return
	scroll_sec = clampf(scroll_sec, 0.0, maxf(d - vis * 0.5, 0.0))
