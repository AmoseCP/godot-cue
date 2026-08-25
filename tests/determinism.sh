#!/usr/bin/env bash
# M4 验收:同一场景用 --write-movie 渲染两次,PNG 序列必须逐帧字节一致。
#
# 用法:  tests/determinism.sh [godot 可执行文件路径]
#
# 这是整个插件最重要的一条测试。它失败不是"小 bug",是架构问题 ——
# 说明运行时逻辑里混进了非确定性的时间源。

set -euo pipefail

GODOT="${1:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCENE="tests/determinism/main.tscn"
A="$ROOT/tests/render_a"
B="$ROOT/tests/render_b"

if [ ! -x "$GODOT" ]; then
	echo "找不到 Godot 可执行文件:$GODOT" >&2
	echo "用法:tests/determinism.sh [godot 路径]" >&2
	exit 2
fi

render() {
	local out="$1" log="$2"
	rm -rf "$out"; mkdir -p "$out"
	( cd "$ROOT" && "$GODOT" --path . --write-movie "$out/f.png" "$SCENE" ) > "$log" 2>&1
	cp "$ROOT/tests/determinism/fire_log.txt" "$out/fire_log.txt"
}

echo "第 1 次渲染..."
render "$A" "$A/render.log"
echo "第 2 次渲染..."
render "$B" "$B/render.log"

na=$(find "$A" -name '*.png' | wc -l | tr -d ' ')
nb=$(find "$B" -name '*.png' | wc -l | tr -d ' ')
echo "帧数:A=$na  B=$nb"
if [ "$na" -ne "$nb" ] || [ "$na" -eq 0 ]; then
	echo "FAIL:两次渲染帧数不一致(或没有输出)"
	exit 1
fi

# 逐帧 SHA256 比对
fail=0
for pa in "$A"/*.png; do
	name=$(basename "$pa")
	pb="$B/$name"
	if [ ! -f "$pb" ]; then
		echo "FAIL:$name 只在第 1 次渲染中存在"; fail=1; continue
	fi
	ha=$(shasum -a 256 "$pa" | cut -d' ' -f1)
	hb=$(shasum -a 256 "$pb" | cut -d' ' -f1)
	if [ "$ha" != "$hb" ]; then
		echo "FAIL:$name 哈希不同"
		echo "      A=$ha"
		echo "      B=$hb"
		fail=1
	fi
done

# 标记触发帧号也必须一致
if ! diff -q "$A/fire_log.txt" "$B/fire_log.txt" > /dev/null; then
	echo "FAIL:标记触发帧号在两次渲染中不同"
	diff "$A/fire_log.txt" "$B/fire_log.txt" || true
	fail=1
else
	echo "标记触发帧号一致:"
	sed 's/^/      /' "$A/fire_log.txt"
fi

if [ "$fail" -eq 0 ]; then
	echo "PASS:$na 帧逐帧 SHA256 完全一致"
else
	echo "确定性测试失败 —— 运行时逻辑里有非确定性的时间源。"
	exit 1
fi
