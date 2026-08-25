# Godot 4.7 实测笔记

写 Cue 的过程中撞到的 Godot 行为,每一条都在
**4.7.2.stable.official.ed1daf0bf**(macOS arm64)上实测过,
复现脚本在 [`tests/probe/`](../tests/probe/)。

放在这里是因为这些坑跟 Cue 本身无关 —— 任何写 Godot 编辑器插件、
做音频可视化、或者依赖离线渲染确定性的人都可能撞上。

---

## 1. 4.4+ 默认用 QOA 压缩导入 WAV

把一个 `.wav` 拖进项目,默认 `.import` 里是 `compress/mode=2`,
加载后 `AudioStreamWAV.format == 3 == FORMAT_QOA`。
`data` 是压缩数据,**GDScript 解不了**。

```
1 秒 44.1kHz 单声道:data.size() = 17864   (裸 PCM 应该是 88200)
```

枚举值:`FORMAT_8_BITS=0  FORMAT_16_BITS=1  FORMAT_IMA_ADPCM=2  FORMAT_QOA=3`

**Cue 的处理**:优先自己解析源 `.wav` 文件(走 RIFF chunk),
导入设置完全不影响它;源文件不在时才回退去读 `data`,
那时才检查 format 并提示用户关掉压缩。

解析 RIFF 时**不能假设 44 字节固定头** —— Audacity 会插 `LIST`/`INFO` 块,
必须逐 chunk 遍历。另外 RIFF 的 8-bit PCM 是**无符号**的(128 = 静音),
而 Godot 内部的 `FORMAT_8_BITS` 是**有符号**的,两条路径要分别处理。

复现:`tests/probe/probe_audio.gd`

---

## 2. GDScript 逐采样循环没有想象中慢,批量转换反而更慢

常见建议是"别在 GDScript 里逐采样循环,用 `to_int32_array()` 批量转换"。
实测 5 分钟 44.1kHz 单声道(13,230,000 采样)求 min/max:

| 策略 | 耗时 |
|---|---|
| 逐采样 `decode_s16` | **627ms** |
| `to_int32_array()`(2ms)+ GDScript 位提取循环 | 850ms |
| 步进 1/4 + `decode_s16` | 234ms |

`to_int32_array()` 本身只要 2ms,但之后在 GDScript 里做位提取和符号修正的
开销超过了直接 `decode_s16`。所以 Cue 用逐采样,峰值是**精确**的,
不做步进近似;分块 `await` 只是为了不冻结编辑器 UI,不是为了性能。

复现:`tests/probe/probe_perf.gd`

---

## 3. 编辑器主题里没有 `("font", "Editor")`

直觉写法会打警告:

```gdscript
theme.get_font("font", "Editor")
# WARNING: Trying to access a non-existing editor theme font 'font' in 'Editor'.
```

实测主题的字体类型列表:

```
["EditorFonts", "MainScreenButton", "Label", "HeaderSmall", "HeaderMedium",
 "HeaderLarge", "RichTextLabel", "FoldableContainer", "Window",
 "HeaderSmallLink", "TopBarOptionButton", "GraphStateMachine", "CodeEdit"]
```

正确的键是 **`("main", "EditorFonts")`** / **`("main_size", "EditorFonts")`**。

颜色确实在 `"Editor"` 下(`dark_color_1/2`、`accent_color`、`font_color`、
`warning_color`、`error_color`、`property_color_z` 都在),
图标在 `"EditorIcons"` 下。

另外:**`EditorInterface.save_resource()` 不存在**,用 `ResourceSaver.save()`。

---

## 4. `EditorUndoRedoManager` 的历史归属会按对象类型分裂

症状:每次编辑都刷一条

```
ERROR: UndoRedo history mismatch: expected 0, got 1.
```

实测 `get_object_history_id()`:

| 对象 | history id |
|---|---|
| 已存盘的自定义 Resource | 0(`GLOBAL_HISTORY`) |
| 编辑器里的 `Control` 节点 | 0 |
| **新建的、没有 `resource_path` 的子 Resource** | **1**(当前编辑场景的历史) |

也就是说 `create_action(..., sheet)` 把动作锁在历史 0 之后,
任何 `add_do_property(子资源, ...)` 都会被判成历史 1,于是冲突。
**`add_do_reference()` / `add_undo_reference()` 同样做这个校验**,
不只是 property / method。

绕开的办法(两条要一起用):

1. **所有 undo 动作的目标对象统一成那个已存盘的资源**,
   子资源只作为**参数**传进去 —— 参数不参与历史判定。
   为此在容器资源上加 `set_child_time(child, v)` 这类方法。
2. **不用 `add_*_reference()`**,改由容器资源自己用一个非 `@export`
   的数组拿住被删掉的子资源,免得没人引用就被释放。

另外 `EditorUndoRedoManager` **没有** `undo()` / `redo()` 方法;
要撤销得走 `get_history_undo_redo(history_id)` 拿到底层的 `UndoRedo`。

复现:`tests/probe/probe_undo.gd`,回归测试 `tests/edit_harness/`

---

## 5. `Engine.get_frames_drawn()` 在 `--headless` 下恒为 0

dummy 渲染器什么都不画,所以计数器不动。任何拿它当时钟的逻辑
在 headless CLI 里会直接冻住。

**`Engine.get_process_frames()`**(主循环迭代数)两种环境下都推进,
而且 Movie Maker 下一次迭代恰好对应一帧输出 —— 确定性等价。
Cue 换成它之后,双次渲染仍然逐帧 SHA256 一致。

---

## 6. `--write-movie` 会被引擎从命令行参数里吃掉

`OS.has_feature("movie")` 在 `--write-movie` 下确实是 `true`,可以放心用。

但**别指望**用扫命令行参数当兜底 —— 实测渲染时
`OS.get_cmdline_args()` 只剩场景路径,`--write-movie` 已经被引擎消化掉了:

```
MODE movie=true cmdline=["tests/determinism/main.tscn"]
```

---

## 7. macOS 上 `AudioServer.get_output_latency()` 返回 0.0

不只是 headless 的 Dummy 驱动 —— 用真实的 **CoreAudio** 驱动也返回 `0.0`:

```
LAT driver=CoreAudio
LAT output_latency=0.0
LAT time_since_last_mix=0.008097
LAT mix_rate=48000.0
```

CoreAudio 实际输出延迟通常有 10~20ms,这部分**不会**被自动补偿。
需要音画精确对齐的话得留一个手调偏移项。

复现:`tests/probe/latency_probe.tscn`(需要声卡)

---

## 8. GDScript 的 lambda 按值捕获局部变量

```gdscript
var flag := false
var arr: Array = []
var lam := func() -> void:
    flag = true          # 改的是副本,外面看不到
    arr.append("x")      # 这个看得到(Array 是引用类型)
lam.call()
# flag == false,  arr == ["x"]
```

在协程里往外回传状态时特别容易中招 —— 用 `Array` / `Dictionary` 包一层。

复现:`tests/probe/probe_frames.gd`

---

## 9. 进程退出时带活跃 WAV 播放会报"资源仍在使用"

```
WARNING: 2 ObjectDB instances were leaked at exit.
ERROR: 1 resources still in use at exit.
  Leaked instance: AudioStreamPlaybackWAV - Reference count: 1
  Leaked instance: AudioStreamWAV - Reference count: 1
```

这是引擎自身的关闭顺序问题,**不是插件的错**。
用一个裸 `AudioStreamPlayer` 播 `AudioStreamWAV` 然后退出即可复现,
全程不涉及任何第三方代码。在播放结束后再退出就不会出现。
