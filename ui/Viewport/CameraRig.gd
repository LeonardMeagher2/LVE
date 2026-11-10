class_name EditorCameraRig
extends Camera3D

## The editor view camera.
##
## It orbits a target, pans, and zooms. It frames the document or the
## selection. A bounds provider can supply the framed box.

## The camera view mode.
enum ViewMode {
	## No view drag.
	NONE,
	## Pan the view.
	PAN,
	## Orbit the view.
	ROTATE,
}

## Emitted when the zoom percent changes.
signal zoom_changed(percent: float)
## Emitted after the camera transform changes.
signal view_changed

## Whether the camera uses an orthographic projection.
@export var is_orthogonal:bool = false :
	set(value):
		if not is_orthogonal == value:
			is_orthogonal = value
			_update()
## The active view mode.
@export var view_mode:ViewMode = ViewMode.NONE
## The minimum zoom percent.
@export var min_zoom:float = 1.0
## The maximum zoom percent.
@export var max_zoom:float = 400

## The box that the camera frames. When it is not valid, the camera uses the
## document bounds.
var bounds_provider: Callable

var _yaw := deg_to_rad(-90.0)
var _pitch := deg_to_rad(45.0)
var _dist := 24.0
var _target := Vector3.ZERO
var _init_dist := 24.0

func _ready() -> void:
	configure()
	State.document_changed.connect(configure)
	State.document_deactivating.connect(_save_pose)
	set_view("default")

## Frames the document or the provided bounds. A document with a saved pose
## restores it, so a tab switch keeps the view.
func configure() -> void:
	var bounds: AABB = bounds_provider.call() if bounds_provider.is_valid() else State.document.bounds()
	_init_dist = maxf(bounds.size.length(), 16.0) * 1.25
	var pose: Dictionary = State.document.edit_camera
	if pose.is_empty():
		_dist = _init_dist
		_target = bounds.get_center()
	else:
		_yaw = float(pose.get("yaw", _yaw))
		_pitch = float(pose.get("pitch", _pitch))
		_dist = float(pose.get("dist", _init_dist))
		_target = pose.get("target", bounds.get_center())
	_update()
	zoom_changed.emit(zoom_percent())


# Stores the view on the document that is about to be inactive.
func _save_pose() -> void:
	if not State.document:
		return
	State.document.edit_camera = {
		"yaw": _yaw,
		"pitch": _pitch,
		"dist": _dist,
		"target": _target,
	}


## Frames one box at the default distance.
func center_on(box: AABB) -> void:
	_target = box.get_center()
	_dist = maxf(box.size.length(), 16.0) * 1.25
	_update()
	zoom_changed.emit(zoom_percent())

## Frames the selection when it is not empty. Otherwise it frames the document
## or the provided bounds.
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


## Sets one named view. A known name is [code]default[/code], [code]top[/code],
## [code]bottom[/code], [code]front[/code], [code]back[/code], [code]left[/code],
## [code]right[/code], or [code]isometric[/code].
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


## Returns the zoom percent against the initial distance.
func zoom_percent() -> float:
	return _init_dist / _dist * 100.0


## Sets the zoom percent against the initial distance.
func set_zoom_percent(percent: float) -> void:
	var p := percent
	_dist = _init_dist / (p / 100.0)
	_update()
	zoom_changed.emit(zoom_percent())

## Multiplies the distance by one factor. A factor above one zooms out.
func zoom(factor: float) -> void:
	_dist = _dist * factor
	_update()
	zoom_changed.emit(_init_dist / _dist * 100.0)


## Orbits the camera by one pointer delta.
func orbit(rel: Vector2) -> void:
	_yaw -= rel.x * 0.01
	_pitch = clampf(_pitch + rel.y * 0.01, deg_to_rad(-89.0), deg_to_rad(89.0))
	_update()


## Pans the camera by one pointer delta.
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
