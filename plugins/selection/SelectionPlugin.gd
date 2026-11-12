extends VoxelPlugin

## The selection plugin.
##
## It owns the box, wand, and lasso selection tools. It shows the shared
## selection preview and the selection option bar.

var _settings := preload("./settings.tres")

@onready var _toolbar:MenuButton = preload("./Toolbar.tscn").instantiate()
@onready var _options := preload("./Options.tscn").instantiate()
@onready var _selection := preload("./SelectionPreview.tscn").instantiate()

# Tools
@onready var _box := preload("./tools/BoxSelectTool.tscn").instantiate()
@onready var _wand := preload("./tools/WandSelectTool.tscn").instantiate()
@onready var _lasso := preload("./tools/LassoSelectTool.tscn").instantiate()

var _current_tool:Node = null
## Whether the selection plugin owns the pointer. A tool change while another
## plugin is active must not add a second tool node to the viewport.
var _active := false

func _ready() -> void:
	name = "SelectionPlugin"
	State.selection_changed.connect(_on_selection_changed)
	_toolbar.toggled.connect(_on_toolbar_toggled)
	_settings.tool_changed.connect(_on_tool_changed)
	add_tool_bar_item(_toolbar)
	add_editor_node(_selection)
	
	_on_selection_changed()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node in [_toolbar, _options, _selection, _box, _wand, _lasso]:
			if is_instance_valid(node):
				node.free()


func _on_selection_changed() -> void:
	# A streaming wand publishes a growing selection. Route it through the
	# progressive path, so a new snapshot cannot cancel the outline that is
	# already building. Every other caller keeps the strict latest-only path.
	var progressive: bool = _wand != null and is_instance_valid(_wand) and _wand.is_streaming()
	_selection.show_selection(State.selection, progressive)


## Activates the current selection tool and shows the option bar.
func activate_tool() -> void:
	_active = true
	_toolbar.set_pressed_no_signal(true)
	add_option_bar_item(_options)
	_on_tool_changed(_settings.tool)


## Deactivates the current selection tool and hides the option bar. A held Box
## or Lasso drag applies its outline before the detach.
func deactivate_tool() -> void:
	_active = false
	remove_option_bar_item(_options)
	if _current_tool:
		# A held Box or Lasso drag applies its current outline as a release would
		# before the detach. A pending calculation finishes after it.
		_current_tool.finish_on_switch()
		remove_editor_node(_current_tool)


func _on_toolbar_toggled(on: bool) -> void:
	if on:
		activate_tool()
	else:
		deactivate_tool()

func _on_tool_changed(tool: int):
	if not _active:
		return
	if _current_tool:
		_current_tool.finish_on_switch()
		remove_editor_node(_current_tool)
		_current_tool = null
	match tool:
		_settings.Tools.BOX:
			_current_tool = _box
		_settings.Tools.WAND:
			_current_tool = _wand
		_settings.Tools.LASSO:
			_current_tool = _lasso
	add_editor_node(_current_tool)
