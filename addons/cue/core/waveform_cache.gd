@tool
class_name WaveformCache extends Resource

## 预计算的波形峰值。每个 bucket 保存该区间内的最小/最大采样值(-1..1)。
##
## 之所以缓存,是因为 5 分钟 44.1kHz 单声道有 1300 万个采样,
## 不可能在每次重绘时扫描(见 PLAN D3)。

@export var mins: PackedFloat32Array = PackedFloat32Array()
@export var maxs: PackedFloat32Array = PackedFloat32Array()
@export var samples_per_bucket: int = 256
@export var mix_rate: int = 44100
@export var duration: float = 0.0
## 源音频文件的哈希,用于检测音频被替换后缓存失效。
@export var source_hash: String = ""


## 降采样金字塔。**只在内存里**,不进 .tres ——
## 它完全可以从 level 0 重算,存进资源只会让文本文件白白变大四成。
##
## PLAN 把 LOD 列为"仅在实测卡顿时"才做的 P1 项。实测触发条件了:
## 4 段音频、整集视野下,每列要扫约 43 个 bucket,线段重建 18ms/帧,
## 段数再多就掉到 30fps 以下。有了金字塔之后每列固定只扫 1~4 个 bucket,
## 开销与缩放级别无关。
##
## 每一级是上一级 4 个 bucket 的 min/max 合并 —— **是精确的**,
## 不是近似:min 的 min 就是 min。
var _lod_mins: Array[PackedFloat32Array] = []
var _lod_maxs: Array[PackedFloat32Array] = []

## 每级相对上一级的降采样倍数。
const LOD_FACTOR := 4
## 最小保留的 bucket 数,再往下分级没意义。
const LOD_MIN_BUCKETS := 64


func bucket_count() -> int:
	return mins.size()


## 每个 bucket 覆盖的秒数。
func seconds_per_bucket() -> float:
	if mix_rate <= 0:
		return 0.0
	return float(samples_per_bucket) / float(mix_rate)


## 按需建好金字塔。已经建过就直接返回。
func ensure_lod() -> void:
	if not _lod_mins.is_empty() or not is_valid():
		return
	_lod_mins = [mins]
	_lod_maxs = [maxs]
	var cur_min := mins
	var cur_max := maxs
	while cur_min.size() > LOD_MIN_BUCKETS * LOD_FACTOR:
		var n := cur_min.size() / LOD_FACTOR
		var nm := PackedFloat32Array(); nm.resize(n)
		var nx := PackedFloat32Array(); nx.resize(n)
		for i in n:
			var b := i * LOD_FACTOR
			var lo: float = cur_min[b]
			var hi: float = cur_max[b]
			for k in range(1, LOD_FACTOR):
				var j := b + k
				if cur_min[j] < lo: lo = cur_min[j]
				if cur_max[j] > hi: hi = cur_max[j]
			nm[i] = lo
			nx[i] = hi
		_lod_mins.append(nm)
		_lod_maxs.append(nx)
		cur_min = nm
		cur_max = nx


func lod_levels() -> int:
	return _lod_mins.size()


## 一列要覆盖 [param buckets_per_column] 个 level-0 bucket 时,该用第几级。
## 目标是每列只扫 1~LOD_FACTOR 个 bucket。
func lod_level_for(buckets_per_column: float) -> int:
	ensure_lod()
	var lv := 0
	var span := buckets_per_column
	while lv < _lod_mins.size() - 1 and span > float(LOD_FACTOR):
		span /= float(LOD_FACTOR)
		lv += 1
	return lv


func lod_mins(level: int) -> PackedFloat32Array:
	ensure_lod()
	return _lod_mins[clampi(level, 0, _lod_mins.size() - 1)]


func lod_maxs(level: int) -> PackedFloat32Array:
	ensure_lod()
	return _lod_maxs[clampi(level, 0, _lod_maxs.size() - 1)]


## 第 [param level] 级上,一个 bucket 覆盖多少秒。
func lod_seconds_per_bucket(level: int) -> float:
	return seconds_per_bucket() * pow(float(LOD_FACTOR), float(level))


func is_valid() -> bool:
	return mins.size() > 0 and mins.size() == maxs.size() and mix_rate > 0


## 缓存是否仍匹配给定音频文件。
func matches(audio_path: String) -> bool:
	if not is_valid():
		return false
	return source_hash != "" and source_hash == compute_hash(audio_path)


## 音频文件指纹。用 md5 是因为这里只需要检测"文件变了",不涉及安全性。
static func compute_hash(audio_path: String) -> String:
	if audio_path == "" or not FileAccess.file_exists(audio_path):
		return ""
	return FileAccess.get_md5(audio_path)
