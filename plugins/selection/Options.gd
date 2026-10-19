extends HBoxContainer

var _settings := preload("./settings.tres")

func _ready() -> void:
	_settings.changed.connect(_sync)
	_sync()
	
func _sync() -> void:
	var mode_buttons := [$replace, $add, $subtract]
	mode_buttons[_settings.mode].button_pressed = true
	$Connected.set_pressed_no_signal(_settings.connected)
	$Connected.visible = _settings.tool == _settings.Tools.WAND
	$Sep.visible = $Connected.visible
	$empty.set_pressed_no_signal(_settings.include_empty)
	# The wand picks a voxel. It has no empty cell option.
	var show_empty := _settings.tool != _settings.Tools.WAND
	for control in [$EmptySep, $empty]:
		control.visible = show_empty
	$Depth.set_pressed_no_signal(_settings.depth_test)
	# The depth test reads the screen shape. The wand picks a voxel.
	$Depth.visible = show_empty


func _on_depth_toggled(toggled_on: bool) -> void:
	_settings.depth_test = toggled_on


func _on_empty_toggled(toggled_on: bool) -> void:
	_settings.include_empty = toggled_on


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
