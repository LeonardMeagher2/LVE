class_name TransformTool
extends VoxelTool

var _grabbed := false
var _pending := false
var _dragged := false
var _cells: Array[Vector3i] = []
var _colors := {}
var _base_cells := {}
var _dest_cells: Array[Vector3i] = []


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event is InputEventMouseButton:
		return _on_mouse_button(event, pos)
	if event is InputEventMouseMotion:
		return _on_mouse_motion(event, pos)
	if event is InputEventKey:
		return _on_key(event)
	return false


func _exit_tree() -> void:
	if _pending or _stroke_active:
		_restore_snapshot(_stroke_before)
	_stroke_active = false
	_grabbed = false
	_pending = false
	_clear_grab()


func _on_mouse_button(event: InputEventMouseButton, pos: Vector2) -> bool:
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return false
	var ray := _ray(pos)
	if mb.pressed:
		_press(ray[0], ray[1])
	else:
		_release()
	return true


func _on_mouse_motion(event: InputEventMouseMotion, pos: Vector2) -> bool:
	var mm := event as InputEventMouseMotion
	var ray := _ray(pos)
	if _stroke_active and _plane != null and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
		var pick := _pick_drag(ray[0], ray[1])
		if _grabbed and _update_params(pick, ray[0], ray[1]):
			_apply_preview()
		update_visual(pick)
		return true
	if mm.button_mask == 0:
		update_visual(_pick_start(ray[0], ray[1]))
		return true
	return false


func _on_key(event: InputEventKey) -> bool:
	if event.is_action_pressed("ui_cancel"):
		if _stroke_active:
			return true
	if _stroke_active:
		return true
	return _key_action(event)


func _press(origin: Vector3, dir: Vector3) -> void:
	var pick := _pick_start(origin, dir)
	_plane = pick.plane
	_last_target = pick.target
	_stroke_active = true
	_dragged = false
	if pick.hit != VoxelPicking.NONE and (State.selection.is_empty() or State.selection.contains(pick.hit)):
		_grabbed = true
		if not _pending:
			begin_stroke()
			_cells = _grab_cells()
			var cells: Dictionary = State.document.frames[State.current_frame].cells
			_colors = {}
			for c in _cells:
				if cells.has(c):
					_colors[c] = cells[c]
			_base_cells = cells.duplicate()
			_begin_grab(pick, origin, dir)
		else:
			_regrab(pick, origin, dir)
	elif _pending:
		_cancel_pending()
	update_visual(pick)


func _release() -> void:
	if not _stroke_active:
		return
	_stroke_active = false
	_grabbed = false
	if _dragged:
		_pending = true
	elif _pending:
		_commit()
	else:
		_clear_grab()
		_end()


func _apply_preview() -> void:
	_dragged = true
	var preview: Dictionary = _base_cells.duplicate()
	for c in _colors:
		preview.erase(c)
	_dest_cells = []
	var box := _dest_bbox()
	var lo := box.position.floor() - Vector3.ONE
	var hi := box.end.ceil() + Vector3.ONE
	for x in range(int(lo.x), int(hi.x) + 1):
		for y in range(int(lo.y), int(hi.y) + 1):
			for z in range(int(lo.z), int(hi.z) + 1):
				var d := Vector3i(x, y, z)
				var s := _map_source(d)
				if _colors.has(s):
					preview[d] = _colors[s]
					_dest_cells.append(d)
	State.document.frames[State.current_frame].cells = preview
	State.cells_changed.emit()


func _commit() -> void:
	if not _pending:
		return
	_finish_pending()


func _cancel_pending() -> void:
	if not _pending:
		return
	_restore_snapshot(_stroke_before)
	_finish_pending()


func _finish_pending() -> void:
	_clear_grab()
	_pending = false
	_end()


func _clear_grab() -> void:
	_cells = []
	_colors = {}
	_base_cells = {}
	_dest_cells = []


func _grab_cells() -> Array[Vector3i]:
	if not State.selection.is_empty():
		return State.selection.to_array()
	var out: Array[Vector3i] = []
	for c in State.document.frames[State.current_frame].cells:
		out.append(c)
	return out


func _plane_point(origin: Vector3, dir: Vector3) -> Vector3:
	if _plane == null:
		return Vector3.ZERO
	var denom: float = dir.dot(_plane.normal)
	if absf(denom) < 1e-8:
		return Vector3.ZERO
	var t: float = (_plane.point - origin).dot(_plane.normal) / denom
	if t <= 0.0:
		return Vector3.ZERO
	return origin + dir * t


func _source_bbox() -> AABB:
	var b := AABB()
	var first := true
	for c in _cells:
		var cb := AABB(Vector3(c), Vector3.ONE)
		b = cb if first else b.merge(cb)
		first = false
	return b


func _begin_grab(_pick: PickResult, _origin: Vector3, _dir: Vector3) -> void:
	pass


func _regrab(_pick: PickResult, _origin: Vector3, _dir: Vector3) -> void:
	pass


func _update_params(_pick: PickResult, _origin: Vector3, _dir: Vector3) -> bool:
	return false


func _dest_bbox() -> AABB:
	return AABB()


func _map_source(_d: Vector3i) -> Vector3i:
	return _d


func _key_action(_event: InputEventKey) -> bool:
	return false
