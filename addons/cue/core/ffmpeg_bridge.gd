@tool
class_name CueFFmpeg

## 用外部 ffmpeg 把 MP3 / OGG / M4A 预转成 16-bit PCM WAV,再交给
## [CuePcmReader] 分析。
##
## GDScript 解不了这些压缩格式,而 PLAN 又不允许引入任何需要编译的依赖
## (D1),所以只能借外部工具。**ffmpeg 是可选的** —— 没有它,插件的其余
## 部分照常工作,只是 MP3/OGG 会给出一条说明怎么装的中文提示。
##
## [b]关于 D8(只读音频,永不写音频)[/b]:转出来的 WAV 写在
## [code]user://cue_cache/[/code] 下,按源文件哈希命名,既不放在源文件旁边
## 也永不覆盖源文件。它是派生缓存,不是对用户音频的改动 ——
## PLAN 第 5 节的 P2 条目本身就写明了"通过检测外部 ffmpeg 预转 WAV"。

const CACHE_DIR := "user://cue_cache"
## 可在项目设置里指定 ffmpeg 路径,免得依赖 PATH。
const SETTING_PATH := "cue/audio/ffmpeg_path"

## 需要转码的扩展名。
const NEEDS_CONVERT := ["mp3", "ogg", "oga", "m4a", "aac", "flac", "opus", "wma"]

## 常见安装位置。Godot 的 [method OS.execute] 不走 shell,
## 编辑器进程拿到的 PATH 未必包含 Homebrew 那几个目录
## (macOS 上从 Dock 启动的 GUI 程序尤其典型),所以必须自己找一遍。
const COMMON_PATHS := [
	"/opt/homebrew/bin/ffmpeg",
	"/usr/local/bin/ffmpeg",
	"/usr/bin/ffmpeg",
	"/bin/ffmpeg",
	"/opt/local/bin/ffmpeg",
	"C:/ffmpeg/bin/ffmpeg.exe",
	"C:/Program Files/ffmpeg/bin/ffmpeg.exe",
]

static var _cached_path: String = ""
static var _searched: bool = false


static func needs_convert(path: String) -> bool:
	return NEEDS_CONVERT.has(path.get_extension().to_lower())


## ffmpeg 可执行文件的绝对路径;找不到返回空串。结果会缓存。
static func find() -> String:
	if _searched:
		return _cached_path
	_searched = true
	_cached_path = ""

	if ProjectSettings.has_setting(SETTING_PATH):
		var custom := String(ProjectSettings.get_setting(SETTING_PATH))
		if custom != "" and FileAccess.file_exists(custom):
			_cached_path = custom
			return _cached_path

	for p in COMMON_PATHS:
		if FileAccess.file_exists(p):
			_cached_path = p
			return _cached_path

	# 最后才问系统 —— which/where 依赖进程 PATH,不一定靠谱
	var out: Array = []
	var finder := "where" if OS.get_name() == "Windows" else "which"
	if OS.execute(finder, ["ffmpeg"], out, false) == 0 and not out.is_empty():
		var line := String(out[0]).strip_edges().split("\n")[0].strip_edges()
		if line != "" and FileAccess.file_exists(line):
			_cached_path = line
	return _cached_path


static func available() -> bool:
	return find() != ""


## 忘掉缓存的路径。用户改了项目设置之后调。
static func forget() -> void:
	_searched = false
	_cached_path = ""


static func version() -> String:
	var exe := find()
	if exe == "":
		return ""
	var out: Array = []
	if OS.execute(exe, ["-version"], out, false) != 0 or out.is_empty():
		return ""
	return String(out[0]).strip_edges().split("\n")[0]


## 缓存文件名按**源文件内容**的哈希取,所以换了音频会自动重转,
## 而同一个文件重复分析不会重复转码。
static func cache_path_for(src: String) -> String:
	var h := WaveformCache.compute_hash(src)
	if h == "":
		h = str(src.hash())
	return "%s/%s.wav" % [CACHE_DIR, h]


## 把 [param src] 转成 16-bit PCM WAV,返回缓存文件的路径。
## 失败时返回空串,[param out_error] 里是中文错误说明。
static func to_wav(src: String, out_error: Array = []) -> String:
	if not FileAccess.file_exists(src):
		out_error.append("Cue:找不到音频文件 %s。" % src)
		return ""

	var dst := cache_path_for(src)
	if FileAccess.file_exists(dst):
		return dst                      # 命中缓存,不重复转码

	var exe := find()
	if exe == "":
		out_error.append(
			"Cue:%s 需要 ffmpeg 才能分析(GDScript 解不了压缩音频)。\n"
			% src.get_file()
			+ "请安装 ffmpeg(macOS:brew install ffmpeg;Windows:scoop install ffmpeg),"
			+ "或在「项目设置 → Cue → Audio → Ffmpeg Path」里填它的绝对路径。\n"
			+ "也可以直接用 Audacity 把它导出成 16-bit PCM WAV。")
		return ""

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	var abs_src := ProjectSettings.globalize_path(src)
	var abs_dst := ProjectSettings.globalize_path(dst)

	var out: Array = []
	var code := OS.execute(exe, [
		"-v", "error",
		"-y",
		"-i", abs_src,
		"-acodec", "pcm_s16le",
		abs_dst,
	], out, true)

	if code != 0 or not FileAccess.file_exists(dst):
		var detail := String(out[0]).strip_edges() if not out.is_empty() else ""
		out_error.append("Cue:ffmpeg 转码失败(退出码 %d)。%s" % [code, detail])
		return ""
	return dst


## 清空转码缓存。
static func clear_cache() -> int:
	var abs_dir := ProjectSettings.globalize_path(CACHE_DIR)
	var d := DirAccess.open(abs_dir)
	if d == null:
		return 0
	var n := 0
	for f in d.get_files():
		if f.ends_with(".wav") and d.remove(f) == OK:
			n += 1
	return n
