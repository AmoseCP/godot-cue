@tool
class_name CueClock extends RefCounted

## 双模时间源(PLAN D4)—— 整个插件正确性的核心。
##
## [b]实时预览[/b]:以音频播放位置为准,并补偿混音缓冲与输出延迟。
## 画面必须跟着声音走,因为人耳对不同步极其敏感。
##
## [b]Movie Maker 离线渲染[/b]:时间[i]完全[/i]由已绘制帧数决定。
## 离线渲染时音频线程与固定帧步是解耦的,若仍用播放位置驱动动画,
## 同一个场景每次渲染出的视频都会略有不同,"渲染是纯函数" 就不成立了。
## M4 的双次渲染哈希比对就是在测这一条。

## 允许测试强制指定模式:-1 = 自动检测,0 = 强制实时,1 = 强制离线。
static var force_mode: int = -1

## 某些平台上 [method AudioServer.get_output_latency] 返回 0
## (4.7.2 实测:macOS headless + Dummy 驱动下为 0)。
## 这里留一个手动偏移,单位秒,正值表示画面再提前一点。
static var extra_latency: float = 0.0

var fps: float = 30.0
var player: AudioStreamPlayer = null

var _movie: bool = false
var _start_frame: int = 0
var _start_offset: float = 0.0
var _running: bool = false
var _frozen: float = 0.0


func _init(p_fps: float = 30.0, p_player: AudioStreamPlayer = null) -> void:
	fps = maxf(p_fps, 1.0)
	player = p_player
	_movie = detect_movie_mode()


## Movie Maker 模式检测。
##
## 4.7.2 实测:[code]OS.has_feature("movie")[/code] 在普通运行下为 false;
## 命令行里带 [code]--write-movie[/code] 时为 true(见 tests/probe)。
## 仍然同时检查命令行参数作为兜底 —— 这个判断错了整集渲染才会暴露,
## 多一层冗余远比事后重渲便宜。
static func detect_movie_mode() -> bool:
	if force_mode >= 0:
		return force_mode == 1
	if OS.has_feature("movie"):
		return true
	for a in OS.get_cmdline_args():
		if a.begins_with("--write-movie"):
			return true
	return false


func is_movie_mode() -> bool:
	return _movie


## 从 [param from] 秒开始计时。
func start(from: float = 0.0) -> void:
	_start_offset = maxf(from, 0.0)
	_start_frame = Engine.get_frames_drawn()
	_frozen = _start_offset
	_running = true


func stop() -> void:
	_frozen = now()
	_running = false


## 暂停后恢复:重新以当前时间为原点,离线模式下帧计数才不会把暂停时长算进去。
func resume() -> void:
	if _running:
		return
	start(_frozen)


func is_running() -> bool:
	return _running


## 当前 sheet 时间(秒)。
func now() -> float:
	if not _running:
		return _frozen
	if _movie:
		# 纯帧计数 —— 不读任何音频状态,因此是确定性的。
		return _start_offset + float(Engine.get_frames_drawn() - _start_frame) / fps
	if player == null or not player.playing:
		return _frozen
	var t := player.get_playback_position()
	t += AudioServer.get_time_since_last_mix()
	t -= AudioServer.get_output_latency()
	t -= extra_latency
	return maxf(t, 0.0)


## 把时间量化到帧边界。离线渲染下标记触发帧号必须是确定的整数。
func frame_of(t: float) -> int:
	return int(floor(t * fps))
