extends ConfirmationDialog

## The exact-value dialog for the transform tools.
##
## It edits one scale, move, or rotate value. It emits [signal values_changed]
## while the user edits, so the tool previews the value.

## Emitted when one dialog value changes. The state holds the values, the axis,
## and the uniform flag.
signal values_changed(state: Dictionary)

## The scale dialog mode.
const MODE_SCALE := 0
## The move dialog mode.
const MODE_MOVE := 1
## The rotate dialog mode.
const MODE_ROTATE := 2

## The state key of the values.
const KEY_VALUES := "values"
## The state key of the axis.
const KEY_AXIS := "axis"
## The state key of the uniform flag.
const KEY_UNIFORM := "uniform"

var _settings := preload("../settings.tres")
var _mode := MODE_SCALE
var _updating := false


func _ready() -> void:
	%ScaleX.value_changed.connect(_on_scale_x_changed)
	%ScaleY.value_changed.connect(_on_scale_y_changed)
	%ScaleZ.value_changed.connect(_on_scale_z_changed)
	%Uniform.toggled.connect(_on_uniform_toggled)
	%MoveX.value_changed.connect(_on_move_changed)
	%MoveY.value_changed.connect(_on_move_changed)
	%MoveZ.value_changed.connect(_on_move_changed)
	%AngleX.value_changed.connect(_on_rotate_changed)
	%AngleY.value_changed.connect(_on_rotate_changed)
	%AngleZ.value_changed.connect(_on_rotate_changed)
	_settings.changed.connect(_sync_uniform)
	_sync_uniform()


## Shows the dialog in scale mode with one value.
func open_for_scale(value: Vector3) -> void:
	_mode = MODE_SCALE
	title = "Scale"
	%ScaleRow.visible = true
	%MoveRow.visible = false
	%RotateRow.visible = false
	_updating = true
	%ScaleX.set_value_no_signal(value.x)
	%ScaleY.set_value_no_signal(value.y)
	%ScaleZ.set_value_no_signal(value.z)
	%Uniform.set_pressed_no_signal(_settings.uniform)
	_updating = false


## Shows the dialog in move mode with one offset.
func open_for_move(offset: Vector3) -> void:
	_mode = MODE_MOVE
	title = "Move"
	%ScaleRow.visible = false
	%MoveRow.visible = true
	%RotateRow.visible = false
	_updating = true
	%MoveX.set_value_no_signal(offset.x)
	%MoveY.set_value_no_signal(offset.y)
	%MoveZ.set_value_no_signal(offset.z)
	_updating = false


## Shows the dialog in rotate mode with one angle in degrees.
func open_for_rotate(angles_deg: Vector3) -> void:
	_mode = MODE_ROTATE
	title = "Rotate"
	%ScaleRow.visible = false
	%MoveRow.visible = false
	%RotateRow.visible = true
	_updating = true
	%AngleX.set_value_no_signal(angles_deg.x)
	%AngleY.set_value_no_signal(angles_deg.y)
	%AngleZ.set_value_no_signal(angles_deg.z)
	_updating = false


func _sync_uniform() -> void:
	if not is_node_ready():
		return
	%Uniform.set_pressed_no_signal(_settings.uniform)


func _emit_state(values: Vector3, axis: int) -> void:
	values_changed.emit({KEY_VALUES: values, KEY_AXIS: axis, KEY_UNIFORM: _settings.uniform})


func _scale_values() -> Vector3:
	return Vector3(%ScaleX.value, %ScaleY.value, %ScaleZ.value)


func _on_scale_x_changed(value: float) -> void:
	if _updating or _mode != MODE_SCALE:
		return
	if _settings.uniform:
		_updating = true
		%ScaleY.set_value_no_signal(value)
		%ScaleZ.set_value_no_signal(value)
		_updating = false
		_emit_state(Vector3(value, value, value), -1)
	else:
		_emit_state(Vector3(value, %ScaleY.value, %ScaleZ.value), -1)


func _on_scale_y_changed(value: float) -> void:
	if _updating or _mode != MODE_SCALE:
		return
	if _settings.uniform:
		_updating = true
		%ScaleX.set_value_no_signal(value)
		%ScaleZ.set_value_no_signal(value)
		_updating = false
		_emit_state(Vector3(value, value, value), -1)
	else:
		_emit_state(Vector3(%ScaleX.value, value, %ScaleZ.value), -1)


func _on_scale_z_changed(value: float) -> void:
	if _updating or _mode != MODE_SCALE:
		return
	if _settings.uniform:
		_updating = true
		%ScaleX.set_value_no_signal(value)
		%ScaleY.set_value_no_signal(value)
		_updating = false
		_emit_state(Vector3(value, value, value), -1)
	else:
		_emit_state(Vector3(%ScaleX.value, %ScaleY.value, value), -1)


func _on_uniform_toggled(on: bool) -> void:
	if _updating or _mode != MODE_SCALE:
		return
	_settings.uniform = on
	if on:
		var value: float = %ScaleX.value
		_updating = true
		%ScaleY.set_value_no_signal(value)
		%ScaleZ.set_value_no_signal(value)
		_updating = false
		_emit_state(Vector3(value, value, value), -1)


func _on_move_changed(_value: float) -> void:
	if _updating or _mode != MODE_MOVE:
		return
	_emit_state(Vector3(%MoveX.value, %MoveY.value, %MoveZ.value), -1)


func _on_rotate_changed(_value: float) -> void:
	if _updating or _mode != MODE_ROTATE:
		return
	_emit_state(Vector3(%AngleX.value, %AngleY.value, %AngleZ.value), -1)
