extends VoxelTool

var _settings := preload("../settings.tres")

var _dragging := false
var _pending := false
var _dragged := false
var _track_selection := false
var _cells: Array[Vector3i] = []
var _colors := {}
var _dest_cells: Array[Vector3i] = []
var _covered := {}


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event is InputEventMouseButton:
		return _on_mouse_button(event, pos)
	if event is InputEventMouseMotion:
		return _on_mouse_motion(event, pos)
	if event is InputEventKey:
		return _on_key(event)
	return false


func _enter_tree() -> void:
	_settings.commit_requested.connect(_commit)
	_settings.cancel_requested.connect(_cancel)


func _exit_tree() -> void:
	_settings.commit_requested.disconnect(_commit)
	_settings.cancel_requested.disconnect(_cancel)
	_commit()


func _on_mouse_button(event: InputEventMouseButton, pos: Vector2) -> bool:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false
	var ray := _ray(pos)
	if event.pressed:
		_press(ray[0], ray[1])
	else:
		_release()
	return true


func _on_mouse_motion(event: InputEventMouseMotion, pos: Vector2) -> bool:
	if _dragging and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		var ray := _ray(pos)
		if _update_params(ray[0], ray[1]):
			_apply_preview()
		return true
	return false


func _on_key(event: InputEventKey) -> bool:
	if event.is_action_pressed("ui_accept"):
		if _dragging or _pending:
			_commit()
			return true
		return false
	if event.is_action_pressed("ui_cancel"):
		if _dragging or _pending:
			_cancel()
			return true
		return false
	return false


func _press(origin: Vector3, dir: Vector3) -> void:
	if _dragging or _pending:
		_reanchor()
		_begin_grab(origin, dir)
		_dragging = true
		_dragged = false
		return
	var cells := _grab_cells()
	if cells.is_empty():
		return
	_track_selection = not State.selection.is_empty()
	begin_stroke()
	_cells = cells
	var frame: Dictionary = State.document.frames[State.current_frame].cells
	_colors = {}
	for c in _cells:
		if frame.has(c):
			_colors[c] = frame[c]
	_begin_grab(origin, dir)
	_settings.transforming = true
	_dragging = true
	_dragged = false


# Pressing again while a transform is already dragging or pending re-anchors it: the cells and
# colors currently on screen become the new working set, and _begin_grab starts fresh from there
# (fresh pivot, transform parameter reset to identity). The tool never resets to the original,
# pre-transform state on a regrab; only Cancel does that. The undo/redo boundary is unaffected,
# since it was captured once at the very first press and is not touched again until commit/cancel.
func _reanchor() -> void:
	if _dest_cells.is_empty():
		return
	var frame: Dictionary = State.document.frames[State.current_frame].cells
	var new_cells: Array[Vector3i] = []
	var new_colors := {}
	for c in _dest_cells:
		new_cells.append(c)
		if frame.has(c):
			new_colors[c] = frame[c]
	_cells = new_cells
	_colors = new_colors
	_dest_cells = []


func _release() -> void:
	if not _dragging:
		return
	_dragging = false
	if _dragged:
		_pending = true
	elif not _pending:
		_clear_grab()
		_settings.transforming = false
		_end()


func _apply_preview() -> void:
	_dragged = true
	var doc := State.document
	var frame := State.current_frame

	var new_dest: Dictionary = _compute_new_dest()

	var old_positions: Array[Vector3i] = _dest_cells if not _dest_cells.is_empty() else _cells
	var old_set := {}
	for c in old_positions:
		old_set[c] = true

	# Vacate cells the shape no longer covers, restoring anything it was hiding.
	for c in old_positions:
		if new_dest.has(c):
			continue
		if _covered.has(c):
			doc.set_cell(frame, c, _covered[c])
			_covered.erase(c)
		else:
			doc.erase(frame, c)

	# Occupy the new cells, caching (not destroying) anything already there.
	for d in new_dest:
		if not old_set.has(d) and not _covered.has(d) and doc.has_cell(frame, d):
			_covered[d] = doc.get_color_at(frame, d)
		doc.set_cell(frame, d, new_dest[d])

	if _track_selection:
		State.selection.cells.clear()
		for d in new_dest:
			State.selection.cells[d] = true
		State.selection_changed.emit()

	var affected := _changed_cells(old_set, new_dest)
	_dest_cells = []
	for d in new_dest:
		_dest_cells.append(d)
	State.cells_changed.emit(frame, affected)


func _changed_cells(old_set: Dictionary, new_dest: Dictionary) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for c in old_set:
		out.append(c)
	for c in new_dest:
		if not old_set.has(c):
			out.append(c)
	return out


func _commit() -> void:
	if not (_dragging or _pending):
		return
	_dragging = false
	_pending = false
	_clear_grab()
	_settings.transforming = false
	_end()


func _cancel() -> void:
	if not (_dragging or _pending):
		return
	_restore_snapshot(_stroke_before)
	_dragging = false
	_pending = false
	_clear_grab()
	_settings.transforming = false
	_end()


func _clear_grab() -> void:
	_cells = []
	_colors = {}
	_dest_cells = []
	_covered = {}


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


func _view_axis() -> int:
	var toward := -_forward()
	var fx: float = absf(toward.x)
	var fy: float = absf(toward.y)
	var fz: float = absf(toward.z)
	if fy >= fx and fy >= fz:
		return 1
	elif fz >= fx:
		return 2
	return 0


func _view_axis_sign() -> float:
	var toward := -_forward()
	var a := _view_axis()
	return 1.0 if toward[a] >= 0.0 else -1.0


func _view_plane_through(point: Vector3) -> StrokePlane:
	var p := StrokePlane.new()
	p.axis = _view_axis()
	p.idx = 0
	p.point = point
	var n := Vector3.ZERO
	n[p.axis] = 1.0
	p.normal = n
	return p


func _source_bbox() -> AABB:
	var b := AABB()
	var first := true
	for c in _cells:
		var cb := AABB(Vector3(c) - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
		b = cb if first else b.merge(cb)
		first = false
	return b


func _begin_grab(_origin: Vector3, _dir: Vector3) -> void:
	pass


func _update_params(_origin: Vector3, _dir: Vector3) -> bool:
	return false


func _map_dest(s: Vector3i) -> Vector3i:
	return s


func _compute_new_dest() -> Dictionary:
	var out: Dictionary = {}
	for s in _cells:
		if _colors.has(s):
			out[_map_dest(s)] = _colors[s]
	return out