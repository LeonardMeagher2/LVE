extends VoxiPlugin

@onready var _toolbar := preload("./Toolbar.tscn").instantiate()
@onready var _options := preload("./Options.tscn").instantiate()
@onready var _tool := preload("./FillTool.tscn").instantiate()

func _ready() -> void:
	name = "FillPlugin"
	_toolbar.toggled.connect(_on_toolbar_toggled)
	add_tool_bar_item(_toolbar)


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
