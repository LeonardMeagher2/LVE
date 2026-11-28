class_name EditorCameraRig
extends Camera3D


enum ViewMode {
	NONE,
	PAN,
	ROTATE,
}

signal zoom_changed(percent: float)
signal zoom_limits_changed(min_percent: float, max_percent: float)
signal view_changed

@export var is_orthogonal:bool = false :
	set(value):
		if not is_orthogonal == value:
			is_orthogonal = value
			_update()
@export var view_mode:ViewMode = ViewMode.NONE

var bounds_provider: Callable

@export var stores_document_pose := true

var _yaw := deg_to_rad(-90.0)
var _pitch := deg_to_rad(45.0)
var _dist := 24.0
var _target := Vector3.ZERO
var _init_dist := 24.0
var _restoring_pose := false

const NEAR_MARGIN := 1.0
const FAR_MARGIN := 2.0
const MIN_VIEW_VOXELS := 8.0
const FAR_ZOOM_FACTOR := 2.0
const FRAME_MARGIN := 1.25
const MIN_FOV := 10.0
const MAX_FOV := 135.0
const DEFAULT_FOV := 45.0

var _far_distance := 0.0

var _helper_far_bounds := {}

func _ready() -> void:
	State.document_changed.connect(configure)
	State.cells_changed.connect(_on_content_bounds_changed)
	State.chunks_changed.connect(_on_content_bounds_changed)
	State.frames_changed.connect(refresh_clip)
	State.layers_changed.connect(_on_layers_changed)
	if stores_document_pose:
		State.document_deactivating.connect(_save_pose)
		State.workspace_capture_requested.connect(_save_pose)
	set_view("default")
	configure()
	if stores_document_pose:
		view_changed.connect(_save_pose)

func configure() -> void:
	var bounds: AABB = bounds_provider.call() if bounds_provider.is_valid() else State.document.bounds()
	var fit_span := maxf(bounds.size.length(), 16.0) * FRAME_MARGIN
	var pose: Dictionary = State.document.edit_camera if stores_document_pose else {}
	_restoring_pose = true
	if pose.is_empty() and State.document.reset_workspace:
		_yaw = 0.0
		_pitch = deg_to_rad(45.0)
		fov = DEFAULT_FOV
	elif not pose.is_empty():
		fov = clampf(float(pose.get("fov", DEFAULT_FOV)), MIN_FOV, MAX_FOV)
	_init_dist = _fit_distance(fit_span)
	if pose.is_empty():
		_dist = _init_dist
		_target = bounds.get_center()
	else:
		_yaw = float(pose.get("yaw", _yaw))
		_pitch = float(pose.get("pitch", _pitch))
		_dist = float(pose.get("distance", pose.get("dist", _init_dist)))
		_init_dist = float(pose.get("initial_distance", _init_dist))
		_target = pose.get("target", bounds.get_center())
	_init_dist = maxf(_init_dist, min_distance())
	_far_distance = maxf(max_distance(), _dist)
	_update()
	_restoring_pose = false
	zoom_changed.emit(zoom_percent())
	zoom_limits_changed.emit(min_zoom_percent(), max_zoom_percent())


func _save_pose() -> void:
	if not stores_document_pose or not State.document or _restoring_pose:
		return
	State.document.edit_camera = {
		"yaw": _yaw,
		"pitch": _pitch,
		"distance": _dist,
		"initial_distance": _init_dist,
		"target": _target,
		"fov": fov,
	}


func center_on(box: AABB) -> void:
	_target = box.get_center()
	_dist = _fit_distance(maxf(box.size.length(), 16.0) * FRAME_MARGIN)
	_far_distance = maxf(max_distance(), _dist)
	_update()
	zoom_changed.emit(zoom_percent())
	zoom_limits_changed.emit(min_zoom_percent(), max_zoom_percent())

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


func min_zoom_percent() -> float:
	return _init_dist / far_distance() * 100.0


func max_zoom_percent() -> float:
	return _init_dist / min_distance() * 100.0


func min_distance() -> float:
	var half_angle := maxf(tan(deg_to_rad(fov) * 0.5), 0.0001)
	return MIN_VIEW_VOXELS / (2.0 * half_angle)


func max_distance() -> float:
	var bounds := _framed_bounds()
	var fit := _init_dist
	if bounds.has_surface():
		fit = maxf(_init_dist, _fit_distance(maxf(bounds.size.length(), 16.0) * FRAME_MARGIN))
	return fit * FAR_ZOOM_FACTOR


func _fit_distance(span: float) -> float:
	return span * tan(deg_to_rad(DEFAULT_FOV) * 0.5) / maxf(tan(deg_to_rad(fov) * 0.5), 0.0001)


func field_of_view() -> float:
	return 0.0 if is_orthogonal else fov


func set_field_of_view(degrees: float) -> void:
	var orthographic := degrees < MIN_FOV
	if not orthographic:
		var next_fov := clampf(degrees, MIN_FOV, MAX_FOV)
		if not is_equal_approx(next_fov, fov):
			_scale_lens(next_fov)
			fov = next_fov
	_dist = clampf(_dist, min_distance(), far_distance())
	if is_orthogonal == orthographic:
		_update()
	else:
		is_orthogonal = orthographic
	zoom_changed.emit(zoom_percent())
	zoom_limits_changed.emit(min_zoom_percent(), max_zoom_percent())


func _scale_lens(next_fov: float) -> void:
	var factor := tan(deg_to_rad(fov) * 0.5) / maxf(tan(deg_to_rad(next_fov) * 0.5), 0.0001)
	_dist *= factor
	_init_dist *= factor
	_far_distance *= factor


func reset_field_of_view() -> void:
	fov = DEFAULT_FOV
	if is_orthogonal:
		is_orthogonal = false
	else:
		_update()


func far_distance() -> float:
	return maxf(max_distance(), _far_distance)


func set_zoom_percent(percent: float) -> void:
	var p := clampf(percent, min_zoom_percent(), max_zoom_percent())
	_dist = clampf(_init_dist / (p / 100.0), min_distance(), far_distance())
	if _dist <= max_distance():
		_far_distance = max_distance()
	_update()
	zoom_changed.emit(zoom_percent())

func zoom(factor: float) -> void:
	_dist = clampf(_dist * factor, min_distance(), far_distance())
	if _dist <= max_distance():
		_far_distance = max_distance()
	_update()
	zoom_changed.emit(_init_dist / _dist * 100.0)


func orbit(rel: Vector2) -> void:
	_yaw -= rel.x * 0.01
	_pitch = clampf(_pitch + rel.y * 0.01, deg_to_rad(-89.0), deg_to_rad(89.0))
	_update()


func pan(rel: Vector2) -> void:
	var per_pixel := _world_per_pixel()
	_target -= get_camera_transform().basis.x * rel.x * per_pixel
	_target += get_camera_transform().basis.y * rel.y * per_pixel
	_update()


func _world_per_pixel() -> float:
	var height := maxf(get_viewport().get_visible_rect().size.y, 1.0)
	return 2.0 * _dist * tan(deg_to_rad(fov) * 0.5) / height


func set_helper_far_bounds(key: StringName, box: AABB) -> void:
	if not box.has_surface():
		clear_helper_far_bounds(key)
		return
	_helper_far_bounds[key] = box
	refresh_clip()


func clear_helper_far_bounds(key: StringName) -> void:
	if _helper_far_bounds.erase(key):
		refresh_clip()


func refresh_clip() -> void:
	if not is_orthogonal:
		return
	var box := _clip_bounds()
	if not box.has_surface():
		return
	var forward := -global_transform.basis.z
	var farthest := (box.get_support(forward) - global_position).dot(forward)
	far = maxf(2.0, farthest + FAR_MARGIN)


func _on_content_bounds_changed(_layer: int, _frame: int, _affected: Array[Vector3i]) -> void:
	refresh_clip()
	var far := maxf(max_distance(), _dist)
	if is_equal_approx(far, _far_distance):
		return
	_far_distance = far
	zoom_limits_changed.emit(min_zoom_percent(), max_zoom_percent())


func _on_layers_changed() -> void:
	refresh_clip()
	var far := maxf(max_distance(), _dist)
	if is_equal_approx(far, _far_distance):
		return
	_far_distance = far
	zoom_limits_changed.emit(min_zoom_percent(), max_zoom_percent())


func _view_direction() -> Vector3:
	return Vector3(
		sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)
	)


func _framed_bounds() -> AABB:
	if bounds_provider.is_valid():
		var provided: AABB = bounds_provider.call()
		return provided
	return State.document.bounds()


func _clip_bounds() -> AABB:
	var box := _framed_bounds()
	for value in _helper_far_bounds.values():
		var helper: AABB = value
		if not helper.has_surface():
			continue
		box = helper if not box.has_surface() else box.merge(helper)
	return box


func _apply_orthographic_clip(direction: Vector3) -> void:
	var box := _clip_bounds()
	var forward := -direction
	var camera_distance := maxf(_dist, 1.0 + NEAR_MARGIN)
	var farthest := 1.0
	if box.has_surface():
		var nearest := (box.get_support(-forward) - _target).dot(forward)
		farthest = (box.get_support(forward) - _target).dot(forward)
		camera_distance = maxf(_dist, -nearest + NEAR_MARGIN)
	position = _target + direction * camera_distance
	far = maxf(2.0, camera_distance + farthest + FAR_MARGIN)
	look_at(_target, Vector3.UP)


func _update() -> void:
	var direction := _view_direction()
	if is_orthogonal:
		projection = Camera3D.PROJECTION_ORTHOGONAL
		size = 2.0 * _dist * tan(deg_to_rad(fov) / 2.0)
		_apply_orthographic_clip(direction)
	else:
		projection = Camera3D.PROJECTION_PERSPECTIVE
		var bounds := _framed_bounds()
		var max_radius := maxf(bounds.size.length() * 0.5, 1.0)
		position = _target + direction * _dist
		far = maxf(4000.0, _dist + max_radius * 2.0)
		look_at(_target, Vector3.UP)
	view_changed.emit()
