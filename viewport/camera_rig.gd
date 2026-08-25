class_name EditorCameraRig
extends Node3D

signal zoom_changed(percent: float)
signal view_changed

@onready var _camera: Camera3D = $Camera3D

var _yaw := deg_to_rad(-90.0)
var _pitch := deg_to_rad(45.0)
var _dist := 24.0
var _target := Vector3.ZERO
var _init_dist := 24.0
var _ortho := false

func _ready() -> void:
	configure()
	State.document_changed.connect(configure)

func configure() -> void:
	_init_dist = _frame_distance(State.document)
	_dist = _init_dist
	_target = _frame_target(State.document)
	_update_camera()


func center_on(box: AABB) -> void:
	_target = box.get_center()
	_dist = maxf(box.size.length(), 16.0) * 1.5
	_update_camera()
	zoom_changed.emit(zoom_percent())


func _frame_distance(d: VoxiDocument) -> float:
	return max(d.bounds().size.length(), 16.0) * 1.5


func _frame_target(d: VoxiDocument) -> Vector3:
	return d.bounds().get_center()


@warning_ignore("shadowed_variable_base_class")
func set_view(name: String) -> void:
	match name:
		"top":
			_set_angles(0.0, deg_to_rad(89.0))
		"bottom":
			_set_angles(0.0, deg_to_rad(-89.0))
		"front":
			_set_angles(0.0, 0.0)
		"back":
			_set_angles(deg_to_rad(180.0), 0.0)
		"right", "side":
			_set_angles(deg_to_rad(90.0), 0.0)
		"left":
			_set_angles(deg_to_rad(-90.0), 0.0)
		"isometric":
			_set_angles(deg_to_rad(-45.0), deg_to_rad(45.0))


func _set_angles(yaw: float, pitch: float) -> void:
	_yaw = yaw
	_pitch = pitch
	_update_camera()


func camera() -> Camera3D:
	return _camera


func is_orthogonal() -> bool:
	return _ortho


func set_projection(orthogonal: bool) -> void:
	_ortho = orthogonal
	_update_camera()


func zoom_percent() -> float:
	return _init_dist / _dist * 100.0


func set_zoom_percent(percent: float) -> void:
	var p := percent
	_dist = clampf(_init_dist / (p / 100.0), 4.0, 1280.0)
	_update_camera()
	zoom_changed.emit(zoom_percent())


func _unhandled_input(event: InputEvent) -> void:
	var mode := State.view_mode
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mode != State.ViewMode.NONE and mb.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			return
		match mb.button_index:
			MOUSE_BUTTON_RIGHT:
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_MIDDLE:
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
		if mask & MOUSE_BUTTON_MASK_LEFT and mode != State.ViewMode.NONE:
			if mode == State.ViewMode.PAN:
				_pan(mm.relative)
			else:
				_orbit(mm.relative)
			get_viewport().set_input_as_handled()
		elif mask & MOUSE_BUTTON_MASK_MIDDLE or (mask & MOUSE_BUTTON_MASK_RIGHT and mm.shift_pressed):
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
	_dist = clamp(_dist * factor, 6.0, 1280.0)
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
	if _ortho:
		_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		_camera.size = 2.0 * _dist * tan(deg_to_rad(_camera.fov) / 2.0)
	else:
		_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	view_changed.emit()
