extends VoxelPlugin

## The eyedropper plugin.
##
## It adds the eyedropper tool button and its tool.

@onready var _toolbar := preload("./Toolbar.tscn").instantiate()
@onready var _tool := preload("./EyedropperTool.tscn").instantiate()

func _ready() -> void:
	name = "EyedropperPlugin"
	_toolbar.toggled.connect(_on_toolbar_toggled)
	add_tool_bar_item(_toolbar)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node in [_toolbar, _tool]:
			if is_instance_valid(node):
				node.free()


## Activates the eyedropper tool.
func activate_tool() -> void:
	_toolbar.set_pressed_no_signal(true)
	add_editor_node(_tool)


## Deactivates the eyedropper tool.
func deactivate_tool() -> void:
	remove_editor_node(_tool)


func _on_toolbar_toggled(on: bool) -> void:
	if on:
		activate_tool()
	else:
		deactivate_tool()
