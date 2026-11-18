extends MeshInstance3D

## The pending primitive wire and its face handles.
##
## The wire follows the pending shape: a box outline, an ellipsoid's three great
## circles, or a cone's end circles and sides. The tool hit-tests the face and
## corner handles in screen space and drags one bound. A handle is drawn only
## near the pointer, so the shape stays readable. Three dashed rings turn the
## shape around its local axes; a ring is drawn only when the view is near its
## axis.

const VoxelLineMesh := preload("res://Globals/Rendering/VoxelLineMesh.gd")
const PrimitiveField := preload("res://Globals/State/Tools/PrimitiveField.gd")
## The fallback face cross half extent in world units. The gizmo overrides it
## with the current camera scale, so a cross keeps one screen size at any zoom.
const HANDLE_HALF := 0.35
## The face cross half extent in screen pixels.
const HANDLE_PIXELS := 12.0
## The corner cross half extent in screen pixels.
const CORNER_PIXELS := 10.0
## The radius of a rotate ring in screen pixels. A larger shape pushes the ring
## out, so the ring never sits inside the shape.
const RING_RADIUS_PX := 84.0
## The gap between the shape and a rotate ring in screen pixels.
const RING_MARGIN_PX := 18.0
## The smallest dot between the view and a ring axis that draws the ring. A
## ring that is nearly edge-on cannot be dragged, so it is not drawn.
const RING_VIEW_DOT := 0.45
## The dash and gap span in screen pixels for an idle ring.
const RING_DASH_SPAN_PX := 20.0
## The fewest and most dashes in one idle ring.
const RING_DASH_MIN := 16
const RING_DASH_MAX := 48
## The segments in one solid rotate ring.
const RING_SEGMENTS := 64
## The segments in one shape wire circle.
const SHAPE_SEGMENTS := 32
## The side lines on a cone wire.
const CONE_SIDES := 8
## The segments in one rounded cone cap arc.
const CONE_CAP_SEGMENTS := 4
## The dash and gap span in screen pixels for the blend halo.
const BLEND_DASH_SPAN_PX := 14.0

var _box := AABB()
var _has_box := false
var _pivot := Vector3.ZERO
var _local_center := Vector3.ZERO
var _rotation := Quaternion.IDENTITY
var _primitive := {}
var _blend := 0.0
var _handle_half := HANDLE_HALF
var _corner_half := HANDLE_HALF
var _ring_radius := 0.0
var _ring_dashes := RING_DASH_MIN
var _ring_mask := 0
var _rings_shown := true
var _show_handles := false
var _hot_handle := {}
var _hot_ring := -1
var _world_per_pixel := 0.0
var _material: StandardMaterial3D
var _hot_material: StandardMaterial3D
var _rings: MeshInstance3D
var _hot: MeshInstance3D


func _ready() -> void:
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = Color.WHITE
	_material.no_depth_test = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.render_priority = 2
	material_override = _material
	_hot_material = StandardMaterial3D.new()
	_hot_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hot_material.albedo_color = Color.WHITE
	_hot_material.no_depth_test = true
	_hot_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_hot_material.render_priority = 3
	_rings = MeshInstance3D.new()
	_rings.name = "Rings"
	_rings.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rings.material_override = _material
	add_child(_rings)
	_hot = MeshInstance3D.new()
	_hot.name = "Hot"
	_hot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hot.material_override = _hot_material
	add_child(_hot)
	visible = false
	_rings.visible = false
	_hot.visible = false
	set_process(false)


## Shows the pending shape. [param rotation] turns the shape around [param
## pivot], which defaults to the box center. [param primitive] is the request
## dictionary that the wire draws; an empty dictionary draws the box bounds.
## [param show_handles] draws the rings and answers the handles. [param blend] is
## the smooth blend reach in cells, drawn as a dashed outer wire. A live drag
## uses the shape alone.
func show_box(box: AABB, rotation := Quaternion.IDENTITY, pivot := Vector3.INF, primitive := {}, show_handles := true, blend := 0.0) -> void:
	_box = box
	_local_center = box.get_center()
	_pivot = _local_center if pivot == Vector3.INF else pivot
	_rotation = rotation
	_primitive = primitive
	_blend = maxf(blend, 0.0)
	_has_box = true
	_show_handles = show_handles
	_update_scale()
	_rebuild_shape()
	_rebuild_rings()
	_rebuild_hot()
	visible = true
	set_process(true)


## Hides the shape, its handles, and its rings.
func hide_box() -> void:
	_has_box = false
	visible = false
	set_process(false)
	_hot_handle = {}
	_hot_ring = -1
	if _rings != null:
		_rings.visible = false
	if _hot != null:
		_hot.visible = false


## Highlights one handle, or clears it with an empty dictionary.
func set_hot_handle(hit: Dictionary) -> void:
	if _hot_handle.get("kind", -1) == hit.get("kind", -1) \
			and _hot_handle.get("axis", -1) == hit.get("axis", -1) \
			and _hot_handle.get("side", 0) == hit.get("side", 0) \
			and _hot_handle.get("signs", Vector3i.ZERO) == hit.get("signs", Vector3i.ZERO):
		return
	_hot_handle = hit.duplicate()
	_rebuild_hot()


## Highlights one rotate ring, or hides the highlight with -1.
func set_ring_highlight(axis: int) -> void:
	if axis == _hot_ring:
		return
	_hot_ring = axis
	_rebuild_rings()
	_rebuild_hot()


## Shows or hides the rotate rings. A body or handle drag hides them.
func set_rings_visible(value: bool) -> void:
	if value == _rings_shown:
		return
	_rings_shown = value
	_rebuild_rings()


func _process(_delta: float) -> void:
	if not _has_box:
		return
	var scaled := _update_scale()
	var mask := _visible_ring_mask()
	if scaled:
		_rebuild_shape()
		_rebuild_rings()
		_rebuild_hot()
	elif mask != _ring_mask:
		_rebuild_rings()


## Updates the screen-space sizes from the current camera scale. Returns true
## when a size changed, so the wire and the handles rebuild at their new world
## size.
func _update_scale() -> bool:
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
	var corner := world_per_pixel * CORNER_PIXELS
	var shape_radius := _box.size.length() * 0.5
	var ring_px := maxf(RING_RADIUS_PX, shape_radius / maxf(world_per_pixel, 0.0001) + RING_MARGIN_PX)
	var ring := world_per_pixel * ring_px
	var dashes := clampi(roundi(TAU * ring_px / RING_DASH_SPAN_PX), RING_DASH_MIN, RING_DASH_MAX)
	if is_equal_approx(half, _handle_half) and is_equal_approx(corner, _corner_half) \
			and is_equal_approx(ring, _ring_radius) and dashes == _ring_dashes \
			and is_equal_approx(world_per_pixel, _world_per_pixel):
		return false
	_handle_half = half
	_corner_half = corner
	_ring_radius = ring
	_ring_dashes = dashes
	_world_per_pixel = world_per_pixel
	return true


## Returns the bit mask of rings that the view is close enough to see face-on.
func _visible_ring_mask() -> int:
	if not _has_box or not _show_handles or _ring_radius <= 0.0:
		return 0
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return 7
	var forward := -camera.global_transform.basis.z
	var mask := 0
	for axis in 3:
		var normal := Vector3.ZERO
		normal[axis] = 1.0
		if absf(forward.dot(_rotation * normal)) >= RING_VIEW_DOT:
			mask |= 1 << axis
	return mask


## Returns the rotate rings that the view shows. Each ring carries its plane
## normal and the two in-plane axes, so a drag can measure an angle around it.
func rotation_rings() -> Array:
	var result: Array = []
	if not _has_box or _ring_radius <= 0.0:
		return result
	var mask := _visible_ring_mask()
	for axis in 3:
		if not (mask & (1 << axis)):
			continue
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
	return _pivot + _rotation * (point - _local_center)


func _append_line(vertices: PackedVector3Array, a: Vector3, b: Vector3) -> void:
	vertices.append(_to_world(a))
	vertices.append(_to_world(b))


## Builds the wire of the pending shape. A box or an empty primitive draws the
## box bounds. An ellipsoid draws its three great circles. A cone draws its end
## circles and side lines. A nonzero blend adds a dashed outer wire at the blend
## reach.
func _rebuild_shape() -> void:
	var vertices := PackedVector3Array()
	match int(_primitive.get("kind", -1)):
		PrimitiveField.KIND_ELLIPSOID:
			_append_ellipsoid(vertices)
		PrimitiveField.KIND_CONE:
			_append_cone(vertices)
		_:
			_append_box(vertices)
	if _blend > 0.0001:
		_append_blend(vertices)
	mesh = VoxelLineMesh.build(vertices)


func _append_box(vertices: PackedVector3Array) -> void:
	_append_box_at(vertices, _box, false)


func _append_box_at(vertices: PackedVector3Array, box: AABB, dashed: bool) -> void:
	var low := box.position
	var high := box.end
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
		if dashed:
			_append_dashed_segment(vertices, corners[edge[0]], corners[edge[1]])
		else:
			vertices.append(corners[edge[0]])
			vertices.append(corners[edge[1]])


func _append_ellipsoid(vertices: PackedVector3Array) -> void:
	var center: Vector3 = _primitive.get("center", _pivot)
	var radii: Vector3 = _primitive.get("radii", _box.size * 0.5)
	var rotation := _rotation
	if _primitive.get("rotation", null) != null:
		rotation = PrimitiveField.primitive_rotation(_primitive)
	_append_ellipsoid_at(vertices, center, radii, rotation, false)


func _append_ellipsoid_at(vertices: PackedVector3Array, center: Vector3, radii: Vector3, rotation: Quaternion, dashed: bool) -> void:
	for plane in 3:
		var first := (plane + 1) % 3
		var second := (plane + 2) % 3
		var u := Vector3.ZERO
		u[first] = 1.0
		var v := Vector3.ZERO
		v[second] = 1.0
		_append_ellipse_at(vertices, center, rotation * u, rotation * v, radii[first], radii[second], dashed)


func _append_cone(vertices: PackedVector3Array) -> void:
	var a: Vector3 = _primitive.get("a", _pivot)
	var b: Vector3 = _primitive.get("b", _pivot)
	var r1 := float(_primitive.get("r1", 0.0))
	var r2 := float(_primitive.get("r2", 0.0))
	var roundness := clampf(float(_primitive.get("roundness", 0.0)), 0.0, 1.0)
	_append_cone_at(vertices, a, b, r1, r2, roundness, false)


## Draws a cone from its two end spheres. [param roundness] moves the side lines
## from the flat cone to the tangent of the two spheres and adds the rounded end
## caps. A zero roundness is the flat cone.
func _append_cone_at(vertices: PackedVector3Array, a: Vector3, b: Vector3, r1: float, r2: float, roundness: float, dashed: bool) -> void:
	var axis_vector := b - a
	if axis_vector.length_squared() <= 0.000001:
		return
	var distance := axis_vector.length()
	var axis := axis_vector / distance
	var u := axis.cross(Vector3.UP)
	if u.length_squared() < 0.0001:
		u = axis.cross(Vector3.RIGHT)
	u = u.normalized()
	var v := axis.cross(u).normalized()
	var rr := r1 - r2
	var a2 := distance * distance - rr * rr
	if roundness > 0.0 and a2 <= 0.0:
		_append_sphere_at(vertices, a if r1 >= r2 else b, maxf(r1, r2), dashed)
		return
	var flat_angle := PI * 0.5
	var round_angle := flat_angle
	if a2 > 0.0:
		round_angle = acos(clampf(rr / distance, -1.0, 1.0))
	var angle := lerpf(flat_angle, round_angle, roundness)
	var normal_axis := cos(angle)
	var normal_radial := sin(angle)
	_append_ellipse_at(vertices, a + axis * (r1 * normal_axis), u, v, r1 * normal_radial, r1 * normal_radial, dashed)
	if r2 > 0.0:
		_append_ellipse_at(vertices, b + axis * (r2 * normal_axis), u, v, r2 * normal_radial, r2 * normal_radial, dashed)
	for index in CONE_SIDES:
		var radial := u * cos(TAU * index / CONE_SIDES) + v * sin(TAU * index / CONE_SIDES)
		var normal := axis * normal_axis + radial * normal_radial
		var start := a + normal * r1
		var end := b + normal * r2
		if dashed:
			_append_dashed_segment(vertices, start, end)
		else:
			vertices.append(start)
			vertices.append(end)
	if roundness > 0.0 and not dashed:
		for index in CONE_SIDES:
			var radial := u * cos(TAU * index / CONE_SIDES) + v * sin(TAU * index / CONE_SIDES)
			_append_cone_cap(vertices, a, axis, radial, r1, angle, PI, roundness)
			if r2 > 0.0:
				_append_cone_cap(vertices, b, axis, radial, r2, angle, 0.0, roundness)


## Draws one meridian of a rounded cone cap from the contact normal to the pole.
func _append_cone_cap(vertices: PackedVector3Array, center: Vector3, axis: Vector3, radial: Vector3, radius: float, start_angle: float, end_angle: float, roundness: float) -> void:
	var span := lerpf(start_angle, end_angle, roundness)
	if absf(span - start_angle) < 0.0001:
		return
	var previous := center + (axis * cos(start_angle) + radial * sin(start_angle)) * radius
	for index in range(1, CONE_CAP_SEGMENTS + 1):
		var angle := lerpf(start_angle, span, float(index) / CONE_CAP_SEGMENTS)
		var point := center + (axis * cos(angle) + radial * sin(angle)) * radius
		vertices.append(previous)
		vertices.append(point)
		previous = point


func _append_sphere_at(vertices: PackedVector3Array, center: Vector3, radius: float, dashed: bool) -> void:
	for plane in 3:
		var first := (plane + 1) % 3
		var second := (plane + 2) % 3
		var u := Vector3.ZERO
		u[first] = 1.0
		var v := Vector3.ZERO
		v[second] = 1.0
		_append_ellipse_at(vertices, center, u, v, radius, radius, dashed)


## Appends one circle or ellipse. A dashed ellipse is split into short dashes so
## the blend wire stays lighter than the shape wire.
func _append_ellipse_at(vertices: PackedVector3Array, center: Vector3, u: Vector3, v: Vector3, radius_u: float, radius_v: float, dashed: bool) -> void:
	if dashed:
		var radius := maxf(radius_u, radius_v)
		var count := maxi(roundi(TAU * radius / maxf(_world_per_pixel * BLEND_DASH_SPAN_PX, 0.001)), 12)
		for index in count:
			var start_angle := TAU * index / count
			var end_angle := start_angle + TAU * 0.5 / count
			vertices.append(center + u * (cos(start_angle) * radius_u) + v * (sin(start_angle) * radius_v))
			vertices.append(center + u * (cos(end_angle) * radius_u) + v * (sin(end_angle) * radius_v))
		return
	for index in SHAPE_SEGMENTS:
		var start_angle := TAU * index / SHAPE_SEGMENTS
		var end_angle := TAU * (index + 1) / SHAPE_SEGMENTS
		vertices.append(center + u * (cos(start_angle) * radius_u) + v * (sin(start_angle) * radius_v))
		vertices.append(center + u * (cos(end_angle) * radius_u) + v * (sin(end_angle) * radius_v))


## Appends one dashed straight segment with a fixed screen dash length.
func _append_dashed_segment(vertices: PackedVector3Array, a: Vector3, b: Vector3) -> void:
	var length := a.distance_to(b)
	if length <= 0.0:
		return
	var dash := maxf(_world_per_pixel, 0.01) * BLEND_DASH_SPAN_PX * 0.5
	var count := maxi(roundi(length / (dash * 2.0)), 1)
	var direction := (b - a) / length
	for index in count:
		var start := a + direction * (index * 2.0 * dash)
		var end := a + direction * minf((index * 2.0 + 1.0) * dash, length)
		vertices.append(start)
		vertices.append(end)


## Draws the reach of the smooth blend as a dashed outer wire. The smooth union
## can reach this far into the existing cells.
func _append_blend(vertices: PackedVector3Array) -> void:
	match int(_primitive.get("kind", -1)):
		PrimitiveField.KIND_ELLIPSOID:
			var center: Vector3 = _primitive.get("center", _pivot)
			var radii: Vector3 = _primitive.get("radii", _box.size * 0.5)
			var rotation := _rotation
			if _primitive.get("rotation", null) != null:
				rotation = PrimitiveField.primitive_rotation(_primitive)
			_append_ellipsoid_at(vertices, center, radii + Vector3.ONE * _blend, rotation, true)
		PrimitiveField.KIND_CONE:
			var a: Vector3 = _primitive.get("a", _pivot)
			var b: Vector3 = _primitive.get("b", _pivot)
			var axis := b - a
			if axis.length_squared() <= 0.000001:
				return
			axis = axis.normalized()
			var r1 := float(_primitive.get("r1", 0.0)) + _blend
			var r2 := float(_primitive.get("r2", 0.0)) + _blend
			_append_cone_at(vertices, a - axis * _blend, b + axis * _blend, r1, r2, 0.0, true)
		_:
			var expanded := AABB(_box.position - Vector3.ONE * _blend, _box.size + Vector3.ONE * _blend * 2.0)
			_append_box_at(vertices, expanded, true)


func _rebuild_rings() -> void:
	if _rings == null:
		return
	var vertices := PackedVector3Array()
	_ring_mask = _visible_ring_mask()
	if _rings_shown:
		for axis in 3:
			if not (_ring_mask & (1 << axis)):
				continue
			if axis == _hot_ring:
				continue
			_append_dashed_ring(vertices, axis)
	_rings.mesh = VoxelLineMesh.build(vertices)
	_rings.visible = not vertices.is_empty()


func _append_dashed_ring(vertices: PackedVector3Array, axis: int) -> void:
	var first := (axis + 1) % 3
	var second := (axis + 2) % 3
	for index in _ring_dashes:
		var start_angle := TAU * index / _ring_dashes
		var end_angle := start_angle + TAU * 0.5 / _ring_dashes
		var start := _local_center
		var end := _local_center
		start[first] += cos(start_angle) * _ring_radius
		start[second] += sin(start_angle) * _ring_radius
		end[first] += cos(end_angle) * _ring_radius
		end[second] += sin(end_angle) * _ring_radius
		_append_line(vertices, start, end)


func _rebuild_hot() -> void:
	if _hot == null:
		return
	var vertices := PackedVector3Array()
	if _has_box and _show_handles:
		if _hot_ring >= 0 and (_visible_ring_mask() & (1 << _hot_ring)):
			_append_solid_ring(vertices, _hot_ring)
		if not _hot_handle.is_empty():
			_append_hot_handle(vertices)
	_hot.mesh = VoxelLineMesh.build(vertices)
	_hot.visible = not vertices.is_empty()


func _append_solid_ring(vertices: PackedVector3Array, axis: int) -> void:
	var first := (axis + 1) % 3
	var second := (axis + 2) % 3
	for index in RING_SEGMENTS:
		var start_angle := TAU * index / RING_SEGMENTS
		var end_angle := TAU * (index + 1) / RING_SEGMENTS
		var start := _local_center
		var end := _local_center
		start[first] += cos(start_angle) * _ring_radius
		start[second] += sin(start_angle) * _ring_radius
		end[first] += cos(end_angle) * _ring_radius
		end[second] += sin(end_angle) * _ring_radius
		_append_line(vertices, start, end)


func _append_hot_handle(vertices: PackedVector3Array) -> void:
	if int(_hot_handle.get("kind", 0)) == 1:
		var signs: Vector3i = _hot_handle.get("signs", Vector3i.ZERO)
		var point := _box.get_center()
		point.x = _box.position.x if signs.x < 0 else _box.end.x
		point.y = _box.position.y if signs.y < 0 else _box.end.y
		point.z = _box.position.z if signs.z < 0 else _box.end.z
		_append_corner(vertices, point, _corner_half)
		return
	var axis := int(_hot_handle.get("axis", -1))
	var side := int(_hot_handle.get("side", 0))
	if axis < 0 or side == 0:
		return
	_append_handle(vertices, axis, _face_center(axis, side), _handle_half)


func _append_corner(vertices: PackedVector3Array, center: Vector3, half: float) -> void:
	for axis in 3:
		var start := center
		var end := center
		start[axis] -= half
		end[axis] += half
		_append_line(vertices, start, end)


func _append_handle(vertices: PackedVector3Array, axis: int, center: Vector3, half: float) -> void:
	var first := (axis + 1) % 3
	var second := (axis + 2) % 3
	var a := center
	var b := center
	a[first] -= half
	b[first] += half
	_append_line(vertices, a, b)
	a = center
	b = center
	a[second] -= half
	b[second] += half
	_append_line(vertices, a, b)
