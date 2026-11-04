extends VoxelPlugin

## The terrain plugin.
##
## It owns the terrain tool and adds its toolbar and option bar. A tool switch
## ends an open stroke like a release, so the queued work commits as one history
## action.

var _settings := preload("./settings.tres")

@onready var _toolbar := preload("./Toolbar.tscn").instantiate()
@onready var _options := preload("./Options.tscn").instantiate()
@onready var _terrain_tool := preload("./TerrainTool.tscn").instantiate()

var _tool: Node3D
var _active := false


func _ready() -> void:
	name = "TerrainPlugin"
	_tool = _terrain_tool
	_toolbar.toggled.connect(_on_toolbar_toggled)
	_settings.tool_changed.connect(_on_tool_changed)
	_options.bind(_settings)
	add_tool_bar_item(_toolbar)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node in [_toolbar, _options, _terrain_tool]:
			if is_instance_valid(node):
				node.free()


## Activates the terrain tool and shows its option bar.
func activate_tool() -> void:
	_active = true
	_toolbar.set_pressed_no_signal(true)
	add_editor_node(_tool)
	add_option_bar_item(_options)


## Deactivates the terrain tool and hides its option bar. It ends an open stroke
## like a release.
func deactivate_tool() -> void:
	_active = false
	# A switch ends the stroke like a release. Escape and a context change keep
	# their rollback.
	_tool.finish_on_switch()
	remove_editor_node(_tool)
	remove_option_bar_item(_options)


func _on_toolbar_toggled(on: bool) -> void:
	if on:
		activate_tool()
	else:
		deactivate_tool()


func _on_tool_changed(_tool_id: int) -> void:
	# The single tool instance keeps the stroke settings it captured. A tool
	# change still ends the stroke like a release.
	if _tool:
		_tool.finish_on_switch()
