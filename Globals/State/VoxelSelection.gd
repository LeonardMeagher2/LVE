class_name VoxelSelection
extends RefCounted

## A set of selected voxel cells.
##
## The selection stores cell positions in a dictionary. [method capture] returns
## a shared snapshot. The next write copies the dictionary first, so the
## snapshot stays frozen.

## The selected cells, keyed by cell position. A write replaces the whole set.
var cells: Dictionary:
	get:
		_make_writable()
		return _selected_cells
	set(value):
		_selected_cells = value
		_snapshot_shared = false

var _selected_cells := {}
var _snapshot_shared := false


## Removes every selected cell.
func clear() -> void:
	_selected_cells = {}
	_snapshot_shared = false


## Adds one cell to the selection.
func add(cell_position: Vector3i) -> void:
	_make_writable()
	_selected_cells[cell_position] = true


## Removes one cell from the selection. Does nothing when the cell is not
## selected.
func erase(cell_position: Vector3i) -> void:
	if not _selected_cells.has(cell_position):
		return
	_make_writable()
	_selected_cells.erase(cell_position)


## Returns [code]true[/code] when the cell is selected.
func contains(cell_position: Vector3i) -> bool:
	return _selected_cells.has(cell_position)


## Returns [code]true[/code] when no cell is selected.
func is_empty() -> bool:
	return _selected_cells.is_empty()


## Returns the selected cells as an array.
func to_array() -> Array[Vector3i]:
	var selected_positions: Array[Vector3i] = []
	for cell_position in _selected_cells:
		selected_positions.append(cell_position)
	return selected_positions


## Replaces the selection with every cell in the box between two corners. Both
## corners are inclusive.
func from_box(first_corner: Vector3i, second_corner: Vector3i) -> void:
	var min_corner := Vector3i(mini(first_corner.x, second_corner.x), mini(first_corner.y, second_corner.y), mini(first_corner.z, second_corner.z))
	var max_corner := Vector3i(maxi(first_corner.x, second_corner.x), maxi(first_corner.y, second_corner.y), maxi(first_corner.z, second_corner.z))
	clear()
	for x in range(min_corner.x, max_corner.x + 1):
		for y in range(min_corner.y, max_corner.y + 1):
			for z in range(min_corner.z, max_corner.z + 1):
				_selected_cells[Vector3i(x, y, z)] = true


## Adds every cell of another selection.
func union(other_selection: VoxelSelection) -> void:
	_make_writable()
	for cell_position in other_selection._selected_cells:
		_selected_cells[cell_position] = true


## Removes every cell of another selection.
func subtract(other_selection: VoxelSelection) -> void:
	_make_writable()
	for cell_position in other_selection._selected_cells:
		_selected_cells.erase(cell_position)


## Returns the number of selected cells.
func count() -> int:
	return _selected_cells.size()


## Returns a read-only view of the selected cells. Use the selection methods
## for writes.
func all_cells() -> Dictionary:
	# Read-only view. Use the selection methods for writes.
	return _selected_cells


## Returns the selected cells and marks them shared. The next write copies the
## dictionary first, so this snapshot stays frozen.
func capture() -> Dictionary:
	_snapshot_shared = true
	return _selected_cells


## Replaces the selected cells with a captured snapshot. It marks them shared,
## so the next write copies them first.
func restore(selection_snapshot: Dictionary) -> void:
	_selected_cells = selection_snapshot
	_snapshot_shared = true


func _make_writable() -> void:
	if _snapshot_shared:
		_selected_cells = _selected_cells.duplicate()
		_snapshot_shared = false
