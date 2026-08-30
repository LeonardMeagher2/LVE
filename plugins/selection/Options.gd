extends HBoxContainer

var _settings := preload("./settings.tres")

func _ready() -> void:
	$Connected.set_pressed_no_signal(_settings.connected)
	_settings.tool_changed.connect(_on_tool_changed)
	_on_tool_changed(_settings.tool)
	
func _on_tool_changed(tool: int) -> void:
	$Connected.visible = tool == _settings.Tools.WAND


func _on_connected_toggled(toggled_on: bool) -> void:
	_settings.connected = toggled_on


func _on_clear_pressed() -> void:
	State.clear_selection()


func _on_replace_toggled(toggled_on: bool) -> void:
	if toggled_on:
		_settings.mode = _settings.SelectMode.REPLACE


func _on_add_toggled(toggled_on: bool) -> void:
	if toggled_on:
		_settings.mode = _settings.SelectMode.ADD


func _on_subtract_toggled(toggled_on: bool) -> void:
	if toggled_on:
		_settings.mode = _settings.SelectMode.SUBTRACT
