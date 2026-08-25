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


func bucket_count() -> int:
	return mins.size()


## 每个 bucket 覆盖的秒数。
func seconds_per_bucket() -> float:
	if mix_rate <= 0:
		return 0.0
	return float(samples_per_bucket) / float(mix_rate)


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
