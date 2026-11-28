class_name VoxelTool
extends Node3D


var _plane: StrokePlane = null
var _last_target := VoxelPicking.NONE
var _stroke_active := false
var _cells_dirty := false
var _affected: Array[Vector3i] = []
var _edit: VoxelEditTransaction


func _unhandled_input(event: InputEvent) -> void:
	if not _accepts(event):
		return
	var input_viewport := get_viewport()
	if input_viewport == null:
		return
	if State.edit_busy(self):
		return
	var pos := Vector2.ZERO
	if event is InputEventMouse:
		pos = (event as InputEventMouse).position
	if handle_input(event, pos):
		input_viewport.set_input_as_handled()


func _ray(pos: Vector2) -> Array:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return [Vector3.ZERO, Vector3.ZERO]
	return [cam.project_ray_origin(pos), cam.project_ray_normal(pos)]


func _forward() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Vector3.BACK
	return -cam.basis.z


func _accepts(event: InputEvent) -> bool:
	return event is InputEventMouseButton or event is InputEventMouseMotion or event is InputEventKey


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	var r := _ray(pos)
	var origin: Vector3 = r[0]
	var dir: Vector3 = r[1]
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			if _stroke_active:
				return true
			if open_stroke() == null:
				return false
			var pick := _pick_start(origin, dir)
			if pick == null:
				abort_stroke()
				return false
			_plane = pick.plane
			_last_target = pick.target
			_stroke_active = true
			if pick.target != VoxelPicking.NONE:
				_apply_pick(pick.target, pick.hit)
			update_visual(pick)
		else:
			if _stroke_active:
				_end()
		return true
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _stroke_active and _plane != null and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var pick := _pick_drag(origin, dir)
			if pick.target != _last_target and pick.target != VoxelPicking.NONE:
				_apply_stroke_to(pick.target)
				_last_target = pick.target
			update_visual(pick)
			return true
		if mm.button_mask == 0:
			if _stroke_active:
				_end()
			update_visual(_pick_start(origin, dir))
			return true
		return false
	return false


func _apply_pick(target: Vector3i, hit: Vector3i) -> void:
	if not apply(target, hit):
		return
	for c in applied_cells(target, hit):
		_affected.append(c)
	_flush_cells()


func _apply_stroke_to(to: Vector3i) -> void:
	for c in StrokeLine.cells(_last_target, to):
		if c == _last_target:
			continue
		_apply_pick(c, _hit_at(c))


func _hit_at(c: Vector3i) -> Vector3i:
	if State.document.has_cell(State.current_frame, c):
		return c
	return VoxelPicking.NONE


func colors_equal(a: Color, b: Color, epsilon:float = 0.0) -> bool:
	if epsilon <= 0.0:
		return a == b
	return (
		absf(a.r - b.r) <= epsilon and absf(a.g - b.g) <= epsilon and
		absf(a.b - b.b) <= epsilon and absf(a.a - b.a) <= epsilon
	)

func apply(_target: Vector3i, _hit: Vector3i) -> bool:
	return false


func applied_cells(target: Vector3i, hit: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if target != VoxelPicking.NONE:
		out.append(target)
	if hit != VoxelPicking.NONE and hit != target:
		out.append(hit)
	return out


func _end() -> void:
	_flush_cells()
	_plane = null
	_last_target = VoxelPicking.NONE
	_stroke_active = false
	close_stroke()


func _flush_cells() -> void:
	if _cells_dirty:
		return
	_cells_dirty = true
	call_deferred("_do_flush")


func _do_flush() -> void:
	_cells_dirty = false
	if _affected.is_empty():
		return
	State.cells_changed.emit(State.active_layer_index, State.current_frame, _affected)
	_affected.clear()


func open_stroke() -> VoxelEditTransaction:
	if _edit != null and _edit.is_closed():
		_edit = null
	if _edit == null:
		_edit = State.begin_edit()
	return _edit


func close_stroke(action: String = "Stroke") -> void:
	var tx := _edit
	if tx == null:
		return
	_edit = null
	State.finish_edit(tx, action)


func abort_stroke() -> void:
	var tx := _edit
	if tx == null:
		return
	_edit = null
	State.cancel_edit(tx)


func cancel_stroke() -> void:
	_plane = null
	_last_target = VoxelPicking.NONE
	_stroke_active = false
	_cells_dirty = false
	_affected.clear()
	abort_stroke()


func _pick_start(origin: Vector3, dir: Vector3) -> PickResult:
	return pick_start(_request(origin, dir, null))


func _pick_drag(origin: Vector3, dir: Vector3) -> PickResult:
	return pick_drag(_request(origin, dir, _plane))


func _request(origin: Vector3, dir: Vector3, plane: StrokePlane) -> PickRequest:
	var req := PickRequest.new()
	req.origin = origin
	req.direction = dir
	req.frame = State.get_current_voxel_frame()
	req.plane = plane
	req.forward = _forward()
	req.slice = State.slice_enabled
	return req


func pick_start(request: PickRequest) -> PickResult:
	return VoxelPicking.start_pick(request.origin, request.direction, request.frame, request.forward, request.slice)


func pick_drag(request: PickRequest) -> PickResult:
	return VoxelPicking.drag_pick(request.origin, request.direction, request.frame, request.plane)


func update_visual(pick: PickResult) -> void:
	if pick.target == VoxelPicking.NONE:
		visible = false
		return
	position = Vector3(pick.target)
	visible = true


func driver_plane(cell: Vector3i) -> StrokePlane:
	var axis := 1
	var view := get_viewport()
	if view != null:
		var camera := view.get_camera_3d()
		if camera != null:
			var forward := -camera.global_transform.basis.z
			var amount := Vector3(absf(forward.x), absf(forward.y), absf(forward.z))
			if amount.x >= amount.y and amount.x >= amount.z:
				axis = 0
			elif amount.z >= amount.y:
				axis = 2
	var plane := StrokePlane.new()
	plane.axis = axis
	plane.cell_index = cell[axis]
	plane.point = Vector3(cell)
	plane.normal = Vector3.ZERO
	plane.normal[axis] = 1.0
	return plane


func driver_show_cursor(cell: Vector3i, hit: Vector3i) -> void:
	if cell == VoxelPicking.NONE:
		visible = false
		return
	var pick := PickResult.new()
	pick.target = cell
	pick.hit = hit
	pick.plane = _plane if _plane != null else driver_plane(cell)
	update_visual(pick)


func driver_begin_stroke(cell: Vector3i, hit: Vector3i) -> bool:
	if open_stroke() == null:
		return false
	_stroke_active = true
	_plane = driver_plane(cell)
	_last_target = cell
	_apply_pick(cell, hit)
	driver_show_cursor(cell, hit)
	return true


func driver_stroke_to(cell: Vector3i) -> void:
	if _edit == null:
		return
	_apply_stroke_to(cell)
	_last_target = cell
	driver_show_cursor(cell, cell if _paints_existing() else VoxelPicking.NONE)


func driver_end_stroke() -> void:
	if _edit == null:
		return
	_end()


func driver_is_busy() -> bool:
	return _edit != null


func _paints_existing() -> bool:
	return false
