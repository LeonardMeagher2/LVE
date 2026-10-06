extends HBoxContainer


func _ready() -> void:
	for axis in 3:
		get_node(["X", "Y", "Z"][axis]).toggled.connect(_on_axis_toggled.bind(axis))
		get_node(["OriginX", "OriginY", "OriginZ"][axis]).value_changed.connect(_on_origin_changed.bind(axis))
	State.symmetry_changed.connect(_sync)
	State.activity_changed.connect(_sync)
	$Reset.pressed.connect(_reset_origin)
	_sync()


func _sync() -> void:
	var busy := State.edit_busy()
	for axis in 3:
		var button: Button = get_node(["X", "Y", "Z"][axis])
		button.set_pressed_no_signal(bool(State.symmetry_axes & (1 << axis)))
		button.disabled = busy
		var control: SpinBox = get_node(["OriginX", "OriginY", "OriginZ"][axis])
		control.set_value_no_signal(State.symmetry_origin[axis])
		control.editable = not busy
	$Reset.disabled = busy


func _on_axis_toggled(on: bool, axis: int) -> void:
	if on:
		State.symmetry_axes |= 1 << axis
	else:
		State.symmetry_axes &= ~(1 << axis)


func _on_origin_changed(value: float, axis: int) -> void:
	var origin := State.symmetry_origin
	origin[axis] = value
	State.symmetry_origin = origin


func _reset_origin() -> void:
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
