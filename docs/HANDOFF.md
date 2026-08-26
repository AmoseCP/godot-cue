# 交接文档

给接手继续开发的人。读完这份 + 跑一遍测试,应该就能动手了。

**为什么需要这份文档**:这个项目的规划文档(`PLAN.md`)、实测笔记(`NOTES.md`)
和 AI 协作指令(`CLAUDE.md`)都在 `.gitignore` 里,clone 仓库拿不到。
决策历史和踩坑记录本来只存在于那几个文件里,这份是它们的公开提炼。
(如果你能拿到原始的 `PLAN.md` / `NOTES.md`,值得一读,细节比这里多得多。)

面向用户的说明在 [README](../README.md),不在这里重复。

---

## 1. 第一小时

```bash
git clone https://github.com/AmoseCP/godot-cue.git
cd godot-cue

# 全套测试(约 10 分钟,最重的是两段编辑器会话和 8 次离线渲染)
tests/run_all.sh /path/to/godot

# 只跑不需要渲染的部分(约 1 分钟,日常迭代用这个)
tests/run_all.sh /path/to/godot --skip-render
```

**日常迭代不要每次跑全套。** 改哪块跑哪块:

```bash
godot --headless --path . --script tests/test_runtime.gd    # 运行时
godot --headless --path . --script tests/test_core.gd       # PCM / 峰值 / 缓存
```

然后用 Godot 4.7+ 打开这个目录,按 F5 看 `examples/hello_cue`。
底部面板里点「打开」选 `examples/hello_cue/shot_01.tres`。

开发环境实测在 **Godot 4.7.2.stable / macOS arm64**。
CI 在 Linux 和 Windows 上跑 headless 部分。

---

## 2. 代码地图

```
addons/cue/
├── core/      14 个文件 1936 行 —— 数据层,编辑器和运行时共用
├── editor/    12 个文件 2594 行 —— 只在编辑器里跑
├── runtime/    3 个文件  835 行 —— 导出项目 / headless 里跑
└── import/     3 个文件  315 行 —— Rhubarb / TextGrid 解析
```

**唯一一条塑造了这个目录结构的硬规则:`runtime/` 和 `core/` 绝不能引用
`editor/` 里的任何东西。** 运行时代码必须能在导出的项目和 headless 渲染里跑。
改动时如果发现"运行时需要用编辑器的某个东西",那是设计出问题了,
不是加个 `if Engine.is_editor_hint()` 就能绕过去的。

### 几个值得先看的文件

| 文件 | 为什么重要 |
|---|---|
| `runtime/cue_clock.gd` | **整个插件正确性的核心**。双模时间源,离线渲染的确定性全靠它 |
| `runtime/cue.gd` | 运行时单例。`at()` 的等待语义在这里,历史上出过 4 个 bug |
| `core/cue_sheet.gd` | 数据模型中心。排序缓存、片段、undo 用的那批 setter |
| `editor/cue_panel.gd` | 面板门面。真正干活的是 `CueEditOps`(编辑)和 `CueAnalysisJobs`(长任务) |
| `core/pcm_reader.gd` | 音频解码。RIFF 逐 chunk 解析,绕开 Godot 的 QOA 压缩导入 |

---

## 3. 设计决策

原计划(`PLAN.md` 第 1 节)锁定了 10 条决策。**除 D10 外都还成立**:

| | 决策 | 现状 |
|---|---|---|
| D1 | 纯 GDScript,不引入需要编译的依赖 | 成立。ffmpeg 是**可选**外部工具,不是依赖 |
| D2 | 波形分析只支持 16-bit PCM WAV | 成立,但实现比计划好:直接读源 `.wav`,用户不用改导入设置 |
| D3 | 峰值离线预计算并缓存 | 成立。后来又加了内存里的 LOD 金字塔 |
| D4 | 时间源双模 | 成立,但**除数改了**(见下) |
| D5 | 标记存 `.tres` 文本资源 | 成立 |
| D6 | UI 放底部面板 | 成立 |
| D7 | 所有编辑走 `EditorUndoRedoManager` | 成立,而且是硬要求 |
| D8 | 只读音频,永不写音频 | 成立。ffmpeg 转出的 WAV 写在 `user://` 缓存,不碰源文件 |
| D9 | 运行时不依赖编辑器 | 成立,见上面那条硬规则 |
| ~~D10~~ | ~~一个 sheet 一个音频~~ | **已推翻 → D10′** |

**D10′**:`CueSheet` 持有 `segments: Array[CueAudioSegment]`,每段带 `offset`
和自己的 `waveform`。理由:多角色分轨配音是常态而非例外,做成外挂层会让
运行时 API 长期分裂成「单 sheet / sheet 组」两套。D10 原本「资源粒度小、
便于局部重渲」的诉求由**每段各自持有 waveform** 保留 —— 改一个角色只重算那一段。

> 如实记录:这次推翻是**产品决定**,不是实测证明 D10 不可行。
> D10 在技术上完全可行。

旧的 `audio` / `audio_path` / `waveform` 字段仍然保留,`all_segments()` 会用
它们合成一个片段,所以旧 `.tres` 不改也能开;点一次「分析波形」就地升级。

---

## 4. 这个项目踩过的坑

**这一节是这份文档最有价值的部分。** P0–P2 全部实现之后,后续找到的问题
**没有一个是"缺功能",全部是 bug**。它们高度集中在四类:

### 4.1 一个布尔量被用来回答不是二选一的问题

出过 **4 次**,全在 `runtime/cue.gd`:

```gdscript
while _playing:            # ← 错
    await marker_reached
```

`_playing` 在**三种**情况下都是 false:还没 `play()`、暂停中、已停止。
拿它当等待循环的条件,前两种情况下 `await` 会**立即返回** ——
「先起协程再 play()」会让整段分镜在一帧里跑完。

同一个错误在 `at()`、`after()`、`stop()` 的唤醒条件、`seek()` 里各出现一次。
现在统一用**播放轮次** `_generation`:判据是「这一轮有没有作废」。

**教训**:发现一个这类 bug 之后,立刻 `grep` 同一个变量的所有使用点。
四个里有三个是这么找到的。

### 4.2 缓存失效

`CueMarker` 的 setter 只在**标记自己**身上发 `changed`,`CueSheet` 收不到,
于是 `sheet.find(&"x").time = 5.0` 之后 `sorted()` 返回陈旧顺序,
`Cue` 的触发队列跟着错序。现在 sheet 盯住每个标记的 `changed`。

**改任何数据结构时,先问:谁缓存了它派生出来的东西?**

### 4.3 结论绑在未言明的前提上

我在这个项目上写错过 **3 次**结论,共同点都是这个:

| 错误结论 | 实际前提 | 真相 |
|---|---|---|
| 「波形 LOD 不需要,实测 2ms」 | 单片段 | 4 段音频时 18ms/帧,段数再多就掉到 30fps |
| 「编辑器 undo 历史上限 24」 | 一串 undo/redo 之后 | `max_steps = 0`(无限),真实机制是 **redo 分支截断** |
| 「性能测试 0ms,很快」 | 场景树已就绪 | 树没建好,`refresh()` 提前 return,**测试是空的** |

**写下任何性能或行为结论时,把测量条件一起写下来。**

### 4.4 工具本身的盲点

- **Godot 对 GDScript 解析错误、类型错误、脚本文件不存在一律退出 `0`。**
  只看退出码的 runner 会让一个编译不过的测试文件报绿。
  `run_all.sh` 现在要求每个套件**真的产出结果行**。
- **跳过的断言必须报数。** 第一次跑 CI 时 ffmpeg 套件跳过了 24 条却报绿 ——
  那次「成功」是虚假的信心,而漏掉的正好是最想验的 Windows 分支。
- **一个提前 return 的函数和一个高效的函数在计时器上长得一样。**
  性能测试要附带「它真的干活了」的断言。

其余 Godot 4.7 的坑(QOA 默认导入、编辑器主题键名、`UndoRedo` 历史归属、
`--write-movie` 的帧率设置不生效等)整理在
[`docs/godot-4.7-notes.md`](godot-4.7-notes.md),每条都有 `tests/probe/` 下的
复现脚本。**改相关代码之前先扫一眼那份。**

---

## 5. 测试

739 条自动化断言(618 条 headless 脚本 + 121 条编辑器 harness),
外加 315 帧逐帧哈希、跨帧率回归、10 轮插件启停。

| 类型 | 位置 | 怎么跑 |
|---|---|---|
| headless 脚本 | `tests/test_*.gd` | `godot --headless --path . --script <文件>` |
| 编辑器 harness | `tests/*_harness/` | 是 EditorPlugin,由 `run_all.sh` 启停 |
| 确定性 | `tests/determinism.sh` | 双次 `--write-movie` 逐帧 SHA256 |
| 人工 | `tests/MANUAL.md` | 58 项,**一项都没勾** |

### 为什么有两个 harness,而且必须分开跑

`toggle_harness` 会反复禁用/启用 Cue 插件;和 `edit_harness` 同时跑会把
后者正在操作的面板和 undo 历史掀掉,产生假失败。`run_all.sh` 分两次跑。

### 确定性测试是这个项目最重要的一条

```bash
tests/determinism.sh
```

同一场景 `--write-movie` 渲染两次,PNG 逐帧 SHA256 必须完全一致。
**它失败不是"小 bug",是架构问题** —— 说明运行时逻辑里混进了非确定性的时间源。

脚本自带两道自检:确认每帧哈希**互不相同**(否则"两次一致"可能只是
"全是空白帧"),以及换个帧率重渲一次确认标记触发时刻不漂移。

渲染有 180 秒看门狗 —— 曾经有一次渲染卡死 56 分钟一帧未出(**未能复现,
根因不明**),不管原因是什么都不该把套件拖到无限期。

### 加新测试时

- 断言消息写清「期望什么、为什么」,不要只写 `assert(x == y)`
- 性能测试必须附带「它真的干活了」的断言(见 4.4)
- 用到场景树的测试要走 `_init()` → `_run.call_deferred()` 的延迟模式

---

## 6. 未完成的工作

### 必须由人来做

**M2 是唯一未通过验收的里程碑。** 标准是「播放头位置与实际听到的声音
偏差 < 1 帧(33ms @30fps),在 macOS 和 Windows 上分别验证」——**必须人耳**。
机器能验的部分(暂停不跳位、seek 后时钟重置、补偿公式)都绿了。

已知会碍事:macOS 上 `AudioServer.get_output_latency()` 实测返回 **0**,
CoreAudio 的真实延迟(通常 10~20ms)没被自动补偿,大概率要调项目设置
`cue/playback/extra_latency_ms`。**这也是不标 1.0 的唯一原因。**

`tests/MANUAL.md` 的 58 项人工检查同理。

### 待办

- **Asset Library 尚未提交**。逐字段的内容、预览图清单、自查表都写好在
  [`docs/asset-library.md`](asset-library.md),提交需要账号。
- **那次 56 分钟渲染挂起的根因不明**。复现不了(单独跑 10 次全过),
  倾向于窗口/GPU 层面的环境问题,但**没有证据,没下结论**。看门狗只是止血。
- **确定性测试在 CI 上跑不了**(runner 无 GPU/显示器),只能本地跑。
  想补的话可以试 `xvfb` + 软件渲染,我没验过。

---

## 7. 如果你要加功能

原计划第 9 节写着一句该反复读的话:

> Cue 是**动画视频项目的支撑工具,不是目的**。如果在写 Cue 的过程中
> 发现自己在给 Cue 加功能而不是在做视频,停下来。

P0 / P1 / P2 全部实现完之后,连续五轮的开发里我**一个"缺功能"都没找到,
全部是 bug**。功能面大概率已经饱和了。

所以建议:**在加任何新功能之前,先拿它做一集真实视频。** 那会一次性覆盖
所有靠读代码推演不出来的问题 —— 已经找到的 9 个 bug 里,有 3 个是
"跑起来"才暴露的(flaky 测试、规模测试、语义推演),而 M2 那条验收
只有戴上耳机才验得了。

真要加,先读 `PLAN.md` 第 5 节的「明确不做」(范围守卫):
音频剪辑、降噪、电平调整、混音、任何写回音频文件的操作 —— 都不做。
Cue 只读音频。

---

## 8. 提交与发布

- 提交信息用 Conventional Commits,scope 固定 `cue`,**一个提交一件事**
- 界面文案和错误提示用中文,代码注释用中文,标识符用英文
- 静态类型必写;字符串名用 `StringName`(`&"marker"`)
- 发版:改 `addons/cue/plugin.cfg` 的 `version` → 写
  [`CHANGELOG.md`](../CHANGELOG.md) → 打带注释的 tag → 推 tag →
  同步更新 `docs/asset-library.md` 里的版本与 download tag

**破坏性变更必须在 CHANGELOG 里显眼地写清楚"旧写法为什么会出问题"**,
不能只写"改了什么"。0.10.0 就有三个 —— 其中一个会影响成片的动画速度。
