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
## Emitted when the framed bounds change the zoom range.
signal zoom_limits_changed(min_percent: float, max_percent: float)
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

## The box that the camera frames. When it is not valid, the camera uses the
## document bounds.
var bounds_provider: Callable

## Whether the camera keeps its pose on the active document. The export preview
## has its own camera, so it must not overwrite the editor pose.
@export var stores_document_pose := true

var _yaw := deg_to_rad(-90.0)
var _pitch := deg_to_rad(45.0)
var _dist := 24.0
var _target := Vector3.ZERO
var _init_dist := 24.0
var _restoring_pose := false

## The distance kept in front of the nearest clipped geometry.
const NEAR_MARGIN := 1.0
## The distance kept past the farthest clipped geometry. The grid extends one
## cell past the content. The symmetry planes extend four cells past the origin.
const FAR_MARGIN := 2.0
## The voxels that fill the closest view height. Voxels are one world unit, so
## this sets the closest camera distance from the field of view.
const MIN_VIEW_VOXELS := 8.0
## The farthest zoom as a multiple of the framed distance. The model fit is the
## base, so the farthest view keeps the model on screen with room around it.
const FAR_ZOOM_FACTOR := 2.0
## The space around the framed bounds. The initial view and the farthest zoom
## use the same margin.
const FRAME_MARGIN := 1.25
## The travel of the zoom slider. The value is a position on a logarithmic
## scale, so a small model and a large one both use the whole track.
const ZOOM_STEPS := 1000.0

## The farthest distance of the current view. A restored pose or a centered
## selection can sit beyond the model fit. The latch keeps the first zoom from
## jumping, and it drops back to the model fit once the view is inside it.
var _far_distance := 0.0

## Extra world boxes that the orthographic clip range must contain, keyed by
## their owner.
var _helper_far_bounds := {}

func _ready() -> void:
	State.document_changed.connect(configure)
	State.cells_changed.connect(_on_content_bounds_changed)
	State.chunks_changed.connect(_on_content_bounds_changed)
	State.frames_changed.connect(refresh_clip)
	if stores_document_pose:
		State.document_deactivating.connect(_save_pose)
		State.workspace_capture_requested.connect(_save_pose)
	set_view("default")
	configure()
	if stores_document_pose:
		view_changed.connect(_save_pose)

## Frames the document or the provided bounds. A document with a saved pose
## restores it, so a tab switch keeps the view.
func configure() -> void:
	var bounds: AABB = bounds_provider.call() if bounds_provider.is_valid() else State.document.bounds()
	_init_dist = maxf(bounds.size.length(), 16.0) * FRAME_MARGIN
	var pose: Dictionary = State.document.edit_camera if stores_document_pose else {}
	_restoring_pose = true
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


# Stores the view on the document that is about to be inactive.
func _save_pose() -> void:
	if not stores_document_pose or not State.document or _restoring_pose:
		return
	State.document.edit_camera = {
		"yaw": _yaw,
		"pitch": _pitch,
		"distance": _dist,
		"initial_distance": _init_dist,
		"target": _target,
	}


## Frames one box at the default distance.
func center_on(box: AABB) -> void:
	_target = box.get_center()
	_dist = maxf(box.size.length(), 16.0) * FRAME_MARGIN
	_far_distance = maxf(max_distance(), _dist)
	_update()
	zoom_changed.emit(zoom_percent())
	zoom_limits_changed.emit(min_zoom_percent(), max_zoom_percent())

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


## Returns the lowest zoom percent. It frames the current bounds.
func min_zoom_percent() -> float:
	return _init_dist / far_distance() * 100.0


## Returns the highest zoom percent. It stops at [method min_distance].
func max_zoom_percent() -> float:
	return _init_dist / min_distance() * 100.0


## Returns the closest camera distance. It shows [constant MIN_VIEW_VOXELS]
## voxels across the view height.
func min_distance() -> float:
	var half_angle := maxf(tan(deg_to_rad(fov) * 0.5), 0.0001)
	return MIN_VIEW_VOXELS / (2.0 * half_angle)


## Returns the farthest camera distance. It frames the current bounds with the
## same margin as the initial view, then adds [constant FAR_ZOOM_FACTOR].
func max_distance() -> float:
	var bounds := _framed_bounds()
	var fit := _init_dist
	if bounds.has_surface():
		fit = maxf(_init_dist, bounds.size.length() * FRAME_MARGIN)
	return fit * FAR_ZOOM_FACTOR


## Returns the farthest distance that a zoom may reach. It is the model fit,
## unless the current view already sits farther out.
func far_distance() -> float:
	return maxf(max_distance(), _far_distance)


## Returns the zoom slider position. The position is logarithmic, so each equal
## step changes the distance by an equal ratio.
func zoom_step() -> float:
	return _percent_to_step(zoom_percent())


## Sets the zoom from a slider position between zero and [constant ZOOM_STEPS].
func set_zoom_step(step: float) -> void:
	set_zoom_percent(_step_to_percent(clampf(step, 0.0, ZOOM_STEPS)))


## Returns the slider travel of one distance factor. A factor above one zooms in.
func zoom_step_for_factor(factor: float) -> float:
	return log(factor) / _zoom_span() * ZOOM_STEPS


func _percent_to_step(percent: float) -> float:
	return log(percent / min_zoom_percent()) / _zoom_span() * ZOOM_STEPS


func _step_to_percent(step: float) -> float:
	return min_zoom_percent() * exp(_zoom_span() * step / ZOOM_STEPS)


## Returns the logarithmic distance between the far and close limits. A
## degenerate range keeps a small span, so no slider mapping divides by zero.
func _zoom_span() -> float:
	return maxf(log(max_zoom_percent() / min_zoom_percent()), 0.0001)


## Sets the zoom percent against the initial distance.
func set_zoom_percent(percent: float) -> void:
	var p := clampf(percent, min_zoom_percent(), max_zoom_percent())
	_dist = clampf(_init_dist / (p / 100.0), min_distance(), far_distance())
	if _dist <= max_distance():
		_far_distance = max_distance()
	_update()
	zoom_changed.emit(zoom_percent())

## Multiplies the distance by one factor. A factor above one zooms out.
func zoom(factor: float) -> void:
	_dist = clampf(_dist * factor, min_distance(), far_distance())
	if _dist <= max_distance():
		_far_distance = max_distance()
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


## Registers one world box that the orthographic clip range must contain. The
## key lets the owner update or clear its box.
func set_helper_far_bounds(key: StringName, box: AABB) -> void:
	if not box.has_surface():
		clear_helper_far_bounds(key)
		return
	_helper_far_bounds[key] = box
	refresh_clip()


## Removes one helper box from the orthographic clip range.
func clear_helper_far_bounds(key: StringName) -> void:
	if _helper_far_bounds.erase(key):
		refresh_clip()


## Recomputes the orthographic far plane. It never moves the camera, so a cell
## or helper change cannot alter a captured ray family. It emits no view change.
func refresh_clip() -> void:
	if not is_orthogonal:
		return
	var box := _clip_bounds()
	if not box.has_surface():
		return
	var forward := -global_transform.basis.z
	var farthest := (box.get_support(forward) - global_position).dot(forward)
	far = maxf(2.0, farthest + FAR_MARGIN)


func _on_content_bounds_changed(_frame: int, _affected: Array[Vector3i]) -> void:
	refresh_clip()
	var far := maxf(max_distance(), _dist)
	if is_equal_approx(far, _far_distance):
		return
	# The bounds moved the far limit. Resync the slider before the next input.
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


# In orthographic projection, Godot derives the directional shadow depth range
# from the camera far plane. Keep the far plane just past the visible content
# and helpers so orthographic shadows stay crisp. The projection scale follows
# the zoom, but the camera must stay outside the clip box. A close zoom would
# otherwise put geometry behind the near plane, and orthographic clipping would
# cut it.
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
		# The lowest zoom step is farther than a fixed far plane would keep.
		far = maxf(4000.0, _dist + max_radius * 2.0)
		look_at(_target, Vector3.UP)
	view_changed.emit()
