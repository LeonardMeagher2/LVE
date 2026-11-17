extends HBoxContainer

## The primitive option bar.
##
## It selects the operation, edits the smooth blend and the shell, edits the
## cone options, and commits or cancels the pending primitives. The shape is
## selected from the primitive toolbar.

var _settings := preload("./PrimitiveSettings.tres")


func _ready() -> void:
	if not _settings.changed.is_connected(_sync):
		_settings.changed.connect(_sync)
	_sync()


func _sync() -> void:
	var op_buttons := [$Op/Add, $Op/Subtract, $Op/Intersect]
	var op: int = _settings.op
	if op < 0 or op >= op_buttons.size():
		op = PrimitiveToolSettings.Op.ADD
	op_buttons[op].button_pressed = true
	$Smooth.set_value_no_signal(_settings.smooth)
	$Shell.set_value_no_signal(_settings.shell)
	$Roundness.visible = _settings.tool != PrimitiveToolSettings.Tools.ELLIPSOID
	$Roundness.set_value_no_signal(_settings.roundness)
	$Cone.visible = _settings.tool == PrimitiveToolSettings.Tools.CONE
	$Cone/SecondRadius.set_value_no_signal(_settings.second_radius)
	$Commit.disabled = not _settings.editing
	$Cancel.disabled = not _settings.editing


func _on_add_pressed() -> void:
	_settings.op = PrimitiveToolSettings.Op.ADD


func _on_subtract_pressed() -> void:
	_settings.op = PrimitiveToolSettings.Op.SUBTRACT


func _on_intersect_pressed() -> void:
	_settings.op = PrimitiveToolSettings.Op.INTERSECT


func _on_smooth_changed(value: float) -> void:
	_settings.smooth = value


func _on_shell_changed(value: float) -> void:
	_settings.shell = int(value)


func _on_roundness_changed(value: float) -> void:
	_settings.roundness = value


func _on_second_radius_changed(value: float) -> void:
	_settings.second_radius = value


func _on_commit_pressed() -> void:
	_settings.commit()


func _on_cancel_pressed() -> void:
	_settings.cancel()
