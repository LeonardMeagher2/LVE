extends VoxelPlugin

## The deform plugin.
##
## It owns the grab and pose tools. It adds their toolbar and option bar, and it
## switches the active tool when the deform tool changes. A tool switch ends an
## open gesture like a release, so the drag commits as one history action.

var _settings := preload("./settings.tres")

@onready var _toolbar: MenuButton = preload("./Toolbar.tscn").instantiate()
@onready var _options := preload("./Options.tscn").instantiate()
@onready var _grab := preload("./GrabTool.tscn").instantiate()
@onready var _pose := preload("./PoseTool.tscn").instantiate()

var _current_tool: Node = null
var _active := false


func _ready() -> void:
	name = "DeformPlugin"
	_toolbar.toggled.connect(_on_toolbar_toggled)
	_settings.tool_changed.connect(_on_tool_changed)
	_options.bind(_settings)
	add_tool_bar_item(_toolbar)
	_select_tool(_settings.tool)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node in [_toolbar, _options, _grab, _pose]:
			if is_instance_valid(node):
				node.free()


## Activates the current deform tool and shows the option bar.
func activate_tool() -> void:
	_active = true
	_toolbar.set_pressed_no_signal(true)
	add_option_bar_item(_options)
	_on_tool_changed(_settings.tool)


## Deactivates the current deform tool and hides the option bar. It ends an open
## gesture like a release.
func deactivate_tool() -> void:
	_active = false
	remove_option_bar_item(_options)
	if _current_tool:
		_current_tool.finish_on_switch()
		remove_editor_node(_current_tool)


func _on_toolbar_toggled(on: bool) -> void:
	if on:
		activate_tool()
	else:
		deactivate_tool()


func _on_tool_changed(tool: int) -> void:
	_select_tool(tool)
	if _active:
		add_editor_node(_current_tool)


func _select_tool(tool: int) -> void:
	if _current_tool:
		# The old tool ends its open gesture like a release before the switch.
		_current_tool.finish_on_switch()
		remove_editor_node(_current_tool)
	match tool:
		_settings.Tools.POSE:
			_current_tool = _pose
		_:
			_current_tool = _grab
