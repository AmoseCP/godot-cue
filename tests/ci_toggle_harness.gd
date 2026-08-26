extends SceneTree

## 启用/禁用测试用的 harness 插件,直接改 ProjectSettings。
##
##   godot --headless --path . --script tests/ci_toggle_harness.gd -- on  toggle
##   godot --headless --path . --script tests/ci_toggle_harness.gd -- off
##
## 为什么不用 sed/python:runner 要在 Linux / Windows / macOS 上都能跑,
## 而 Windows runner 上 `python3` 不一定存在、sed 的行为也不一致。
## 用 Godot 自己改自己的配置是唯一三平台一致的做法。

const CUE := "res://addons/cue/plugin.cfg"
const HARNESS := {
	"toggle": "res://tests/toggle_harness/plugin.cfg",
	"edit": "res://tests/edit_harness/plugin.cfg",
}


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("用法:-- on <harness名> | -- off")
		quit(2)
		return

	var enabled := PackedStringArray([CUE])
	if args[0] == "on":
		for i in range(1, args.size()):
			var key := String(args[i])
			if not HARNESS.has(key):
				push_error("未知的 harness:%s(可选:%s)" % [key, ", ".join(HARNESS.keys())])
				quit(2)
				return
			enabled.append(HARNESS[key])
	elif args[0] != "off":
		push_error("第一个参数必须是 on 或 off,得到 %s" % args[0])
		quit(2)
		return

	ProjectSettings.set_setting("editor_plugins/enabled", enabled)
	var err := ProjectSettings.save()
	if err != OK:
		push_error("保存 project.godot 失败,错误码 %d" % err)
		quit(1)
		return
	print("已启用插件:", enabled)
	quit(0)
