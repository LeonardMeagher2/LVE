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
## The half size of the rotate joint square in screen pixels. It matches the
## transform tool rotate gizmo.
const ROTATE_JOINT_PX := 7.0
## The gap between the shape top and the rotate mark, in screen pixels.
const ROTATE_MARK_OFFSET_PX := 26.0
## The rotate mark corner offset in screen pixels.
const ROTATE_OFFSET_PX := 8.0
## The straight run of a rotate mark arm in screen pixels.
const ROTATE_RUN_PX := 13.0
## The rotate mark arrowhead length in screen pixels.
const ROTATE_HEAD_PX := 3.5

var _box := AABB()
var _has_box := false
var _pivot := Vector3.ZERO
var _rotation := Quaternion.IDENTITY
var _handle_half := HANDLE_HALF
var _world_per_pixel := 0.0
var _rotate_mark := Vector3.ZERO
var _show_handles := false
var _highlight_axis := -1
var _highlight_side := 0
var _material: StandardMaterial3D
var _highlight_material: StandardMaterial3D
var _highlight: MeshInstance3D


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
	visible = false
	_highlight.visible = false
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
	visible = true
	set_process(true)


## Hides the box and its handles.
func hide_box() -> void:
	_has_box = false
	visible = false
	set_process(false)
	if _highlight != null:
		_highlight.visible = false


func _process(_delta: float) -> void:
	if not _has_box:
		return
	if not _update_handle_scale():
		return
	_rebuild(_show_handles)
	_refresh_highlight()


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
	var mark := _rotate_mark_position(camera)
	if is_equal_approx(half, _handle_half) and mark.is_equal_approx(_rotate_mark):
		return false
	_handle_half = half
	_world_per_pixel = world_per_pixel
	_rotate_mark = mark
	return true


## Returns the world point of the rotate mark. It sits above the projected shape
## top, so it never covers the body drag area.
func _rotate_mark_position(camera: Camera3D) -> Vector3:
	var forward := -camera.global_transform.basis.z
	var depth := (_pivot - camera.global_position).dot(forward)
	if depth <= camera.near:
		return _pivot
	var screen := camera.unproject_position(_pivot)
	var top := screen.y
	for x in [-1, 1]:
		for y in [-1, 1]:
			for z in [-1, 1]:
				var point := _box.get_center()
				point.x = _box.position.x if x < 0 else _box.end.x
				point.y = _box.position.y if y < 0 else _box.end.y
				point.z = _box.position.z if z < 0 else _box.end.z
				top = minf(top, camera.unproject_position(_to_world(point)).y)
	return camera.project_position(Vector2(screen.x, top - ROTATE_MARK_OFFSET_PX), depth)


func _refresh_highlight() -> void:
	if not _show_handles or _highlight_axis < 0 or _highlight_side == 0:
		_highlight.visible = false
		return
	_highlight.mesh = _handle_mesh(_highlight_axis, _highlight_side)
	_highlight.visible = true


## Returns the world center of the rotate mark.
func rotate_mark_center() -> Vector3:
	return _rotate_mark


## Appends the screen-facing rotate mark. It matches the transform tool: a joint
## square and two quarter-turn arrows in the camera plane.
func _append_rotate_mark(vertices: PackedVector3Array) -> void:
	if _world_per_pixel <= 0.0 or not is_inside_tree():
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var right := camera.global_transform.basis.x
	var up := camera.global_transform.basis.y
	var world_px := _world_per_pixel
	var joint := world_px * ROTATE_JOINT_PX
	var square: Array[Vector3] = [
		_rotate_mark - right * joint - up * joint,
		_rotate_mark + right * joint - up * joint,
		_rotate_mark + right * joint + up * joint,
		_rotate_mark - right * joint + up * joint,
	]
	for index in 4:
		vertices.append(square[index])
		vertices.append(square[(index + 1) % 4])
	var offset := world_px * ROTATE_OFFSET_PX
	_append_turn_arrow(vertices, _rotate_mark + right * (joint + offset) + up * (joint + offset), right, -up, world_px)
	_append_turn_arrow(vertices, _rotate_mark - right * (joint + offset) - up * (joint + offset), -right, up, world_px)


## Draws one quarter-turn arrow. [param across] runs to the corner, then
## [param along] runs to a right-angle head, like the transform rotate mark.
func _append_turn_arrow(vertices: PackedVector3Array, corner: Vector3, across: Vector3, along: Vector3, world_px: float) -> void:
	var run := world_px * ROTATE_RUN_PX
	var head := world_px * ROTATE_HEAD_PX
	var tip := corner + along * run
	vertices.append(corner - across * run)
	vertices.append(corner)
	vertices.append(corner)
	vertices.append(tip)
	var back := tip - along * head
	vertices.append(tip)
	vertices.append(back + across * head)
	vertices.append(tip)
	vertices.append(back - across * head)


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
		_append_rotate_mark(vertices)
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
