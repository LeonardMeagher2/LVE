extends VoxelPlugin

## The brush plugin.
##
## It owns the brush tool and the line tool. It adds their toolbar and option
## bar, and it switches the active tool when the brush mode changes.

@onready var _toolbar := preload("./Toolbar.tscn").instantiate()
@onready var _options := preload("./Options.tscn").instantiate()
@onready var _brush_tool := preload("./BrushTool.tscn").instantiate()
@onready var _line_tool := preload("./LineTool.tscn").instantiate()
var _tool: Node3D
var _settings := preload("./settings.tres")
var _active_mode := 0


func _ready() -> void:
	name = "BrushPlugin"
	_tool = _brush_tool
	_active_mode = _settings.mode
	_toolbar.toggled.connect(_on_toolbar_toggled)
	_settings.changed.connect(_on_settings_changed)
	add_tool_bar_item(_toolbar)
	add_option_bar_item(_options)
	activate_tool()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node in [_toolbar, _options, _brush_tool, _line_tool]:
			if is_instance_valid(node):
				node.free()


## Activates the brush tool and shows its option bar.
func activate_tool() -> void:
	_toolbar.set_pressed_no_signal(true)
	add_editor_node(_tool)
	add_option_bar_item(_options)

## Deactivates the brush tool and hides its option bar. It ends an open stroke
## like a release.
func deactivate_tool() -> void:
	# A switch ends the stroke like a release: the queued centers are stamped and
	# the stroke commits as one history action. Escape and a context change keep
	# their rollback.
	_tool.finish_on_switch()
	remove_editor_node(_tool)
	remove_option_bar_item(_options)


func _on_settings_changed() -> void:
	var mode_changed := _settings.mode != _active_mode
	_active_mode = _settings.mode
	var next_tool: Node3D = _line_tool if _settings.mode == _settings.BrushMode.LINE else _brush_tool
	if next_tool == _tool:
		# The same instance keeps the tool. A mode change still ends the stroke with
		# the mode and material it captured at its start.
		if mode_changed:
			_tool.finish_on_switch()
		return
	_tool.finish_on_switch()
	remove_editor_node(_tool)
	_tool = next_tool
	if _toolbar.button_pressed:
		add_editor_node(_tool)

func _on_toolbar_toggled(on: bool) -> void:
	if on:
		activate_tool()
	else:
		deactivate_tool()
