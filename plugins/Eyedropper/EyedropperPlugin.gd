extends VoxiPlugin

const ToolBar = preload("./Toolbar.tscn")
const Tool = preload("./EyedropperTool.tscn")

@onready var _toolbar = ToolBar.instantiate()
@onready var _tool = Tool.instantiate()

func _ready() -> void:
	name = "EyedropperPlugin"
	_toolbar.toggled.connect(_on_toolbar_toggled)
	add_tool_bar_item(_toolbar)


func activate_tool() -> void:
	_toolbar.set_pressed_no_signal(true)
	add_editor_node(_tool)


func deactivate_tool() -> void:
	remove_editor_node(_tool)


func _on_toolbar_toggled(on: bool) -> void:
	if on:
		activate_tool()
	else:
		deactivate_tool()
