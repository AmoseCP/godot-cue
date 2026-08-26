@tool
class_name CueWaveformGeometry

## 波形视图的几何:泳道区/片段带/把手的矩形,以及命中测试。
##
## 抽成[b]纯函数[/b]的理由不是"文件太长",而是这部分[b]完全没有测试覆盖[/b] ——
## 它藏在一个 Control 里,要验就得起编辑器。而它偏偏是最容易出错的一类代码:
## 一堆 y 坐标的加减,错一像素就变成"点第 1 条却选中了第 2 条"。
## 而且 [CueTrackHeaders] 必须和它严格对齐,两边各算一遍必然错位。
##
## 所有函数都只依赖 [CueViewState] 和控件尺寸,不碰任何绘制状态。

## 每条片段带顶部这么高的一条是"把手":在这里拖动整段音频,
## 在带内其他地方点击仍然是移动播放头。
const SEG_HANDLE_H := 13.0
## 标记的横向命中半径(像素)。
const MARKER_HIT_PX := 7.0
## 泳道区最多占控件高度的多少 —— 轨道很多时不能把波形挤没了。
const LANES_MAX_RATIO := 0.6


## 泳道区总高(已按 [constant LANES_MAX_RATIO] 截断)。
static func lanes_height(state: CueViewState, size: Vector2) -> float:
	if state == null:
		return 0.0
	return minf(state.lanes_height(), size.y * LANES_MAX_RATIO)


## 波形区顶部 y。
static func wave_top(state: CueViewState, size: Vector2) -> float:
	return lanes_height(state, size)


static func wave_height(state: CueViewState, size: Vector2) -> float:
	return maxf(size.y - wave_top(state, size), 1.0)


## 第 [param index] 段音频占的横带([param total] 段平分波形区)。
static func segment_band(state: CueViewState, size: Vector2,
		index: int, total: int) -> Rect2:
	var top := wave_top(state, size)
	var h := wave_height(state, size) / float(maxi(total, 1))
	return Rect2(0.0, top + h * float(index), size.x, h)


## 片段把手的高度。带子很矮时不能让把手占满整条。
static func handle_height(band: Rect2) -> float:
	return minf(SEG_HANDLE_H, band.size.y * 0.5)


## 落在 [param pos] 上的片段把手;没有返回 null。
static func segment_handle_at(state: CueViewState, size: Vector2,
		pos: Vector2) -> CueAudioSegment:
	if state == null or state.sheet == null:
		return null
	if pos.y < wave_top(state, size):
		return null
	var segs := state.sheet.all_segments()
	for si in segs.size():
		var band := segment_band(state, size, si, segs.size())
		var h := handle_height(band)
		if pos.y < band.position.y or pos.y > band.position.y + h:
			continue
		var seg := segs[si]
		var x0 := state.time_to_x(seg.offset)
		var x1 := state.time_to_x(seg.end())
		if pos.x >= x0 and pos.x <= x1:
			return seg
	return null


## 落在 [param pos] 上的标记。
##
## [b]只在鼠标所在的那条泳道里找[/b] —— 不同轨上时间相近的标记
## (口型轨尤其密)才不会互相抢点击。
static func marker_at(state: CueViewState, pos: Vector2) -> CueMarker:
	if state == null or state.sheet == null:
		return null
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


## [param pos] 是否落在波形区(而不是泳道区)。
## 波形区里点击 = 移动播放头,泳道区里点击 = 操作标记。
static func in_wave_area(state: CueViewState, size: Vector2, pos: Vector2) -> bool:
	return pos.y >= wave_top(state, size)
