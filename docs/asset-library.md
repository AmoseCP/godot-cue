# Godot Asset Library 提交清单

提交表单在 <https://godotengine.org/asset-library/asset> → Submit Asset。
下面是逐字段的内容,直接复制。

## 表单字段

| 字段 | 值 |
|---|---|
| **Asset name** | Cue — 音频波形与命名事件标记 |
| **Category** | Tools |
| **Godot version** | 4.4(实际开发与验证在 **4.7.2.stable**;`plugin.cfg` 不限定下界,但下面「兼容性」一节列了已知的版本依赖) |
| **Version string** | 0.9.0 |
| **Repository provider** | GitHub |
| **Repository URL** | https://github.com/AmoseCP/godot-cue |
| **Issues URL** | https://github.com/AmoseCP/godot-cue/issues |
| **Download commit / tag** | `v0.9.0` |
| **Icon URL** | https://raw.githubusercontent.com/AmoseCP/godot-cue/main/docs/icon.png |
| **License** | MIT |

## Brief description(一句话)

> 在音频波形上打命名标记,然后在脚本里 `await Cue.at(&"marker")`。
> 为配音驱动的 2D 动画而做,Movie Maker 离线渲染下确定性正确。

## Description(正文)

```
Cue 让你像用 Motion Canvas 的 waitUntil() 那样写分镜:在配音波形上打命名标记,
脚本里 await 它们。时间点全在 .tres 资源里,拖一下标记就改了,代码一行不用动。

纯 GDScript,无 GDExtension,无需编译,复制 addons/cue/ 即可使用。

主要功能
· 底部面板:波形绘制、秒/帧标尺、缩放平移、多轨泳道与折叠
· 标记的增删改拖,全部走 EditorUndoRedoManager
· 一个 sheet 可容纳多段音频(多角色分轨配音),标记时间轴跨片段统一
· 双模时钟:实时预览跟音频走,Movie Maker 离线渲染纯帧计数 —— 两次渲染
  逐帧 SHA256 完全一致(仓库里有可复跑的验证脚本)
· 口型同步:导入 Rhubarb Lip Sync JSON 与 Montreal Forced Aligner TextGrid;
  CueMouthShape 节点驱动嘴型;没有口型数据时可用振幅包络降级
· 频谱图视图(纯 GDScript FFT)、字幕文本对照
· 标记与包络的 CSV / JSON 导出;从标记一键生成 GDScript 剧本骨架
· MP3/OGG 经外部 ffmpeg 预转(可选依赖,没有它其余功能照常)

音频格式:波形分析读未压缩的 16/8-bit PCM WAV。Godot 4.4+ 默认以 QOA 压缩
导入 WAV,Cue 会直接解析源 .wav 文件绕开它,所以你不必改任何导入设置。

界面与提示信息为中文。
```

## Preview images

按顺序上传(仓库内路径,提交时用 raw.githubusercontent 链接):

1. `docs/example.png` —— 标记驱动的分镜示例
2. `docs/multi-voice-example.png` —— 多角色分轨
3. `docs/mouth-example.png` —— 口型同步 vs 响度降级方案
4. `docs/spectrogram-example.png` —— 频谱图

## 兼容性说明

开发与全部验证都在 **Godot 4.7.2.stable**(macOS arm64)完成。
以下依赖决定了实际可用的最低版本,提交前若要放宽下界需逐条复验:

- `AudioStreamWAV.FORMAT_QOA` —— Godot 4.3+
- `@icon` 注解、`EditorUndoRedoManager` —— 4.0+
- 编辑器主题键 `("main", "EditorFonts")` —— 见 `docs/godot-4.7-notes.md`,
  这个键名在 4.x 内部改过,老版本上可能取不到字体(会退化为不画文字,不崩)

## 提交前自查

- [ ] `tests/run_all.sh` 全绿
- [ ] 从零 clone 后冷启动 0 error / 0 warning
- [ ] `addons/cue/plugin.cfg` 的 version 与 git tag 一致
- [ ] README 顶部的截图链接可访问
- [ ] LICENSE 在仓库根目录
- [ ] tag 已推送:`git tag -a v0.9.0 -m "..." && git push origin v0.9.0`

## 为什么是 0.9.0 而不是 1.0.0

计划里的 P0 / P1 / P2 都已实现并有自动化验收,但 **M2 的核心验收项
——「播放头位置与实际听到的声音偏差 < 1 帧,macOS 和 Windows 分别验证」
——需要人戴耳机实测**,机器验不了(见 `tests/MANUAL.md`)。
在那条走通、并且真正用它做完一集视频之前,不标 1.0。
