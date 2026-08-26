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

## 手动延迟偏移(秒)。负值表示"从项目设置读",这是默认行为。
##
## 4.7.2 实测:[method AudioServer.get_output_latency] 在 macOS 上用真实的
## CoreAudio 驱动也返回 **0.0**(不只是 headless 的 Dummy 驱动),
## 而 CoreAudio 实际输出延迟通常有 10~20ms。M2 要求播放头与声音偏差 < 1 帧
## (33ms @30fps),白白吃掉一半余量。所以留这个手调项,
## 对应 PLAN 第 7 节写的缓解措施。
static var extra_latency: float = -1.0

## 项目设置里的手调延迟,单位毫秒。由编辑器插件注册,运行时只读。
const SETTING_EXTRA_LATENCY := "cue/playback/extra_latency_ms"

var fps: float = 30.0
## 当前用作时间锚点的播放器。多片段时由 [Cue] 每帧切换成"覆盖当前时刻的那一段"。
var player: AudioStreamPlayer = null
## 锚点片段在 sheet 时间轴上的起点。播放位置是段内的,要加上它才是 sheet 时间。
var anchor_offset: float = 0.0

var _movie: bool = false
var _start_frame: int = 0
var _start_offset: float = 0.0
var _running: bool = false
var _frozen: float = 0.0
# 片段之间没有音频在响时的续推基准。
var _wall_base: float = 0.0
var _wall_start_us: int = 0
## 实测到的渲染帧率。0 = 还没测到,先用 [member fps]。
var _render_fps: float = 0.0


func _init(p_fps: float = 30.0, p_player: AudioStreamPlayer = null) -> void:
	fps = maxf(p_fps, 1.0)
	player = p_player
	_movie = detect_movie_mode()


## Movie Maker 模式检测。
##
## 4.7.2 实测:[code]OS.has_feature("movie")[/code] 是**唯一**可靠的判据 ——
## 普通运行下为 false,带 [code]--write-movie[/code] 时为 true。
##
## 注意:引擎会把 [code]--write-movie[/code] 从
## [method OS.get_cmdline_args] 里[b]吃掉[/b](实测渲染时该数组只剩场景路径),
## 所以下面那段命令行扫描在 4.7 上永远不会命中。留着只是防未来版本改行为,
## 不要把它当成真正的兜底。
static func detect_movie_mode() -> bool:
	if force_mode >= 0:
		return force_mode == 1
	if OS.has_feature("movie"):
		return true
	for a in OS.get_cmdline_args():
		if a.begins_with("--write-movie"):
			return true
	return false


## 帧计数源。
##
## 4.7.2 实测:[code]Engine.get_frames_drawn()[/code] 在 [code]--headless[/code]
## 下[b]恒为 0[/b](dummy 渲染器什么都不画),用它的话运行时逻辑在 headless CLI
## 里时钟是冻住的 —— 而 PLAN D9 要求 runtime/ 能在 headless 下跑。
## [code]Engine.get_process_frames()[/code] 数的是主循环迭代次数,两种环境下都推进,
## 且 Movie Maker 下一次迭代恰好对应一帧输出,确定性与 frames_drawn 等价
## (tests/determinism.sh 两次渲染逐帧 SHA256 一致,已验证)。
static func _frame_counter() -> int:
	return Engine.get_process_frames()


## 实际生效的手调延迟(秒)。
static func extra_latency_seconds() -> float:
	if extra_latency >= 0.0:
		return extra_latency
	if ProjectSettings.has_setting(SETTING_EXTRA_LATENCY):
		return float(ProjectSettings.get_setting(SETTING_EXTRA_LATENCY)) * 0.001
	return 0.0


## 用实际渲染帧率校准离线时钟。
##
## [b]为什么需要这个[/b]:CueSheet 的 fps 是**编辑器概念**(帧吸附、帧标尺),
## 和 Movie Maker 实际录制的帧率没有任何强制关系。4.7.2 实测:
## 项目设置 [code]editor/movie_writer/fps[/code] 读得到值,但**独立运行
## `--write-movie` 时并不生效**,除非显式传 [code]--fixed-fps[/code];
## 默认就是 60。于是一个 30fps 的 sheet 按 60fps 渲染出去,
## 若拿 sheet.fps 当除数,时间会走得[b]快一倍[/b],整集动画全部提前。
##
## 离线模式下 Godot 强制固定时间步,所以 [param delta] 恰好是 1/实际帧率,
## 由它反推最可靠 —— 不依赖任何设置项。
## [b]守卫用的是 OS.has_feature("movie") 而不是 _movie[/b]:
## 只有真正在录影片时 Godot 才强制固定时间步。测试里用 force_mode 假装离线
## 时帧率并不受限,delta 是真实耗时(headless 下可能是零点几毫秒),
## 拿它反推会得出上万的"帧率",时钟直接停摆。这条守卫踩过一次才加的。
func observe_delta(delta: float) -> void:
	if _render_fps > 0.0 or not OS.has_feature("movie"):
		return
	var measured := fps_from_delta(delta)
	if measured > 0.0:
		_render_fps = measured


## 从固定时间步反推帧率。纯函数,单独抽出来是为了能脱离运行环境测。
static func fps_from_delta(delta: float) -> float:
	# 超过 1 秒的时间步不可能是真实的渲染帧率,当作测不到
	if delta <= 0.0 or delta > 1.0:
		return 0.0
	return round(1.0 / delta)


## 离线模式下每秒推进多少帧。
func render_fps() -> float:
	return _render_fps if _render_fps > 0.0 else fps


func is_movie_mode() -> bool:
	return _movie


## 从 [param from] 秒开始计时。
func start(from: float = 0.0) -> void:
	_start_offset = maxf(from, 0.0)
	_start_frame = _frame_counter()
	_frozen = _start_offset
	_wall_base = _start_offset
	_wall_start_us = Time.get_ticks_usec()
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
		return _start_offset + float(_frame_counter() - _start_frame) / render_fps()
	if is_instance_valid(player) and player.playing and not player.stream_paused:
		var t := anchor_offset + player.get_playback_position()
		t += AudioServer.get_time_since_last_mix()
		t -= AudioServer.get_output_latency()
		t -= extra_latency_seconds()
		t = maxf(t, 0.0)
		# 记下锚点,片段结束后好从这里continue往下推
		_wall_base = t
		_wall_start_us = Time.get_ticks_usec()
		return t

	# 没有音频锚点 —— 片段之间的空隙,或者最后一段已经放完。
	#
	# 这是 CueClock [b]唯一[/b]直接读系统时钟的地方,也是唯一允许的地方:
	# 它本身就是"时间源抽象",而这条分支只在实时预览下走得到。
	# 离线渲染永远走上面的帧计数分支,确定性不受影响
	# (CLAUDE.md 禁止的是[b]运行时逻辑[/b]绕过 CueClock 直接读时钟)。
	return _wall_base + float(Time.get_ticks_usec() - _wall_start_us) / 1_000_000.0


## 把时间量化到帧边界。离线渲染下标记触发帧号必须是确定的整数。
func frame_of(t: float) -> int:
	return int(floor(t * fps))
