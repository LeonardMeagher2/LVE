extends VoxiPlugin

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


func activate_tool() -> void:
	_toolbar.set_pressed_no_signal(true)
	add_editor_node(_tool)
	add_option_bar_item(_options)

func deactivate_tool() -> void:
	remove_editor_node(_tool)
	remove_option_bar_item(_options)


func _on_settings_changed() -> void:
	if _settings.mode != _active_mode and _brush_tool._stroke_open:
		_brush_tool._cancel_edit()
	_active_mode = _settings.mode
	var next_tool: Node3D = _line_tool if _settings.mode == _settings.BrushMode.LINE else _brush_tool
	if next_tool == _tool:
		return
	remove_editor_node(_tool)
	_tool = next_tool
	if _toolbar.button_pressed:
		add_editor_node(_tool)

func _on_toolbar_toggled(on: bool) -> void:
	if on:
		activate_tool()
	else:
		deactivate_tool()
