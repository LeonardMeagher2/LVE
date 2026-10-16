class_name EditorCameraRig
extends Camera3D

enum ViewMode {
	NONE,
	PAN,
	ROTATE,
}

signal zoom_changed(percent: float)
signal view_changed

@export var is_orthogonal:bool = false :
	set(value):
		if not is_orthogonal == value:
			is_orthogonal = value
			_update()
@export var view_mode:ViewMode = ViewMode.NONE
@export var min_zoom:float = 1.0
@export var max_zoom:float = 400

var _yaw := deg_to_rad(-90.0)
var _pitch := deg_to_rad(45.0)
var _dist := 24.0
var _target := Vector3.ZERO
var _init_dist := 24.0
var bounds_provider: Callable

func _ready() -> void:
	configure()
	State.document_changed.connect(configure)
	set_view("default")

func configure() -> void:
	var bounds: AABB = bounds_provider.call() if bounds_provider.is_valid() else State.document.bounds()
	_init_dist = maxf(bounds.size.length(), 16.0) * 1.25
	_dist = _init_dist
	_target = bounds.get_center()
	_update()


func center_on(box: AABB) -> void:
	_target = box.get_center()
	_dist = maxf(box.size.length(), 16.0) * 1.25
	_update()
	zoom_changed.emit(zoom_percent())

func center_active() -> void:
	if bounds_provider.is_valid():
		center_on(bounds_provider.call())
		return
	var bounds := AABB()
	if not State.selection.is_empty():
		for c in State.selection.all_cells():
			var cb := AABB(Vector3(c) - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
			bounds = cb if not bounds.has_volume() else bounds.merge(cb)
	else:
		bounds = State.document.bounds()
	center_on(bounds)

func _frame_distance(d: VoxelDocument) -> float:
	return max(d.bounds().size.length(), 16.0) * 1.25


func _frame_target(d: VoxelDocument) -> Vector3:
	return d.bounds().get_center()


func set_view(view_name: String) -> void:
	match view_name:
		"default":
			_set_angles(deg_to_rad(0.0), deg_to_rad(45.0))
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
	_update()


func zoom_percent() -> float:
	return _init_dist / _dist * 100.0


func set_zoom_percent(percent: float) -> void:
	var p := percent
	_dist = _init_dist / (p / 100.0)
	_update()
	zoom_changed.emit(zoom_percent())

func zoom(factor: float) -> void:
	_dist = _dist * factor
	_update()
	zoom_changed.emit(_init_dist / _dist * 100.0)


func orbit(rel: Vector2) -> void:
	_yaw -= rel.x * 0.01
	_pitch = clampf(_pitch + rel.y * 0.01, deg_to_rad(-89.0), deg_to_rad(89.0))
	_update()


func pan(rel: Vector2) -> void:
	var s := _dist * 0.0016
	_target -= get_camera_transform().basis.x * rel.x * s
	_target += get_camera_transform().basis.y * rel.y * s
	_update()


func _update() -> void:
	var off := Vector3(
		sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)
	) * _dist
	position = _target + off
	look_at(_target, Vector3.UP)
	var bounds: AABB = bounds_provider.call() if bounds_provider.is_valid() else State.document.bounds()
	var max_radius := maxf(bounds.size.length() * 0.5, 1.0)
	if is_orthogonal:
		projection = Camera3D.PROJECTION_ORTHOGONAL
		size = 2.0 * _dist * tan(deg_to_rad(fov) / 2.0)
		# Godot derives the directional shadow depth range from the camera far plane in orthographic projection.
		far = maxf(2.0, _dist + max_radius)
	else:
		projection = Camera3D.PROJECTION_PERSPECTIVE
		far = 4000.0
	view_changed.emit()
