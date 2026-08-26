@tool
class_name CueAnalysisJobs extends RefCounted

## 两类耗时作业:波形/包络分析,以及按需的频谱图。
##
## 从面板里拆出来的理由:这两件事都是"长任务 + 进度 + 可作废",
## 和面板的布局/播放/对话框没有共同点,挤在一起只会让两边都难读。

signal progress(ratio: float)
## 一段频谱图算好了。[param index] 与 [method CueSheet.all_segments] 对齐。
signal spectrogram_ready(index: int, texture: ImageTexture)
signal spectrogram_busy(busy: bool)

var _state: CueViewState = null
var analyzing: bool = false

## 频谱图需要原始 PCM(峰值缓存里没有相位信息),重读文件很贵,按路径缓存。
var _pcm_cache: Dictionary = {}
## 作业序号。视图一变就 +1,旧作业算到一半发现序号变了就自己作废。
var _spec_job: int = 0


func _init(state: CueViewState) -> void:
	_state = state


## 换 sheet 时调用:丢掉 PCM 缓存,作废在跑的频谱作业。
func reset() -> void:
	_pcm_cache.clear()
	_spec_job += 1


# ── 波形与包络 ──────────────────────────────────────────────────────

## 分析全部片段。[param force] 为 false 时**只重算需要重算的** ——
## 改一个角色的配音不该把整集其他角色的波形也重扫一遍
## (这是 D10′ 保留"局部重渲"诉求的落点)。
func analyze(sheet: CueSheet, force: bool = false) -> bool:
	if sheet == null or analyzing:
		return false
	sheet.migrate_legacy()          # 旧的单音频 sheet 就地升级
	var segs := sheet.all_segments()
	if segs.is_empty():
		push_error("Cue:这个 CueSheet 还没有音频片段。请用工具栏的「音频 → 添加音频片段」。")
		return false

	analyzing = true
	var builder := CueWaveformBuilder.new()
	var done := 0
	var failed := PackedStringArray()

	for seg in segs:
		if not force and seg.has_waveform() and not seg.waveform_stale():
			done += 1
			progress.emit(float(done) / float(segs.size()))
			continue
		var src := CuePcmReader.open(seg.path, seg.stream)
		if not src.ok():
			failed.append(src.error)
			done += 1
			continue
		# 多段时进度条要横跨所有段,不能每段都从 0 走一遍
		var base := float(done) / float(segs.size())
		var span := 1.0 / float(segs.size())
		var cb := func(r: float) -> void: progress.emit(base + r * span)
		builder.progress.connect(cb)
		var cache: WaveformCache = await builder.build_async(src)
		builder.progress.disconnect(cb)
		cache.source_hash = WaveformCache.compute_hash(seg.path)
		if _state.sheet != sheet:
			analyzing = false        # 分析期间用户换了 sheet
			return false
		seg.waveform = cache
		done += 1

	analyzing = false
	progress.emit(1.0)
	for e in failed:
		push_error(e)

	sheet.envelope = CueEnvelopeBuilder.from_sheet(sheet)
	return true


# ── 频谱图 ──────────────────────────────────────────────────────────

func cancel_spectrogram() -> void:
	_spec_job += 1
	spectrogram_busy.emit(false)


## 算当前视野里每一段的频谱图。[param view_width] 是波形控件的像素宽。
func run_spectrogram(view_width: float, low: Color, mid: Color, high: Color) -> void:
	if not _state.spectrogram or _state.sheet == null:
		return
	var segs := _state.sheet.all_segments()
	if segs.is_empty():
		return

	_spec_job += 1
	var job := _spec_job
	spectrogram_busy.emit(true)
	var cols: int = clampi(int(view_width * 0.5), 32, 480)

	for si in segs.size():
		if job != _spec_job:
			return                            # 期间视图又变了,这次作废
		var seg := segs[si]
		var src := _pcm_for(seg)
		if src == null or not src.ok():
			continue
		# 只算这段音频在当前视野里露出来的那部分
		var t0: float = maxf(_state.scroll_sec - seg.offset, 0.0)
		var t1: float = minf(_state.x_to_time(view_width) - seg.offset, seg.length())
		if t1 <= t0:
			continue
		var spec := CueSpectrogram.new()
		var img: Image = await spec.build_async(src, t0, t1, cols)
		if job != _spec_job:
			return
		if img != null:
			spectrogram_ready.emit(si, CueSpectrogram.colorize(img, low, mid, high))

	if job == _spec_job:
		spectrogram_busy.emit(false)


func _pcm_for(seg: CueAudioSegment) -> CuePcmReader.Source:
	var key := seg.path if seg.path != "" else str(seg.get_instance_id())
	if _pcm_cache.has(key):
		return _pcm_cache[key]
	var src := CuePcmReader.open(seg.path, seg.stream)
	if not src.ok():
		push_error(src.error)
		_pcm_cache[key] = null
		return null
	_pcm_cache[key] = src
	return src
