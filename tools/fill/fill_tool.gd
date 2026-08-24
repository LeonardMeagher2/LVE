class_name FillTool
extends VoxelTool


func apply(_target: Vector3i, hit: Vector3i) -> bool:
	if hit == State.NONE or not State.can_edit(hit):
		return false
	if not State.document.has_cell(State.current_frame, hit):
		return false
	return _flood_fill(hit)


func _flood_fill(seed: Vector3i) -> bool:
	var frame: VoxelFrame = State.document.frames[State.current_frame]
	var old_index: int = frame.cells[seed]
	var new_index: int = State.document.ensure_color(State.current_color)
	if new_index == -1:
		new_index = State.document.add_color(State.current_color)
	if new_index == old_index:
		return false
	var stack: Array[Vector3i] = [seed]
	frame.cells[seed] = new_index
	while not stack.is_empty():
		var c: Vector3i = stack.pop_back()
		for n in _neighbors(c):
			if not State.can_edit(n):
				continue
			if frame.cells.get(n, -1) == old_index:
				frame.cells[n] = new_index
				stack.append(n)
	return true


func _neighbors(c: Vector3i) -> Array[Vector3i]:
	return [
		Vector3i(c.x + 1, c.y, c.z), Vector3i(c.x - 1, c.y, c.z),
		Vector3i(c.x, c.y + 1, c.z), Vector3i(c.x, c.y - 1, c.z),
		Vector3i(c.x, c.y, c.z + 1), Vector3i(c.x, c.y, c.z - 1),
	]
