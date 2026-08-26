#!/usr/bin/env bash
# 一次跑完所有机器可验的测试。
#
#   tests/run_all.sh [godot 可执行文件路径] [--skip-render]
#
# --skip-render 跳过离线渲染那部分(确定性测试)。CI 的 Linux/Windows runner
# 没有 GPU/显示器,渲染跑不起来,但其余套件照常验。
#
# UI 交互部分见 tests/MANUAL.md。

set -uo pipefail

GODOT=""
SKIP_RENDER=0
for arg in "$@"; do
	case "$arg" in
		--skip-render) SKIP_RENDER=1 ;;
		*) GODOT="$arg" ;;
	esac
done
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -x "$GODOT" ] && ! command -v "$GODOT" > /dev/null 2>&1; then
	echo "找不到 Godot 可执行文件:$GODOT" >&2
	echo "用法:tests/run_all.sh [godot 路径] [--skip-render]" >&2
	exit 2
fi

FAIL=0
SKIPPED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

hr() { printf '\n\033[1m── %s ──\033[0m\n' "$1"; }

# 跑一个 headless 脚本测试。
#
# [b]不能只看退出码。[/b] 实测:GDScript 解析错误、类型错误、甚至脚本文件
# 根本不存在,Godot 都以 [b]0[/b] 退出。只看退出码的话,一个编译不过的
# 测试文件会被当成"通过" —— 那时套件是全绿的,而测试根本没跑。
# 所以必须确认结果行真的出现了,并且失败数为 0。
run_script() {
	hr "$1"
	local script="$2"
	if [ ! -f "$script" ]; then
		echo "  ↑ 失败:找不到测试脚本 $script"
		FAIL=1
		return
	fi
	"$GODOT" --headless --path . --script "$script" > "$TMP/out" 2>&1
	local code=$?
	local line
	line=$(grep -E "^=== [0-9]+ 通过 / [0-9]+ 失败( / [0-9]+ 跳过)? ===$" "$TMP/out" | tail -1)
	if [ -z "$line" ]; then
		echo "  ↑ 失败:测试没有产出结果行(退出码 $code) —— 多半是脚本没跑起来"
		grep -E "SCRIPT ERROR|Parse Error|^ERROR" "$TMP/out" | head -5 | sed 's/^/     /'
		FAIL=1
		return
	fi
	echo "  $line"
	# 跳过不算失败,但必须显眼 —— 「因为缺依赖所以没测」和「测过了」
	# 在汇总行里长得太像,CI 上尤其容易误判为已覆盖。
	if echo "$line" | grep -q "跳过"; then
		grep -E "跳过" "$TMP/out" | head -2 | sed "s/^/  /"
		SKIPPED=1
	fi
	if ! echo "$line" | grep -q "/ 0 失败"; then
		grep -E "  FAIL" "$TMP/out" | head -10 | sed 's/^/  /'
		echo "  ↑ 失败"
		FAIL=1
	elif [ "$code" -ne 0 ]; then
		echo "  ↑ 失败:结果行显示全过,但退出码是 $code"
		FAIL=1
	fi
}

# 在编辑器里跑一个测试插件。
#
# 两个 harness 必须分开跑 —— toggle_harness 会反复禁用/启用 Cue,
# 和 edit_harness 同时跑会把后者正在操作的面板和 undo 历史掀掉,产生假失败。
#
# 启停插件用 GDScript 改 ProjectSettings,不用 sed/python:
# Windows runner 上 python3 不一定存在,sed 行为也不一致。
run_harness() {
	local title="$1" key="$2" tag="$3" frames="$4"
	hr "$title"
	"$GODOT" --headless --path . --script tests/ci_toggle_harness.gd -- on "$key" \
		> "$TMP/toggle" 2>&1
	"$GODOT" --headless --editor --path . --quit-after "$frames" > "$TMP/out" 2>&1
	"$GODOT" --headless --path . --script tests/ci_toggle_harness.gd -- off \
		>> "$TMP/toggle" 2>&1

	local line
	line=$(grep -E "${tag} RESULT" "$TMP/out" | tail -1)
	if [ -z "$line" ]; then
		echo "  ↑ 失败:harness 没有产出结果行 —— 多半是插件没加载起来"
		grep -E "SCRIPT ERROR|Parse Error" "$TMP/out" | head -5 | sed 's/^/     /'
		FAIL=1
		return
	fi
	echo "  $line"
	if ! echo "$line" | grep -q "RESULT PASS"; then
		grep -E "${tag} FAIL" "$TMP/out" | head -10 | sed 's/^/  /'
		FAIL=1
	fi
}

hr "准备:导入项目"
# 导两次:第一次建立全局类缓存,第二次才能让所有 class_name 互相解析。
"$GODOT" --headless --import --path . > "$TMP/import1" 2>&1
"$GODOT" --headless --import --path . > "$TMP/import2" 2>&1
if grep -qE "SCRIPT ERROR|Parse Error" "$TMP/import2"; then
	echo "  ↑ 失败:导入阶段就有脚本错误"
	grep -E "SCRIPT ERROR|Parse Error" "$TMP/import2" | head -10 | sed 's/^/     /'
	FAIL=1
else
	echo "  导入干净"
fi

if [ ! -f tests/probe/tone_5min.wav ] || [ ! -f tests/determinism/tone_3s.wav ]; then
	hr "生成测试音频(可再生,不进 git)"
	"$GODOT" --headless --path . --script tests/make_fixtures.gd 2>&1 | grep "写入" | sed 's/^/  /'
	"$GODOT" --headless --path . --script tests/determinism/make_assets.gd > /dev/null 2>&1
	"$GODOT" --headless --import --path . > /dev/null 2>&1
fi

run_script "核心(PCM / 峰值 / 缓存 / 排序 / 吸附)" tests/test_core.gd
run_script "运行时(Cue / CueClock)"                tests/test_runtime.gd
run_script "导入器(Rhubarb / TextGrid)"            tests/test_import.gd
run_script "多音频片段(D10′)"                     tests/test_segments.gd
run_script "轨道泳道几何与折叠"                     tests/test_lanes.gd
run_script "波形视图几何与命中测试"                 tests/test_geometry.gd
run_script "振幅包络与剧本骨架生成"                 tests/test_export.gd
run_script "字幕文本对照"                           tests/test_subtitles.gd
run_script "MP3 / OGG 经 ffmpeg 预转"               tests/test_ffmpeg.gd
run_script "FFT 与频谱图"                           tests/test_spectrogram.gd
run_script "规模验证(一集体量)"                   tests/test_scale.gd

run_harness "编辑器:插件反复启停无泄漏" toggle TOGGLE 500
run_harness "编辑器:undo / redo / 持久化 / 批量导入" edit EDIT 900

if [ "$SKIP_RENDER" -eq 1 ]; then
	hr "确定性:双次渲染逐帧哈希"
	echo "  跳过(--skip-render):这一项需要真实渲染,无 GPU/显示器的环境跑不了"
else
	hr "确定性:双次渲染逐帧哈希"
	if ./tests/determinism.sh "$GODOT" > "$TMP/out" 2>&1; then
		grep -E "PASS:|确定性测试" "$TMP/out" | sed 's/^/  /'
	else
		sed 's/^/  /' "$TMP/out"
		FAIL=1
	fi
fi

echo ""
if [ "$SKIPPED" -eq 1 ]; then
	printf '\033[1;33m注意:有套件因缺少可选依赖跳过了部分断言(见上)\033[0m\n'
fi
if [ "$FAIL" -eq 0 ]; then
	printf '\033[1;32m全部通过\033[0m\n'
else
	printf '\033[1;31m有测试失败\033[0m\n'
	exit 1
fi
