class_name MoveTool
extends VoxelTool

var _grabbed := false
var _pending := false
var _dragged := false
var _grab_target := State.NONE
var _cells: Array[Vector3i] = []
var _colors := {}
var _covered := {}
var _offset := Vector3i.ZERO


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event is InputEventMouseButton:
		return _on_mouse_button(event, pos)
	if event is InputEventMouseMotion:
		return _on_mouse_motion(event, pos)
	if event is InputEventKey:
		return _on_key(event)
	return false


func on_deactivated() -> void:
	_cancel_pending()


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
		if _grabbed and pick.target != _last_target and pick.target != State.NONE:
			_last_target = pick.target
			_move_to(pick.target)
		update_visual(pick)
		return true
	if mm.button_mask == 0:
		update_visual(_pick_start(ray[0], ray[1]))
		return true
	return false


func _on_key(event: InputEventKey) -> bool:
	if event.is_action_pressed("ui_cancel"):
		if _pending:
			_cancel_pending()
		elif _stroke_active:
			return true
		else:
			_clear_selection()
		return true
	if event.is_action_pressed("ui_accept"):
		if _pending:
			_commit()
		return true
	if _stroke_active or _pending:
		return true
	if event.is_action_pressed("ui_left"):
		_nudge(Vector3i(-1, 0, 0))
		return true
	if event.is_action_pressed("ui_right"):
		_nudge(Vector3i(1, 0, 0))
		return true
	if event.is_action_pressed("ui_up"):
		_nudge(Vector3i(0, 1, 0))
		return true
	if event.is_action_pressed("ui_down"):
		_nudge(Vector3i(0, -1, 0))
		return true
	return false


func _press(origin: Vector3, dir: Vector3) -> void:
	var pick := _pick_start(origin, dir)
	_plane = pick.plane
	_last_target = pick.target
	_stroke_active = true
	_dragged = false
	if pick.hit != State.NONE and (State.selection.is_empty() or State.selection.contains(pick.hit)):
		_grabbed = true
		if not _pending:
			begin_stroke()
			_cells = _grab_cells()
			_grab_target = pick.target
			_offset = Vector3i.ZERO
			var cells: Dictionary = State.document.frames[State.current_frame].cells
			_colors = {}
			_covered = {}
			for c in _cells:
				if cells.has(c):
					_colors[c] = cells[c]
		else:
			_grab_target = pick.target - _offset
	elif not State.selection.is_empty():
		if _pending:
			_cancel_pending()
		begin_stroke()
		State.selection.clear()
		State.selection_changed.emit()
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
		_cells = []
		_colors = {}
		_covered = {}
		_end()


func _move_to(target: Vector3i) -> void:
	var new_offset: Vector3i = target - _grab_target
	if new_offset == _offset:
		return
	_dragged = true
	var cells: Dictionary = State.document.frames[State.current_frame].cells
	for c in _cells:
		if _colors.has(c):
			cells.erase(c + _offset)
	for pos in _covered:
		cells[pos] = _covered[pos]
	_covered = {}
	for c in _cells:
		if _colors.has(c):
			var dest: Vector3i = c + new_offset
			if cells.has(dest):
				_covered[dest] = cells[dest]
	for c in _cells:
		if _colors.has(c):
			var dest: Vector3i = c + new_offset
			cells[dest] = _colors[c]
	_offset = new_offset
	_sync_selection()
	State.cells_changed.emit()


func _commit() -> void:
	if not _pending:
		return
	State.selection.clear()
	State.selection_changed.emit()
	_cells = []
	_colors = {}
	_covered = {}
	_offset = Vector3i.ZERO
	_pending = false
	_end()


func _cancel_pending() -> void:
	if not _pending:
		return
	_restore_snapshot(_stroke_before)
	_cells = []
	_colors = {}
	_covered = {}
	_offset = Vector3i.ZERO
	_pending = false
	_end()


func _grab_cells() -> Array[Vector3i]:
	if not State.selection.is_empty():
		return State.selection.to_array()
	var out: Array[Vector3i] = []
	for c in State.document.frames[State.current_frame].cells:
		out.append(c)
	return out


func _sync_selection() -> void:
	State.selection.clear()
	for c in _cells:
		State.selection.add(c + _offset)
	State.selection_changed.emit()


func _clear_selection() -> void:
	if State.selection.is_empty():
		return
	begin_stroke()
	State.selection.clear()
	State.selection_changed.emit()
	_end()


func _nudge(offset: Vector3i) -> void:
	if State.selection.is_empty():
		return
	begin_stroke()
	var sel := State.selection.to_array()
	var moved: Dictionary = {}
	for c in sel:
		if State.document.has_cell(State.current_frame, c):
			moved[c] = State.document.frames[State.current_frame].cells[c]
	for c in moved:
		State.document.erase(State.current_frame, c)
	for c in moved:
		State.document.set_cell(State.current_frame, c + offset, moved[c])
	if not moved.is_empty():
		State.selection.clear()
		for c in sel:
			State.selection.add(c + offset)
		State.cells_changed.emit()
		State.selection_changed.emit()
	_end()
