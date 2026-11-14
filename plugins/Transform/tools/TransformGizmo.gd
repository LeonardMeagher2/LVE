extends MeshInstance3D

## The camera-facing transform pivot gizmo.
##
## Move and Scale draw one fixed view-plane handle. Rotate draws a joint square
## with quarter-turn arrows at the pivot. A bone to the pointer appears during a
## drag. The fixed handles keep a constant screen size. The gizmo draws over
## geometry.

const VoxelLineMesh := preload("res://Globals/Rendering/VoxelLineMesh.gd")

## The shape that the gizmo draws.
enum Kind {
	## Four view-plane arrows.
	MOVE,
	## A bone from the pivot to the pointer.
	ROTATE,
	## A view-plane square with corner arrows.
	SCALE,
}

## The handle radius in screen pixels.
const RADIUS_PX := 64.0
## The Move arrow reach as a fraction of the handle radius.
const MOVE_REACH := 0.25
## The Move arrow shaft start as a fraction of the handle radius.
const MOVE_INNER := 0.06
## The Move arrowhead length as a fraction of the handle radius.
const MOVE_HEAD := 0.09
## The Move arrowhead half width as a fraction of the handle radius.
const MOVE_SIDE := 0.055
## The Move center square half size as a fraction of the handle radius.
const MOVE_CENTER := 0.04
## The Scale square reach as a fraction of the handle radius.
const SCALE_REACH := 0.25
## The Scale arrow shaft start as a fraction of the handle radius.
const SCALE_INNER := 0.07
## The Scale arrowhead length as a fraction of the handle radius.
const SCALE_HEAD := 0.08
## The Scale arrowhead half width as a fraction of the handle radius.
const SCALE_SIDE := 0.055
## The Scale center square half size as a fraction of the handle radius.
const SCALE_CENTER := 0.04
## The half size of the Rotate joint square in screen pixels.
const JOINT_HALF_PX := 7.0
## The Rotate mark arc radius in screen pixels.
const ROTATE_ARC_PX := 8.0
## The Rotate mark arrowhead length in screen pixels.
const ROTATE_HEAD_PX := 4.0
## The Rotate mark arrowhead half width in screen pixels.
const ROTATE_SIDE_PX := 2.5
## The line segments in one Rotate mark arc.
const ROTATE_ARC_SEGMENTS := 8

## The shape to draw.
@export var kind: Kind = Kind.MOVE

var _pivot := Vector3.ZERO
var _has_pivot := false
var _pointer := Vector2.INF
var _plane_normal := Vector3.ZERO
var _last_tip := Vector3.ZERO
var _has_tip := false
var _dragging := false
var _size_viewport: Viewport


func _ready() -> void:
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.WHITE
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = 1
	material_override = material
	if kind != Kind.ROTATE:
		mesh = _build_static_mesh(kind)
	visible = false


func _enter_tree() -> void:
	_size_viewport = get_viewport()
	if _size_viewport != null and not _size_viewport.size_changed.is_connected(_on_viewport_size_changed):
		_size_viewport.size_changed.connect(_on_viewport_size_changed)
	refresh_pose()


func _exit_tree() -> void:
	if is_instance_valid(_size_viewport) and _size_viewport.size_changed.is_connected(_on_viewport_size_changed):
		_size_viewport.size_changed.disconnect(_on_viewport_size_changed)
	_size_viewport = null


## Shows the gizmo at one pivot.
func show_at(pivot: Vector3) -> void:
	if not _has_pivot or not _pivot.is_equal_approx(pivot):
		_has_tip = false
	_pivot = pivot
	_has_pivot = true
	_pose()


## Hides the gizmo.
func hide_gizmo() -> void:
	_has_pivot = false
	visible = false


## Sets the pointer that the Rotate bone points at. A nonzero plane normal uses
## the plane that the drag captured.
func set_pointer(screen_pos: Vector2, plane_normal := Vector3.ZERO) -> void:
	if screen_pos == _pointer and plane_normal == _plane_normal:
		return
	_pointer = screen_pos
	_plane_normal = plane_normal
	if _has_pivot and kind == Kind.ROTATE:
		_pose()


## Shows or hides the Rotate bone. The joint marks stay visible.
func set_dragging(dragging: bool) -> void:
	if dragging == _dragging:
		return
	_dragging = dragging
	if _has_pivot and kind == Kind.ROTATE:
		_pose()


## Poses the gizmo again after a camera or viewport change.
func refresh_pose() -> void:
	if _has_pivot:
		_pose()


func _on_viewport_size_changed() -> void:
	refresh_pose()


func _pose() -> void:
	if not _has_pivot or not is_inside_tree():
		visible = false
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		visible = false
		return
	if kind == Kind.ROTATE:
		_pose_rotate(camera)
	else:
		_pose_fixed(camera)


func _pose_fixed(camera: Camera3D) -> void:
	var world_px := _world_per_pixel(camera, _pivot)
	if world_px <= 0.0:
		visible = false
		return
	global_transform = Transform3D(camera.global_transform.basis.scaled(Vector3.ONE * world_px * RADIUS_PX), _pivot)
	visible = true


func _pose_rotate(camera: Camera3D) -> void:
	var world_px := _world_per_pixel(camera, _pivot)
	if world_px <= 0.0:
		visible = false
		return
	var basis := camera.global_transform.basis
	var vertices := PackedVector3Array()
	if _dragging:
		var pointer := _pointer
		if pointer == Vector2.INF:
			pointer = get_viewport().get_mouse_position()
		var normal := _plane_normal if not _plane_normal.is_zero_approx() else -basis.z
		var tip := _pivot + basis.x * (world_px * RADIUS_PX) if not _has_tip else _last_tip
		var origin := camera.project_ray_origin(pointer)
		var direction := camera.project_ray_normal(pointer)
		var denom := direction.dot(normal)
		if absf(denom) > 0.000001:
			var t: float = (_pivot - origin).dot(normal) / denom
			if t > 0.0:
				tip = origin + direction * t
				_last_tip = tip
				_has_tip = true
		_append_line(vertices, Vector3.ZERO, basis.inverse() * (tip - _pivot))
	else:
		_has_tip = false
	var half := world_px * JOINT_HALF_PX
	_append_square(vertices, Vector3.ZERO, half)
	_append_rotate_marks(vertices, half, world_px)
	mesh = VoxelLineMesh.build(vertices)
	global_transform = Transform3D(basis, _pivot)
	visible = true


# Returns the world distance that one screen pixel covers at one point.
func _world_per_pixel(camera: Camera3D, point: Vector3) -> float:
	if camera.is_position_behind(point):
		return 0.0
	var depth := (point - camera.global_position).dot(-camera.global_transform.basis.z)
	if depth <= camera.near:
		return 0.0
	var center := camera.unproject_position(point)
	var first := camera.project_position(center, depth)
	var second := camera.project_position(center + Vector2(1.0, 0.0), depth)
	return first.distance_to(second)


func _build_static_mesh(gizmo_kind: Kind) -> ArrayMesh:
	var vertices := PackedVector3Array()
	match gizmo_kind:
		Kind.MOVE:
			_append_move(vertices)
		Kind.SCALE:
			_append_scale(vertices)
	return VoxelLineMesh.build(vertices)


func _append_move(vertices: PackedVector3Array) -> void:
	var directions: Array[Vector2] = [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]
	for direction in directions:
		var start := Vector3(direction.x * MOVE_INNER, direction.y * MOVE_INNER, 0.0)
		var end := Vector3(direction.x * MOVE_REACH, direction.y * MOVE_REACH, 0.0)
		_append_line(vertices, start, end)
		var back := Vector3(direction.x * (MOVE_REACH - MOVE_HEAD), direction.y * (MOVE_REACH - MOVE_HEAD), 0.0)
		var side := Vector3(-direction.y * MOVE_SIDE, direction.x * MOVE_SIDE, 0.0)
		_append_line(vertices, end, back + side)
		_append_line(vertices, end, back - side)
	_append_square(vertices, Vector3.ZERO, MOVE_CENTER)


func _append_scale(vertices: PackedVector3Array) -> void:
	var corners: Array[Vector2] = [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	for index in 4:
		_append_line(vertices, _corner(corners[index], SCALE_REACH), _corner(corners[(index + 1) % 4], SCALE_REACH))
	for corner in corners:
		var direction := corner.normalized()
		var end := _corner(corner, SCALE_REACH)
		_append_line(vertices, _corner(corner, SCALE_INNER), end)
		var back := corner * (SCALE_REACH - SCALE_HEAD)
		var side := Vector2(-direction.y, direction.x) * SCALE_SIDE
		_append_line(vertices, end, Vector3(back.x + side.x, back.y + side.y, 0.0))
		_append_line(vertices, end, Vector3(back.x - side.x, back.y - side.y, 0.0))
	_append_square(vertices, Vector3.ZERO, SCALE_CENTER)


func _corner(corner: Vector2, scale: float) -> Vector3:
	return Vector3(corner.x * scale, corner.y * scale, 0.0)


func _append_line(vertices: PackedVector3Array, first: Vector3, second: Vector3) -> void:
	vertices.append(first)
	vertices.append(second)


func _append_square(vertices: PackedVector3Array, center: Vector3, half: float) -> void:
	var points: Array[Vector3] = [
		center - Vector3.RIGHT * half - Vector3.UP * half,
		center + Vector3.RIGHT * half - Vector3.UP * half,
		center + Vector3.RIGHT * half + Vector3.UP * half,
		center - Vector3.RIGHT * half + Vector3.UP * half,
	]
	for index in 4:
		_append_line(vertices, points[index], points[(index + 1) % 4])


func _append_rotate_marks(vertices: PackedVector3Array, half: float, world_px: float) -> void:
	var radius := world_px * ROTATE_ARC_PX
	var head := world_px * ROTATE_HEAD_PX
	var side := world_px * ROTATE_SIDE_PX
	_append_arc_arrow(vertices, Vector2(half, half), radius, PI * 0.5, 0.0, head, side)
	_append_arc_arrow(vertices, Vector2(-half, -half), radius, PI * 1.5, PI, head, side)


func _append_arc_arrow(vertices: PackedVector3Array, center: Vector2, radius: float, start_angle: float, end_angle: float, head: float, side: float) -> void:
	var previous := center + Vector2(cos(start_angle), sin(start_angle)) * radius
	for index in range(1, ROTATE_ARC_SEGMENTS + 1):
		var angle := lerpf(start_angle, end_angle, float(index) / ROTATE_ARC_SEGMENTS)
		var point := center + Vector2(cos(angle), sin(angle)) * radius
		_append_line(vertices, _plane_point(previous), _plane_point(point))
		previous = point
	var direction := Vector2(sin(end_angle), -cos(end_angle))
	var end_point := center + Vector2(cos(end_angle), sin(end_angle)) * radius
	var back := end_point - direction * head
	var normal := Vector2(-direction.y, direction.x)
	_append_line(vertices, _plane_point(end_point), _plane_point(back + normal * side))
	_append_line(vertices, _plane_point(end_point), _plane_point(back - normal * side))


func _plane_point(point: Vector2) -> Vector3:
	return Vector3(point.x, point.y, 0.0)
