extends VoxelTool

var _settings := preload("./settings.tres")
var _filled: Array[Vector3i] = []

func apply(_target: Vector3i, hit: Vector3i) -> bool:
	_filled.clear()
	if hit == VoxelPicking.NONE or not State.can_edit(hit):
		return false
	if not State.document.has_cell(State.current_frame, hit):
		return false
	return _flood_fill(hit)


func applied_cells(_target: Vector3i, _hit: Vector3i) -> Array[Vector3i]:
	return _filled


func _flood_fill(seed_cell: Vector3i) -> bool:
	var frame: VoxelFrame = State.document.frames[State.current_frame]
	var target: Color = frame.cells[seed_cell]
	var replacement := State.current_color
	if colors_equal(target, replacement):
		return false
	if not _settings.connected:
		return _recolor_all(frame, target, replacement)
	var stack: Array[Vector3i] = [seed_cell]
	_set_cell(seed_cell, replacement)
	while not stack.is_empty():
		var c: Vector3i = stack.pop_back()
		for n in _neighbors(c):
			if not State.can_edit(n):
				continue
			if frame.cells.has(n) and colors_equal(frame.cells[n], target):
				_set_cell(n, replacement)
				stack.append(n)
	return true


func _recolor_all(frame: VoxelFrame, target: Color, replacement: Color) -> bool:
	var changed := false
	for c in frame.cells.keys():
		if not State.can_edit(c):
			continue
		if colors_equal(frame.cells[c], target):
			_set_cell(c, replacement)
			changed = true
	return changed


func _set_cell(c: Vector3i, color: Color) -> void:
	State.document.set_cell(State.current_frame, c, color)
	_filled.append(c)


func _neighbors(c: Vector3i) -> Array[Vector3i]:
	return [
		Vector3i(c.x + 1, c.y, c.z), Vector3i(c.x - 1, c.y, c.z),
		Vector3i(c.x, c.y + 1, c.z), Vector3i(c.x, c.y - 1, c.z),
		Vector3i(c.x, c.y, c.z + 1), Vector3i(c.x, c.y, c.z - 1),
	]
