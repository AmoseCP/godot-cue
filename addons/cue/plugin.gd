@tool
extends EditorPlugin

const AUTOLOAD_NAME := "Cue"
const AUTOLOAD_PATH := "res://addons/cue/runtime/cue.gd"
const PanelScene := preload("res://addons/cue/editor/cue_panel.tscn")

var _panel: Control = null
var _panel_button: Button = null
var _inspector: CueInspectorPlugin = null


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	_panel = PanelScene.instantiate()
	_panel.setup(get_undo_redo())
	_panel_button = add_control_to_bottom_panel(_panel, "Cue")

	_inspector = CueInspectorPlugin.new()
	_inspector.open_requested.connect(_on_inspector_open)
	add_inspector_plugin(_inspector)


func _exit_tree() -> void:
	if _inspector != null:
		remove_inspector_plugin(_inspector)
		_inspector = null
	# 顺序要紧:先摘掉面板再释放,否则底部面板会留下悬挂按钮。
	if _panel != null:
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
		_panel = null
	_panel_button = null
	remove_autoload_singleton(AUTOLOAD_NAME)


## 在文件系统里双击 .tres 的 CueSheet 时接管它。
func _handles(object: Object) -> bool:
	return object is CueSheet


func _edit(object: Object) -> void:
	if _panel != null and object is CueSheet:
		_panel.open_sheet(object as CueSheet)


func _on_inspector_open(sheet: CueSheet) -> void:
	if _panel == null:
		return
	_panel.open_sheet(sheet)
	make_bottom_panel_item_visible(_panel)


func _make_visible(visible: bool) -> void:
	if visible and _panel != null and _panel_button != null:
		make_bottom_panel_item_visible(_panel)
