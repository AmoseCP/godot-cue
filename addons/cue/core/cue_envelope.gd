@tool
class_name CueEnvelope extends Resource

## 等间隔的振幅包络。
##
## 存在的意义是**降级方案**:没有 Rhubarb / MFA 的时候(临时配音、
## 非英语素材、赶工),用响度直接驱动几档嘴型开合。效果当然不如真口型同步,
## 但比嘴不动强得多,而且零外部依赖。
##
## [method at] 是时间的纯函数,所以拿它驱动动画不会破坏离线渲染的确定性。

## 每个采样点的振幅,已归一化到 0..1。
@export var values: PackedFloat32Array = PackedFloat32Array()
## 每秒多少个采样点。60 足够跟上嘴型,数据量也小(5 分钟 = 18000 个 float)。
@export var rate: float = 60.0
@export var duration: float = 0.0
## 来源音频的哈希,和 [WaveformCache] 用同一套失效检测。
@export var source_hash: String = ""


func is_valid() -> bool:
	return values.size() > 0 and rate > 0.0


func count() -> int:
	return values.size()


func matches(audio_path: String) -> bool:
	if not is_valid():
		return false
	return source_hash != "" and source_hash == WaveformCache.compute_hash(audio_path)


## [param t] 时刻的振幅(0..1),线性插值。纯函数。
func at(t: float) -> float:
	if not is_valid():
		return 0.0
	var x := t * rate
	if x <= 0.0:
		return values[0]
	var i := int(x)
	if i >= values.size() - 1:
		return values[values.size() - 1]
	var f := x - float(i)
	return lerpf(values[i], values[i + 1], f)


## 按阈值把振幅分档,返回 0..thresholds.size() 的档位。
##
## 阈值必须升序。返回值即"有多少个阈值被越过",所以
## [code]thresholds = [0.04, 0.15, 0.35][/code] 会给出 4 档:静音 / 小 / 中 / 大。
func level(t: float, thresholds: PackedFloat32Array) -> int:
	var a := at(t)
	var n := 0
	for th in thresholds:
		if a >= th:
			n += 1
		else:
			break
	return n


## 峰值,用来判断这段音频整体够不够响。
func peak() -> float:
	var m := 0.0
	for v in values:
		if v > m:
			m = v
	return m


## 导出成 JSON,给外部工具用(比如在 Blender 或 AE 里做同样的嘴型驱动)。
## 结构刻意扁平:[code]{rate, duration, values: [...]}[/code]。
func export_json(path: String, decimals: int = 4) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	var rounded: Array = []
	rounded.resize(values.size())
	var q: float = pow(10.0, float(decimals))
	for i in values.size():
		rounded[i] = round(values[i] * q) / q
	f.store_string(JSON.stringify({
		"rate": rate,
		"duration": duration,
		"count": values.size(),
		"values": rounded,
	}))
	f.close()
	return OK


## 导出成 CSV(两列:秒, 振幅),方便丢进表格或 gnuplot 看一眼。
func export_csv(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_line("time,amplitude")
	for i in values.size():
		f.store_line("%.4f,%.5f" % [float(i) / rate, values[i]])
	f.close()
	return OK
