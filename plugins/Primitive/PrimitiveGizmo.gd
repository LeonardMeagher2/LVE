extends MeshInstance3D

## The pending primitive bounds and its six face handles.
##
## The gizmo draws a wire box and a small cross at each face center. The tool
## hit-tests the crosses in screen space and drags one face of the box.

const VoxelLineMesh := preload("res://Globals/Rendering/VoxelLineMesh.gd")
const HANDLE_HALF := 0.35

var _box := AABB()
var _has_box := false
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


## Shows the pending box. [param axis] and [param side] select the highlighted
## face. A negative axis hides the highlight. [param show_handles] draws the
## face crosses. A live drag uses the box alone.
func show_box(box: AABB, axis := -1, side := 0, show_handles := true) -> void:
	_box = box
	_has_box = true
	_rebuild(show_handles)
	if not show_handles or axis < 0 or side == 0:
		_highlight.visible = false
	else:
		_highlight.mesh = _handle_mesh(axis, side)
		_highlight.visible = true
	visible = true


## Hides the box and its handles.
func hide_box() -> void:
	_has_box = false
	visible = false
	if _highlight != null:
		_highlight.visible = false


## Returns the world position of one face handle.
func handle_position(axis: int, side: int) -> Vector3:
	var center := _box.get_center()
	center[axis] = _box.position[axis] if side < 0 else _box.end[axis]
	return center


## Returns the six face handles and the eight corner handles.
func handles() -> Array:
	var result: Array = []
	if not _has_box:
		return result
	for axis in 3:
		for side in [-1, 1]:
			result.append({"kind": 0, "axis": axis, "side": side, "position": handle_position(axis, side)})
	for x in [-1, 1]:
		for y in [-1, 1]:
			for z in [-1, 1]:
				var signs := Vector3i(x, y, z)
				var point := _box.get_center()
				point.x = _box.position.x if x < 0 else _box.end.x
				point.y = _box.position.y if y < 0 else _box.end.y
				point.z = _box.position.z if z < 0 else _box.end.z
				result.append({"kind": 1, "axis": -1, "side": 0, "signs": signs, "position": point})
	return result


func _rebuild(show_handles: bool) -> void:
	var vertices := PackedVector3Array()
	var low := _box.position
	var high := _box.end
	var corners: Array[Vector3] = [
		Vector3(low.x, low.y, low.z),
		Vector3(high.x, low.y, low.z),
		Vector3(high.x, high.y, low.z),
		Vector3(low.x, high.y, low.z),
		Vector3(low.x, low.y, high.z),
		Vector3(high.x, low.y, high.z),
		Vector3(high.x, high.y, high.z),
		Vector3(low.x, high.y, high.z),
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
				_append_handle(vertices, axis, side, handle_position(axis, side))
		for x in [-1, 1]:
			for y in [-1, 1]:
				for z in [-1, 1]:
					var point := _box.get_center()
					point.x = _box.position.x if x < 0 else _box.end.x
					point.y = _box.position.y if y < 0 else _box.end.y
					point.z = _box.position.z if z < 0 else _box.end.z
					_append_corner(vertices, point)
	mesh = VoxelLineMesh.build(vertices)


func _handle_mesh(axis: int, side: int) -> ArrayMesh:
	var vertices := PackedVector3Array()
	_append_handle(vertices, axis, side, handle_position(axis, side))
	return VoxelLineMesh.build(vertices)


func _append_corner(vertices: PackedVector3Array, center: Vector3) -> void:
	for axis in 3:
		var start := center
		var end := center
		start[axis] -= HANDLE_HALF
		end[axis] += HANDLE_HALF
		vertices.append(start)
		vertices.append(end)


func _append_handle(vertices: PackedVector3Array, axis: int, side: int, center: Vector3) -> void:
	var first := (axis + 1) % 3
	var second := (axis + 2) % 3
	var a := center
	var b := center
	a[first] -= HANDLE_HALF
	b[first] += HANDLE_HALF
	vertices.append(a)
	vertices.append(b)
	a = center
	b = center
	a[second] -= HANDLE_HALF
	b[second] += HANDLE_HALF
	vertices.append(a)
	vertices.append(b)
