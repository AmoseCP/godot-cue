# probe/

这些不是测试,是**实测脚本** —— 每一个都对应 `docs/godot-4.7-notes.md`
里的一条结论。计划阶段对 Godot API 的假设有好几条是错的,
这些脚本就是当初用来证伪它们的,留在这里方便你在别的 Godot 版本上复查。

```bash
G=/Applications/Godot.app/Contents/MacOS/Godot

$G --headless --path . --script tests/probe/probe_audio.gd       # 音频格式枚举、导入后的 format、PackedByteArray 解码
$G --headless --path . --script tests/probe/probe_perf.gd        # 三种 PCM 解码策略的基准
$G --headless --path . --script tests/probe/probe_editor_api.gd  # 编辑器 API 是否存在
$G --headless --path . --script tests/probe/probe_undo.gd        # EditorUndoRedoManager 的方法与常量
$G --headless --path . --script tests/probe/probe_frames.gd      # frames_drawn 在 headless 下的行为、lambda 捕获语义
$G --path . tests/probe/latency_probe.tscn                       # 真实音频驱动下的输出延迟(要有声卡)
```

先跑 `tests/make_fixtures.gd` 生成所需音频。
