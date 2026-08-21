class_name EditorCameraRig
extends Node3D

signal zoom_changed(percent: float)

@onready var _camera: Camera3D = $Camera3D

var _yaw := deg_to_rad(-90.0)
var _pitch := deg_to_rad(45.0)
var _dist := 24.0
var _target := Vector3.ZERO
var _init_dist := 24.0
var _orbiting := false
var _panning := false


func configure() -> void:
	_init_dist = _frame_distance(State.document)
	_dist = _init_dist
	_target = _frame_target(State.document)
	_update_camera()


func reset_view() -> void:
	_yaw = deg_to_rad(-90.0)
	_pitch = deg_to_rad(45.0)
	_init_dist = _frame_distance(State.document)
	_dist = _init_dist
	_target = _frame_target(State.document)
	_update_camera()


func _frame_distance(d: VoxiDocument) -> float:
	return float(d.grid_size) * 1.5


func _frame_target(d: VoxiDocument) -> Vector3:
	var g := float(d.grid_size)
	return Vector3(g * 0.5, 4.0, g * 0.5)


func set_view(name: String) -> void:
	match name:
		"top":
			_set_angles(0.0, deg_to_rad(89.0))
		"front":
			_set_angles(0.0, 0.0)
		"side":
			_set_angles(deg_to_rad(90.0), 0.0)
		"isometric":
			_set_angles(deg_to_rad(-90.0), deg_to_rad(45.0))
		"reset":
			reset_view()


func _set_angles(yaw: float, pitch: float) -> void:
	_yaw = yaw
	_pitch = pitch
	_update_camera()


func camera() -> Camera3D:
	return _camera


func zoom_percent() -> float:
	return _init_dist / _dist * 100.0


func set_zoom_percent(percent: float) -> void:
	var p := clampf(percent, 25.0, 400.0)
	_dist = clampf(_init_dist / (p / 100.0), 4.0, 240.0)
	_update_camera()
	zoom_changed.emit(zoom_percent())


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_RIGHT:
				_orbiting = mb.pressed
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_UP:
				_zoom(0.85)
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom(1.0 / 0.85)
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var mask := mm.button_mask
		if mask & MOUSE_BUTTON_MASK_MIDDLE or (mask & MOUSE_BUTTON_MASK_RIGHT and mm.shift_pressed):
			_pan(mm.relative)
			get_viewport().set_input_as_handled()
		elif mask & MOUSE_BUTTON_MASK_RIGHT:
			_orbit(mm.relative)
			get_viewport().set_input_as_handled()


func _orbit(rel: Vector2) -> void:
	_yaw -= rel.x * 0.01
	_pitch = clampf(_pitch + rel.y * 0.01, deg_to_rad(-89.0), deg_to_rad(89.0))
	_update_camera()


func _pan(rel: Vector2) -> void:
	var s := _dist * 0.0016
	_target -= _camera.basis.x * rel.x * s
	_target += _camera.basis.y * rel.y * s
	_update_camera()


func _zoom(factor: float) -> void:
	_dist = clampf(_dist * factor, 4.0, 240.0)
	_update_camera()
	zoom_changed.emit(_init_dist / _dist * 100.0)


func _update_camera() -> void:
	if not _camera:
		return
	var off := Vector3(
		sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)
	) * _dist
	_camera.position = _target + off
	_camera.look_at(_target, Vector3.UP)
