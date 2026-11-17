extends MeshInstance3D

## The pending primitive bounds and its six face handles.
##
## The gizmo draws a wire box and a small cross at each face center. The tool
## hit-tests the crosses in screen space and drags one face of the box.

const VoxelLineMesh := preload("res://Globals/Rendering/VoxelLineMesh.gd")
## The fallback cross half extent in world units. The gizmo overrides it with
## the current camera scale, so a cross keeps one screen size at any zoom.
const HANDLE_HALF := 0.35
## The cross half extent in screen pixels.
const HANDLE_PIXELS := 10.0
## The radius of a rotate ring in screen pixels. A larger shape pushes the ring
## out, so the ring never sits inside the shape.
const RING_RADIUS_PX := 84.0
## The gap between the shape and a rotate ring in screen pixels.
const RING_MARGIN_PX := 18.0
## The segments in one rotate ring.
const RING_SEGMENTS := 64

var _box := AABB()
var _has_box := false
var _pivot := Vector3.ZERO
var _rotation := Quaternion.IDENTITY
var _handle_half := HANDLE_HALF
var _ring_radius := 0.0
var _show_handles := false
var _highlight_axis := -1
var _highlight_side := 0
var _highlight_ring_axis := -1
var _material: StandardMaterial3D
var _highlight_material: StandardMaterial3D
var _highlight: MeshInstance3D
var _ring_highlight: MeshInstance3D


func _ready() -> void:
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = Color(1.0, 1.0, 1.0, 0.9)
	_material.no_depth_test = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.render_priority = 2
	material_override = _material
	_highlight = MeshInstance3D.new()
	_highlight.name = "Highlight"
	_highlight.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_highlight_material = StandardMaterial3D.new()
	_highlight_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_highlight_material.albedo_color = Color(1.0, 0.6, 0.2, 1.0)
	_highlight_material.no_depth_test = true
	_highlight_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_highlight_material.render_priority = 3
	_highlight.material_override = _highlight_material
	add_child(_highlight)
	_ring_highlight = MeshInstance3D.new()
	_ring_highlight.name = "RingHighlight"
	_ring_highlight.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring_highlight.material_override = _highlight_material
	add_child(_ring_highlight)
	visible = false
	_highlight.visible = false
	_ring_highlight.visible = false
	set_process(false)


## Shows the pending box. [param rotation] turns the box around its center.
## [param axis] and [param side] select the highlighted face. A negative axis
## hides the highlight. [param show_handles] draws the face crosses. A live drag
## uses the box alone.
func show_box(box: AABB, rotation := Quaternion.IDENTITY, axis := -1, side := 0, show_handles := true) -> void:
	_box = box
	_pivot = box.get_center()
	_rotation = rotation
	_has_box = true
	_show_handles = show_handles
	_highlight_axis = axis
	_highlight_side = side
	_update_handle_scale()
	_rebuild(show_handles)
	_refresh_highlight()
	_refresh_ring_highlight()
	visible = true
	set_process(true)


## Hides the box and its handles.
func hide_box() -> void:
	_has_box = false
	visible = false
	set_process(false)
	if _highlight != null:
		_highlight.visible = false
	if _ring_highlight != null:
		_ring_highlight.visible = false


## Highlights one rotate ring, or hides the highlight with -1.
func set_ring_highlight(axis: int) -> void:
	if axis == _highlight_ring_axis:
		return
	_highlight_ring_axis = axis
	_refresh_ring_highlight()


func _process(_delta: float) -> void:
	if not _has_box:
		return
	if not _update_handle_scale():
		return
	_rebuild(_show_handles)
	_refresh_highlight()
	_refresh_ring_highlight()


## Updates the cross extent from the current camera scale. Returns true when the
## extent changed, so a zoom rebuilds the crosses at their new world size.
func _update_handle_scale() -> bool:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return false
	var height := get_viewport().get_visible_rect().size.y
	if height <= 0.0:
		return false
	var world_per_pixel := 1.0
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		world_per_pixel = camera.size / height
	else:
		var forward := -camera.global_transform.basis.z
		var distance := maxf((_box.get_center() - camera.global_position).dot(forward), 0.01)
		world_per_pixel = 2.0 * distance * tan(deg_to_rad(camera.fov) * 0.5) / height
	var half := world_per_pixel * HANDLE_PIXELS
	var shape_radius := _box.size.length() * 0.5
	var ring_px := maxf(RING_RADIUS_PX, shape_radius / maxf(world_per_pixel, 0.0001) + RING_MARGIN_PX)
	var ring := world_per_pixel * ring_px
	if is_equal_approx(half, _handle_half) and is_equal_approx(ring, _ring_radius):
		return false
	_handle_half = half
	_ring_radius = ring
	return true


func _refresh_highlight() -> void:
	if not _show_handles or _highlight_axis < 0 or _highlight_side == 0:
		_highlight.visible = false
		return
	_highlight.mesh = _handle_mesh(_highlight_axis, _highlight_side)
	_highlight.visible = true


func _refresh_ring_highlight() -> void:
	if _ring_highlight == null:
		return
	if not _show_handles or _highlight_ring_axis < 0 or _ring_radius <= 0.0:
		_ring_highlight.visible = false
		return
	var vertices := PackedVector3Array()
	_append_ring(vertices, _highlight_ring_axis)
	_ring_highlight.mesh = VoxelLineMesh.build(vertices)
	_ring_highlight.visible = true


## Returns the three rotate rings in world space. Each ring carries its plane
## normal and the two in-plane axes, so a drag can measure an angle around it.
func rotation_rings() -> Array:
	var result: Array = []
	if not _has_box or _ring_radius <= 0.0:
		return result
	for axis in 3:
		var normal := Vector3.ZERO
		normal[axis] = 1.0
		var first := (axis + 1) % 3
		var second := (axis + 2) % 3
		var u := Vector3.ZERO
		u[first] = 1.0
		var v := Vector3.ZERO
		v[second] = 1.0
		result.append({
			"axis": axis,
			"center": _pivot,
			"normal": _rotation * normal,
			"u": _rotation * u,
			"v": _rotation * v,
			"radius": _ring_radius,
		})
	return result


func _append_ring(vertices: PackedVector3Array, axis: int) -> void:
	var first := (axis + 1) % 3
	var second := (axis + 2) % 3
	for index in RING_SEGMENTS:
		var first_angle := TAU * index / RING_SEGMENTS
		var second_angle := TAU * (index + 1) / RING_SEGMENTS
		var a := _pivot
		a[first] += cos(first_angle) * _ring_radius
		a[second] += sin(first_angle) * _ring_radius
		var b := _pivot
		b[first] += cos(second_angle) * _ring_radius
		b[second] += sin(second_angle) * _ring_radius
		_append_line(vertices, a, b)


## Returns the world position of one face handle.
func handle_position(axis: int, side: int) -> Vector3:
	return _to_world(_face_center(axis, side))


## Returns the six face handles and the eight corner handles. A face handle
## carries its world-facing axis direction, so a drag follows the rotated box.
func handles() -> Array:
	var result: Array = []
	if not _has_box:
		return result
	for axis in 3:
		for side in [-1, 1]:
			var direction := Vector3.ZERO
			direction[axis] = 1.0
			result.append({
				"kind": 0,
				"axis": axis,
				"side": side,
				"position": handle_position(axis, side),
				"axis_direction": _rotation * direction,
			})
	for x in [-1, 1]:
		for y in [-1, 1]:
			for z in [-1, 1]:
				var signs := Vector3i(x, y, z)
				var point := _box.get_center()
				point.x = _box.position.x if x < 0 else _box.end.x
				point.y = _box.position.y if y < 0 else _box.end.y
				point.z = _box.position.z if z < 0 else _box.end.z
				result.append({"kind": 1, "axis": -1, "side": 0, "signs": signs, "position": _to_world(point)})
	return result


func _face_center(axis: int, side: int) -> Vector3:
	var center := _box.get_center()
	center[axis] = _box.position[axis] if side < 0 else _box.end[axis]
	return center


func _to_world(point: Vector3) -> Vector3:
	return _pivot + _rotation * (point - _pivot)


func _append_line(vertices: PackedVector3Array, a: Vector3, b: Vector3) -> void:
	vertices.append(_to_world(a))
	vertices.append(_to_world(b))


func _rebuild(show_handles: bool) -> void:
	var vertices := PackedVector3Array()
	var low := _box.position
	var high := _box.end
	var corners: Array[Vector3] = [
		_to_world(Vector3(low.x, low.y, low.z)),
		_to_world(Vector3(high.x, low.y, low.z)),
		_to_world(Vector3(high.x, high.y, low.z)),
		_to_world(Vector3(low.x, high.y, low.z)),
		_to_world(Vector3(low.x, low.y, high.z)),
		_to_world(Vector3(high.x, low.y, high.z)),
		_to_world(Vector3(high.x, high.y, high.z)),
		_to_world(Vector3(low.x, high.y, high.z)),
	]
	for edge in [
		[0, 1], [1, 2], [2, 3], [3, 0],
		[4, 5], [5, 6], [6, 7], [7, 4],
		[0, 4], [1, 5], [2, 6], [3, 7],
	]:
		vertices.append(corners[edge[0]])
		vertices.append(corners[edge[1]])
	if show_handles:
		for axis in 3:
			for side in [-1, 1]:
				_append_handle(vertices, axis, side, _face_center(axis, side))
		for x in [-1, 1]:
			for y in [-1, 1]:
				for z in [-1, 1]:
					var point := _box.get_center()
					point.x = _box.position.x if x < 0 else _box.end.x
					point.y = _box.position.y if y < 0 else _box.end.y
					point.z = _box.position.z if z < 0 else _box.end.z
					_append_corner(vertices, point)
		for axis in 3:
			_append_ring(vertices, axis)
	mesh = VoxelLineMesh.build(vertices)


func _handle_mesh(axis: int, side: int) -> ArrayMesh:
	var vertices := PackedVector3Array()
	_append_handle(vertices, axis, side, _face_center(axis, side))
	return VoxelLineMesh.build(vertices)


func _append_corner(vertices: PackedVector3Array, center: Vector3) -> void:
	for axis in 3:
		var start := center
		var end := center
		start[axis] -= _handle_half
		end[axis] += _handle_half
		_append_line(vertices, start, end)


func _append_handle(vertices: PackedVector3Array, axis: int, side: int, center: Vector3) -> void:
	var first := (axis + 1) % 3
	var second := (axis + 2) % 3
	var a := center
	var b := center
	a[first] -= _handle_half
	b[first] += _handle_half
	_append_line(vertices, a, b)
	a = center
	b = center
	a[second] -= _handle_half
	b[second] += _handle_half
	_append_line(vertices, a, b)
