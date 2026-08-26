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
## 示例 sheet 都是 30fps,渲染帧率必须跟着钉死。
FPS=30
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
	# --fixed-fps 必须显式传:4.7.2 实测,项目设置 editor/movie_writer/fps
	# 在独立运行 --write-movie 时[b]不生效[/b],默认按 60fps 录,
	# 和示例 sheet 的 30fps 对不上。
	( cd "$ROOT" && "$GODOT" --path . --fixed-fps "$FPS" \
		--write-movie "$out/f.png" "$scene" ) > "$out/render.log" 2>&1
	if [ -f "$ROOT/tests/determinism/fire_log.txt" ]; then
		cp "$ROOT/tests/determinism/fire_log.txt" "$out/fire_log.txt"
	fi
}

check_scene() {
	local scene="$1"
	# 每个场景一对独立目录 —— 共用目录的话,后面的场景会把前一个失败的
	# 现场覆盖掉,事后完全没法取证(这个坑踩过一次)。
	local slug
	slug=$(echo "$scene" | tr '/.' '__')
	local A="$ROOT/tests/render_a/$slug" B="$ROOT/tests/render_b/$slug"
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
	local first_bad=""
	for pa in "$A"/*.png; do
		local name pb ha hb
		name=$(basename "$pa"); pb="$B/$name"
		if [ ! -f "$pb" ]; then
			echo "  FAIL:$name 只在第 1 次渲染中存在"; bad=1; continue
		fi
		ha=$(shasum -a 256 "$pa" | cut -d' ' -f1)
		hb=$(shasum -a 256 "$pb" | cut -d' ' -f1)
		if [ "$ha" != "$hb" ]; then
			if [ -z "$first_bad" ]; then
				first_bad="$name"
				echo "  FAIL:首次分歧在 $name"
				echo "        A=$ha"
				echo "        B=$hb"
			fi
			bad=$((bad + 1))
		fi
	done
	if [ -n "$first_bad" ]; then
		echo "  共 $bad / $na 帧不同;现场保留在 $A 与 $B"
		local ua ub
		ua=$(find "$A" -name '*.png' -exec shasum -a 256 {} \; | cut -d' ' -f1 | sort -u | wc -l | tr -d ' ')
		ub=$(find "$B" -name '*.png' -exec shasum -a 256 {} \; | cut -d' ' -f1 | sort -u | wc -l | tr -d ' ')
		echo "  A 有 $ua 个不同哈希,B 有 $ub 个(都应等于 $na;小于说明那一次渲染中途卡住了)"
	fi

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

# ── 跨帧率回归 ──────────────────────────────────────────────────────
# CueSheet 的 fps 是编辑器概念,和影片实际帧率没有强制关系。
# 拿 sheet.fps 当离线时钟的除数,60fps 渲染 30fps 的 sheet 时会快一倍。
# 这里换个帧率再渲一次,标记触发的[b]秒数[/b]必须对得上。
echo ""
echo "── 跨帧率:标记触发时刻不随渲染帧率漂移 ──"
cross_fps() {
	local fps="$1" out="$ROOT/tests/render_fps$1"
	rm -rf "$out"; mkdir -p "$out"
	rm -f "$ROOT/tests/determinism/fire_log.txt"
	( cd "$ROOT" && "$GODOT" --path . --fixed-fps "$fps" \
		--write-movie "$out/f.png" tests/determinism/main.tscn ) > "$out/render.log" 2>&1
	grep -oE "@f[0-9]+" "$ROOT/tests/determinism/fire_log.txt" 2>/dev/null | tr -d '@f' | tr '\n' ' '
}
FR30=$(cross_fps 30)
FR60=$(cross_fps 60)
echo "  30fps 触发帧号:$FR30"
echo "  60fps 触发帧号:$FR60"
# 触发帧号以 sheet 的 fps 计,所以两者应当几乎相同(允许 ±1 的采样差)
ok_cross=1
i=0
for a in $FR30; do
	b=$(echo $FR60 | cut -d' ' -f$((i + 1)))
	if [ -n "$b" ] && [ "$(( a > b ? a - b : b - a ))" -gt 1 ]; then ok_cross=0; fi
	i=$((i + 1))
done
if [ "$ok_cross" -eq 1 ]; then
	echo "  PASS:换帧率后触发时刻没有漂移"
else
	echo "  FAIL:换帧率后标记触发时刻变了 —— 离线时钟用错了帧率"
	FAIL=1
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
	echo "确定性测试全部通过"
else
	echo "确定性测试失败 —— 运行时逻辑里有非确定性的时间源。"
	exit 1
fi
