extends VoxelPlugin

## The paint plugin.
##
## It owns the paintbrush, the bucket fill, and the spray can. It adds their
## toolbar and option bar, and it switches the active tool when the paint tool
## changes. A tool switch ends an open stroke like a release, so the queued work
## commits as one history action.

var _settings := preload("./settings.tres")

@onready var _toolbar: MenuButton = preload("./Toolbar.tscn").instantiate()
@onready var _options := preload("./Options.tscn").instantiate()
@onready var _paintbrush_tool := preload("./PaintBrushTool.tscn").instantiate()
@onready var _fill_tool := preload("./FillTool.tscn").instantiate()
@onready var _spray_tool := preload("./SprayTool.tscn").instantiate()

var _tool: Node3D
var _active := false


func _ready() -> void:
	name = "PaintPlugin"
	_toolbar.toggled.connect(_on_toolbar_toggled)
	_settings.tool_changed.connect(_on_tool_changed)
	add_tool_bar_item(_toolbar)
	_set_tool(_settings.tool)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node in [_toolbar, _options, _paintbrush_tool, _fill_tool, _spray_tool]:
			if is_instance_valid(node):
				node.free()


## Activates the current paint tool and shows its option bar.
func activate_tool() -> void:
	_active = true
	_toolbar.set_pressed_no_signal(true)
	add_editor_node(_tool)
	add_option_bar_item(_options)


## Deactivates the current paint tool and hides its option bar. It ends an open
## stroke like a release.
func deactivate_tool() -> void:
	_active = false
	# A switch ends the stroke like a release: the queued centers are stamped and
	# the stroke commits as one history action. Escape and a context change keep
	# their rollback.
	_tool.finish_on_switch()
	remove_editor_node(_tool)
	remove_option_bar_item(_options)


func _on_toolbar_toggled(on: bool) -> void:
	if on:
		activate_tool()
	else:
		deactivate_tool()


func _on_tool_changed(tool: int) -> void:
	if _tool:
		# The old tool ends its open stroke like a release before the switch.
		_tool.finish_on_switch()
		remove_editor_node(_tool)
	_set_tool(tool)
	if _active:
		add_editor_node(_tool)


func _set_tool(tool: int) -> void:
	match tool:
		_settings.Tools.FILL:
			_tool = _fill_tool
		_settings.Tools.SPRAY:
			_tool = _spray_tool
		_:
			_tool = _paintbrush_tool
