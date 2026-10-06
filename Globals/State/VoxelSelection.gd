class_name VoxelSelection
extends RefCounted

var cells: Dictionary:
	get:
		_make_writable()
		return _selected_cells
	set(value):
		_selected_cells = value
		_snapshot_shared = false

var _selected_cells := {}
var _snapshot_shared := false


func clear() -> void:
	_selected_cells = {}
	_snapshot_shared = false


func add(cell_position: Vector3i) -> void:
	_make_writable()
	_selected_cells[cell_position] = true


func contains(cell_position: Vector3i) -> bool:
	return _selected_cells.has(cell_position)


func is_empty() -> bool:
	return _selected_cells.is_empty()


func to_array() -> Array[Vector3i]:
	var selected_positions: Array[Vector3i] = []
	for cell_position in _selected_cells:
		selected_positions.append(cell_position)
	return selected_positions


func from_box(first_corner: Vector3i, second_corner: Vector3i) -> void:
	var min_corner := Vector3i(mini(first_corner.x, second_corner.x), mini(first_corner.y, second_corner.y), mini(first_corner.z, second_corner.z))
	var max_corner := Vector3i(maxi(first_corner.x, second_corner.x), maxi(first_corner.y, second_corner.y), maxi(first_corner.z, second_corner.z))
	clear()
	for x in range(min_corner.x, max_corner.x + 1):
		for y in range(min_corner.y, max_corner.y + 1):
			for z in range(min_corner.z, max_corner.z + 1):
				_selected_cells[Vector3i(x, y, z)] = true


func union(other_selection: VoxelSelection) -> void:
	_make_writable()
	for cell_position in other_selection._selected_cells:
		_selected_cells[cell_position] = true


func subtract(other_selection: VoxelSelection) -> void:
	_make_writable()
	for cell_position in other_selection._selected_cells:
		_selected_cells.erase(cell_position)


func count() -> int:
	return _selected_cells.size()


func all_cells() -> Dictionary:
	# Read-only view. Use the selection methods for writes.
	return _selected_cells


func capture() -> Dictionary:
	_snapshot_shared = true
	return _selected_cells


func restore(selection_snapshot: Dictionary) -> void:
	_selected_cells = selection_snapshot
	_snapshot_shared = true


func _make_writable() -> void:
	if _snapshot_shared:
		_selected_cells = _selected_cells.duplicate()
		_snapshot_shared = false
