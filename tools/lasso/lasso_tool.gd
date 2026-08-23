class_name LassoSelectTool
extends VoxelTool

var _points: Array[Vector3i] = []
var _press_target := State.NONE
var _shift := false
var _line_mat: StandardMaterial3D


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	var r := _ray(pos)
	var origin: Vector3 = r[0]
	var dir: Vector3 = r[1]
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			begin_stroke()
			_shift = mb.shift_pressed
			var pick := _pick_start(origin, dir)
			_plane = pick.plane
			_press_target = pick.target
			_last_target = pick.target
			_points.clear()
			if pick.target != State.NONE:
				_points.append(pick.target)
			_stroke_active = true
			_update_line()
			return true
		else:
			if _stroke_active:
				_stroke_active = false
				_commit()
				hide_visual()
				_end()
			return true
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _stroke_active and _plane != null and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var pick := _pick_drag(origin, dir)
			if pick.target != State.NONE and pick.target != _last_target:
				_points.append(pick.target)
				_last_target = pick.target
				_update_line()
			return true
		return false
	return false


func _commit() -> void:
	if _points.size() >= 3:
		var region := VoxelSelection.new()
		_fill_polygon(region)
		if _shift:
			State.selection.union(region)
		else:
			State.selection.cells = region.cells
	elif not State.selection.is_empty():
		State.selection.clear()
	elif _press_target != State.NONE \
			and State.document.has_cell(State.current_frame, _press_target):
		State.selection.add(_press_target)
	State.selection_changed.emit()


func _fill_polygon(sel: VoxelSelection) -> void:
	var poly := PackedVector2Array()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in _points:
		var q := _project(p)
		poly.append(q)
		lo.x = minf(lo.x, q.x)
		lo.y = minf(lo.y, q.y)
		hi.x = maxf(hi.x, q.x)
		hi.y = maxf(hi.y, q.y)
	for x in range(floori(lo.x), ceili(hi.x) + 1):
		for y in range(floori(lo.y), ceili(hi.y) + 1):
			if _point_in_poly(Vector2(x, y), poly):
				sel.add(_unproject(Vector2i(x, y)))


func _point_in_poly(p: Vector2, poly: PackedVector2Array) -> bool:
	var inside := false
	var j := poly.size() - 1
	for i in poly.size():
		var a := poly[i]
		var b := poly[j]
		if (a.y > p.y) != (b.y > p.y):
			var cross: float = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
			if p.x < cross:
				inside = not inside
		j = i
	return inside


func _project(c: Vector3i) -> Vector2:
	match _plane.axis:
		0:
			return Vector2(c.y, c.z)
		1:
			return Vector2(c.x, c.z)
	return Vector2(c.x, c.y)


func _unproject(q: Vector2i) -> Vector3i:
	match _plane.axis:
		0:
			return Vector3i(_plane.idx, q.x, q.y)
		1:
			return Vector3i(q.x, _plane.idx, q.y)
	return Vector3i(q.x, q.y, _plane.idx)


func _update_line() -> void:
	if visual == null:
		return
	if _points.is_empty():
		visual.visible = false
		return
	var off := _normal() * 0.55
	var pts := PackedVector3Array()
	for i in range(1, _points.size()):
		pts.append(Vector3(_points[i - 1]) + off)
		pts.append(Vector3(_points[i]) + off)
	if _points.size() >= 3:
		pts.append(Vector3(_points[_points.size() - 1]) + off)
		pts.append(Vector3(_points[0]) + off)
	if pts.is_empty():
		visual.visible = false
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, MeshUtil.vertex_arrays(pts))
	(visual as MeshInstance3D).mesh = mesh
	visual.position = Vector3.ZERO
	visual.visible = true


func _normal() -> Vector3:
	var n := Vector3.ZERO
	n[_plane.axis] = 1.0
	return n


func _build_visual() -> Node3D:
	_line_mat = StandardMaterial3D.new()
	_line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_line_mat.no_depth_test = true
	_line_mat.albedo_color = Color(0.4, 0.7, 1.0, 0.9)
	var mi := MeshInstance3D.new()
	mi.mesh = ArrayMesh.new()
	mi.material_override = _line_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
