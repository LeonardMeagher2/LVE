class_name WandSelectTool
extends SelectionTool


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
			_commit(pick.target)
			_end()
		return true
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.button_mask == 0:
			update_visual(_pick_start(origin, dir))
			return true
		return false
	return false


func _commit(seed: Vector3i) -> void:
	if seed == VoxelPicking.NONE or not State.document.has_cell(State.current_frame, seed):
		return
	State.selection.cells = _apply_mode(_flood(seed)).cells
	State.selection_changed.emit()


func _flood(seed: Vector3i) -> VoxelSelection:
	var frame: VoxelFrame = State.document.frames[State.current_frame]
	var target: Color = frame.cells[seed]
	var sel := VoxelSelection.new()
	sel.add(seed)
	if not _connected():
		for c in frame.cells:
			if colors_equal(frame.cells[c], target):
				sel.add(c)
		return sel
	var stack: Array[Vector3i] = [seed]
	while not stack.is_empty():
		for n in _neighbors(stack.pop_back()):
			if sel.contains(n):
				continue
			if not frame.cells.has(n) or not colors_equal(frame.cells[n], target):
				continue
			sel.add(n)
			stack.append(n)
	return sel


func _neighbors(c: Vector3i) -> Array[Vector3i]:
	return [
		Vector3i(c.x + 1, c.y, c.z), Vector3i(c.x - 1, c.y, c.z),
		Vector3i(c.x, c.y + 1, c.z), Vector3i(c.x, c.y - 1, c.z),
		Vector3i(c.x, c.y, c.z + 1), Vector3i(c.x, c.y, c.z - 1),
	]
