extends VoxiPlugin

const ToolBar = preload("./Toolbar.tscn")
const Options = preload("./Options.tscn")
const BrushTool = preload("./BrushTool.tscn")

@onready var _toolbar := ToolBar.instantiate()
@onready var _options := Options.instantiate()
@onready var _tool := BrushTool.instantiate()


func _ready() -> void:
	name = "BrushPlugin"
	_toolbar.toggled.connect(_on_toolbar_toggled)
	add_tool_bar_item(_toolbar)
	add_option_bar_item(_options)
	activate_tool()


func activate_tool() -> void:
	_toolbar.set_pressed_no_signal(true)
	add_editor_node(_tool)
	add_option_bar_item(_options)

func deactivate_tool() -> void:
	remove_editor_node(_tool)
	remove_option_bar_item(_options)

func _on_toolbar_toggled(on: bool) -> void:
	if on:
		activate_tool()
	else:
		deactivate_tool()
