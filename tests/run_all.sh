#!/usr/bin/env bash
# 一次跑完所有机器可验的测试。
#   tests/run_all.sh [godot 可执行文件路径]
#
# UI 交互部分见 tests/MANUAL.md。

set -uo pipefail

GODOT="${1:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -x "$GODOT" ]; then
	echo "找不到 Godot 可执行文件:$GODOT" >&2
	echo "用法:tests/run_all.sh [godot 路径]" >&2
	exit 2
fi

FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [ -f "$TMP.godot" ] && mv "$TMP.godot" project.godot' EXIT

hr() { printf '\n\033[1m── %s ──\033[0m\n' "$1"; }

# 跑一个 headless 脚本测试,按退出码判成败。
run_script() {
	hr "$1"
	if "$GODOT" --headless --path . --script "$2" > "$TMP/out" 2>&1; then
		grep -E "^=== " "$TMP/out" | sed 's/^/  /'
	else
		grep -E "FAIL|^=== " "$TMP/out" | sed 's/^/  /'
		echo "  ↑ 失败"
		FAIL=1
	fi
}

# 在编辑器里跑一个测试插件。两个 harness 必须分开跑 ——
# toggle_harness 会反复禁用/启用 Cue,和 edit_harness 同时跑会把
# 后者正在操作的面板和 undo 历史掀掉,产生假失败。
run_harness() {
	local title="$1" cfg="$2" tag="$3" frames="$4"
	hr "$title"
	cp project.godot "$TMP/project.godot.bak"
	CUE_HARNESS="$cfg" python3 - <<'PY'
import os
p = 'project.godot'
s = open(p).read()
s = s.replace('enabled=PackedStringArray("res://addons/cue/plugin.cfg")',
              'enabled=PackedStringArray("res://addons/cue/plugin.cfg", "%s")' % os.environ['CUE_HARNESS'])
open(p, 'w').write(s)
PY
	"$GODOT" --headless --editor --path . --quit-after "$frames" > "$TMP/out" 2>&1
	cp "$TMP/project.godot.bak" project.godot
	grep -E "${tag} (RESULT|FAIL)" "$TMP/out" | sed 's/^/  /'
	if ! grep -q "${tag} RESULT PASS" "$TMP/out"; then
		echo "  ↑ 失败"
		FAIL=1
	fi
}

if [ ! -f tests/probe/tone_5min.wav ] || [ ! -f tests/determinism/tone_3s.wav ]; then
	hr "生成测试音频(可再生,不进 git)"
	"$GODOT" --headless --path . --script tests/make_fixtures.gd 2>&1 | grep "写入" | sed 's/^/  /'
	"$GODOT" --headless --import --path . > /dev/null 2>&1
fi

run_script "核心(PCM / 峰值 / 缓存 / 排序 / 吸附)" tests/test_core.gd
run_script "运行时(Cue / CueClock)"                tests/test_runtime.gd
run_script "导入器(Rhubarb / TextGrid)"            tests/test_import.gd
run_script "多音频片段(D10′)"                     tests/test_segments.gd
run_script "轨道泳道几何与折叠"                     tests/test_lanes.gd
run_script "振幅包络与剧本骨架生成"                 tests/test_export.gd
run_script "字幕文本对照"                           tests/test_subtitles.gd
run_script "MP3 / OGG 经 ffmpeg 预转"               tests/test_ffmpeg.gd
run_script "FFT 与频谱图"                           tests/test_spectrogram.gd
run_script "规模验证(一集体量)"                   tests/test_scale.gd

run_harness "编辑器:插件反复启停无泄漏" \
	"res://tests/toggle_harness/plugin.cfg" TOGGLE 500
run_harness "编辑器:undo / redo / 持久化 / 批量导入" \
	"res://tests/edit_harness/plugin.cfg" EDIT 800

hr "确定性:双次渲染逐帧哈希"
if ./tests/determinism.sh "$GODOT" > "$TMP/out" 2>&1; then
	grep -E "PASS:|确定性测试" "$TMP/out" | sed 's/^/  /'
else
	sed 's/^/  /' "$TMP/out"
	FAIL=1
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
	printf '\033[1;32m全部通过\033[0m\n'
else
	printf '\033[1;31m有测试失败\033[0m\n'
	exit 1
fi
