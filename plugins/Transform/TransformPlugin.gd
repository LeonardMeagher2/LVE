extends VoxiPlugin

var _settings := preload("./settings.tres")

@onready var _toolbar: MenuButton = preload("./Toolbar.tscn").instantiate()
@onready var _options := preload("./Options.tscn").instantiate()

@onready var _move := preload("./tools/MoveTool.tscn").instantiate()
@onready var _rotate := preload("./tools/RotateTool.tscn").instantiate()
@onready var _scale := preload("./tools/ScaleTool.tscn").instantiate()

var _current_tool: Node = null
var _active := false

func _ready() -> void:
	name = "TransformPlugin"
	_toolbar.toggled.connect(_on_toolbar_toggled)
	_settings.tool_changed.connect(_on_tool_changed)
	add_tool_bar_item(_toolbar)


func activate_tool() -> void:
	_active = true
	_toolbar.set_pressed_no_signal(true)
	add_option_bar_item(_options)
	_on_tool_changed(_settings.tool)


func deactivate_tool() -> void:
	_active = false
	remove_option_bar_item(_options)
	if _current_tool:
		remove_editor_node(_current_tool)


func _on_toolbar_toggled(on: bool) -> void:
	if on:
		activate_tool()
	else:
		deactivate_tool()


func _on_tool_changed(tool: int) -> void:
	if not _active:
		return
	if _current_tool:
		remove_editor_node(_current_tool)
	match tool:
		_settings.Tools.MOVE:
			_current_tool = _move
		_settings.Tools.ROTATE:
			_current_tool = _rotate
		_settings.Tools.SCALE:
			_current_tool = _scale
		_:
			_current_tool = null
			push_error("Unknown transform tool %s" % tool)
			return
	add_editor_node(_current_tool)