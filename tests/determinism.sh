#!/usr/bin/env bash
# M4 验收:同一场景用 --write-movie 渲染两次,PNG 序列必须逐帧字节一致。
#
# 用法:  tests/determinism.sh [godot 可执行文件路径]
#
# 这是整个插件最重要的一条测试。它失败不是"小 bug",是架构问题 ——
# 说明运行时逻辑里混进了非确定性的时间源。
#
# 两个场景都测:
#   tests/determinism/main.tscn   —— 纯 Cue.at() / Cue.time()
#   examples/mouth_sync/main.tscn —— 再加上 CueMouthShape 驱动贴图切换
#   examples/multi_voice/main.tscn —— 多音频片段(D10′),多个播放器同时在跑

set -uo pipefail

GODOT="${1:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCENES=("tests/determinism/main.tscn" "examples/mouth_sync/main.tscn" "examples/multi_voice/main.tscn")

if [ ! -x "$GODOT" ]; then
	echo "找不到 Godot 可执行文件:$GODOT" >&2
	echo "用法:tests/determinism.sh [godot 路径]" >&2
	exit 2
fi

# fixture 是可再生的,不进 git
if [ ! -f "$ROOT/tests/determinism/tone_3s.wav" ]; then
	echo "生成测试音频..."
	( cd "$ROOT" && "$GODOT" --headless --path . --script tests/make_fixtures.gd > /dev/null 2>&1 )
	( cd "$ROOT" && "$GODOT" --headless --path . --script tests/determinism/make_assets.gd > /dev/null 2>&1 )
	( cd "$ROOT" && "$GODOT" --headless --import --path . > /dev/null 2>&1 )
fi

FAIL=0

render() {
	local scene="$1" out="$2"
	rm -rf "$out"; mkdir -p "$out"
	( cd "$ROOT" && "$GODOT" --path . --write-movie "$out/f.png" "$scene" ) > "$out/render.log" 2>&1
	if [ -f "$ROOT/tests/determinism/fire_log.txt" ]; then
		cp "$ROOT/tests/determinism/fire_log.txt" "$out/fire_log.txt"
	fi
}

check_scene() {
	local scene="$1"
	local A="$ROOT/tests/render_a" B="$ROOT/tests/render_b"
	echo ""
	echo "── $scene ──"
	rm -f "$ROOT/tests/determinism/fire_log.txt"
	echo "  第 1 次渲染..."; render "$scene" "$A"
	rm -f "$ROOT/tests/determinism/fire_log.txt"
	echo "  第 2 次渲染..."; render "$scene" "$B"

	local na nb
	na=$(find "$A" -name '*.png' | wc -l | tr -d ' ')
	nb=$(find "$B" -name '*.png' | wc -l | tr -d ' ')
	if [ "$na" -ne "$nb" ] || [ "$na" -eq 0 ]; then
		echo "  FAIL:两次渲染帧数不一致(A=$na B=$nb),或没有输出"
		FAIL=1
		return
	fi

	local bad=0
	for pa in "$A"/*.png; do
		local name pb ha hb
		name=$(basename "$pa"); pb="$B/$name"
		if [ ! -f "$pb" ]; then
			echo "  FAIL:$name 只在第 1 次渲染中存在"; bad=1; continue
		fi
		ha=$(shasum -a 256 "$pa" | cut -d' ' -f1)
		hb=$(shasum -a 256 "$pb" | cut -d' ' -f1)
		if [ "$ha" != "$hb" ]; then
			echo "  FAIL:$name 哈希不同"
			echo "        A=$ha"
			echo "        B=$hb"
			bad=1
		fi
	done

	# 自查:每帧都该不一样,否则"两次一致"可能只是"全是空白帧"
	local uniq
	uniq=$(find "$A" -name '*.png' -exec shasum -a 256 {} \; | cut -d' ' -f1 | sort -u | wc -l | tr -d ' ')
	if [ "$uniq" -lt "$na" ]; then
		echo "  注意:$na 帧里只有 $uniq 个不同哈希,画面可能没在变"
	fi

	if [ -f "$A/fire_log.txt" ] && [ -f "$B/fire_log.txt" ]; then
		if ! diff -q "$A/fire_log.txt" "$B/fire_log.txt" > /dev/null; then
			echo "  FAIL:标记触发帧号在两次渲染中不同"
			diff "$A/fire_log.txt" "$B/fire_log.txt" || true
			bad=1
		else
			sed 's/^/        /' "$A/fire_log.txt"
		fi
	fi

	if [ "$bad" -eq 0 ]; then
		echo "  PASS:$na 帧逐帧 SHA256 完全一致($uniq 个互不相同的哈希)"
	else
		FAIL=1
	fi
}

for s in "${SCENES[@]}"; do
	check_scene "$s"
done

echo ""
if [ "$FAIL" -eq 0 ]; then
	echo "确定性测试全部通过"
else
	echo "确定性测试失败 —— 运行时逻辑里有非确定性的时间源。"
	exit 1
fi
