extends VoxelPlugin

## The symmetry plugin.
##
## It adds the symmetry tool and its option bar. The symmetry tool toggles the
## mirror axes and moves the symmetry origin.

@onready var _toolbar := preload("./Toolbar.tscn").instantiate()
@onready var _options := preload("./Options.tscn").instantiate()
@onready var _tool := preload("./SymmetryTool.tscn").instantiate()


func _ready() -> void:
	name = "SymmetryPlugin"
	_toolbar.toggled.connect(_on_toolbar_toggled)
	add_tool_bar_item(_toolbar)
	add_editor_node(_tool)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node in [_toolbar, _options, _tool]:
			if is_instance_valid(node):
				node.free()


## Activates the symmetry tool and shows its option bar.
func activate_tool() -> void:
	_toolbar.set_pressed_no_signal(true)
	_tool.active = true
	add_option_bar_item(_options)


## Deactivates the symmetry tool and hides its option bar.
func deactivate_tool() -> void:
	_tool.active = false
	remove_option_bar_item(_options)


func _on_toolbar_toggled(on: bool) -> void:
	if on:
		activate_tool()
	else:
		deactivate_tool()
