extends ConfirmationDialog

signal scale_changed(scale: Vector3)

var _settings := preload("../settings.tres")
var _updating := false


func _ready() -> void:
	%ScaleX.value_changed.connect(_on_x_changed)
	%ScaleY.value_changed.connect(_on_y_changed)
	%ScaleZ.value_changed.connect(_on_z_changed)
	%Uniform.toggled.connect(_on_uniform_toggled)
	_settings.changed.connect(_sync_uniform)
	_sync_uniform()


func open_with_values(value: Vector3) -> void:
	_updating = true
	%ScaleX.set_value_no_signal(value.x)
	%ScaleY.set_value_no_signal(value.y)
	%ScaleZ.set_value_no_signal(value.z)
	%Uniform.set_pressed_no_signal(_settings.uniform)
	_updating = false


func _sync_uniform() -> void:
	if not is_node_ready():
		return
	%Uniform.set_pressed_no_signal(_settings.uniform)


func _on_x_changed(value: float) -> void:
	if _updating:
		return
	if _settings.uniform:
		_updating = true
		%ScaleY.set_value_no_signal(value)
		%ScaleZ.set_value_no_signal(value)
		_updating = false
		scale_changed.emit(Vector3(value, value, value))
	else:
		scale_changed.emit(Vector3(value, %ScaleY.value, %ScaleZ.value))


func _on_y_changed(value: float) -> void:
	if _updating:
		return
	if _settings.uniform:
		_updating = true
		%ScaleX.set_value_no_signal(value)
		%ScaleZ.set_value_no_signal(value)
		_updating = false
		scale_changed.emit(Vector3(value, value, value))
	else:
		scale_changed.emit(Vector3(%ScaleX.value, value, %ScaleZ.value))


func _on_z_changed(value: float) -> void:
	if _updating:
		return
	if _settings.uniform:
		_updating = true
		%ScaleX.set_value_no_signal(value)
		%ScaleY.set_value_no_signal(value)
		_updating = false
		scale_changed.emit(Vector3(value, value, value))
	else:
		scale_changed.emit(Vector3(%ScaleX.value, %ScaleY.value, value))


func _on_uniform_toggled(on: bool) -> void:
	if _updating:
		return
	_settings.uniform = on
	if on:
		var value: float = %ScaleX.value
		_updating = true
		%ScaleY.set_value_no_signal(value)
		%ScaleZ.set_value_no_signal(value)
		_updating = false
		scale_changed.emit(Vector3(value, value, value))
