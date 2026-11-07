class_name VoxelSelection
extends RefCounted

## A set of selected voxel cells.
##
## The selection stores cell positions in a dictionary. [method capture] returns
## a shared snapshot. The next write copies the dictionary first, so the
## snapshot stays frozen. Every mutation also keeps one bit mask per chunk
## current, so the outline builder reads dense words instead of the dictionary.

## The chunk edge length of one selection mask.
const MASK_CHUNK := VoxelFrame.CHUNK_SIZE
## The cell count of one selection mask grid.
const MASK_SIZE := MASK_CHUNK * MASK_CHUNK
## The entry index of the chunk cell count. A chunk at zero leaves the mask set.
const MASK_COUNT := 3

## The selected cells, keyed by cell position. A write replaces the whole set.
var cells: Dictionary:
	get:
		_make_writable()
		return _selected_cells
	set(value):
		_selected_cells = value
		_snapshot_shared = false
		_rebuild_masks()
		revision += 1

## The content revision. It moves on every mutation, so a caller can dedupe a
## request without hashing the whole set. A copy or a read does not move it.
var revision := 0

var _selected_cells := {}
var _snapshot_shared := false
# The per-chunk masks, keyed by chunk position. Each value holds the x grid, the
# y grid, and the z grid in that order. Every mutation keeps the grids current.
var _chunk_masks := {}
# The last chunk mask that a write touched. A selection adds cells in a mostly
# spatial order, so one entry removes most dictionary lookups.
var _mask_base := Vector3i.MAX
var _mask_chunk: Array = []

# Phase counters of the mask rebuild. A probe resets them by direct static write.
static var _profile_rebuild_calls := 0
static var _profile_rebuild_us := 0


## Removes every selected cell.
func clear() -> void:
	_selected_cells = {}
	_snapshot_shared = false
	_chunk_masks = {}
	_mask_base = Vector3i.MAX
	_mask_chunk = []
	revision += 1


## Adds one cell to the selection.
func add(cell_position: Vector3i) -> void:
	_make_writable()
	_selected_cells[cell_position] = true
	_set_mask(cell_position, true)
	_bump_chunk(chunk_base(cell_position), 1)
	revision += 1


## Removes one cell from the selection. Does nothing when the cell is not
## selected.
func erase(cell_position: Vector3i) -> void:
	if not _selected_cells.has(cell_position):
		return
	_make_writable()
	_selected_cells.erase(cell_position)
	_set_mask(cell_position, false)
	_bump_chunk(chunk_base(cell_position), -1)
	revision += 1


## Adds one range of a streamed batch. The cells are grouped by chunk, and each
## chunk mask is fetched and written back once, so a large wand batch pays one
## call and one mask write-back per chunk.
func add_range(keys: Array, start: int, end: int) -> void:
	if start >= end:
		return
	_make_writable()
	var buckets := {}
	for index in range(start, end):
		var cell_position: Vector3i = keys[index]
		_selected_cells[cell_position] = true
		var base := Vector3i(cell_position.x >> 4, cell_position.y >> 4, cell_position.z >> 4)
		var bucket = buckets.get(base)
		if bucket == null:
			bucket = []
			buckets[base] = bucket
		bucket.append(cell_position)
	for base: Vector3i in buckets:
		var chunk_masks = _chunk_masks.get(base)
		if chunk_masks == null:
			chunk_masks = _new_masks()
			_chunk_masks[base] = chunk_masks
		_write_mask_batch(chunk_masks, base, buckets[base], true)
		_bump_chunk(base, buckets[base].size())
	_mask_base = Vector3i.MAX
	_mask_chunk = []
	revision += 1


## Removes one range of a streamed batch. A cell that is not selected is skipped.
func erase_range(keys: Array, start: int, end: int) -> void:
	var buckets := {}
	var writable := false
	for index in range(start, end):
		var cell_position: Vector3i = keys[index]
		if not _selected_cells.has(cell_position):
			continue
		if not writable:
			# A captured selection is shared and read-only, so the first write
			# copies it. A batch with no match pays no copy.
			_make_writable()
			writable = true
		_selected_cells.erase(cell_position)
		var base := Vector3i(cell_position.x >> 4, cell_position.y >> 4, cell_position.z >> 4)
		var bucket = buckets.get(base)
		if bucket == null:
			bucket = []
			buckets[base] = bucket
		bucket.append(cell_position)
	if buckets.is_empty():
		return
	for base: Vector3i in buckets:
		var chunk_masks = _chunk_masks.get(base)
		if chunk_masks == null:
			continue
		_write_mask_batch(chunk_masks, base, buckets[base], false)
		_bump_chunk(base, -buckets[base].size())
	_mask_base = Vector3i.MAX
	_mask_chunk = []
	revision += 1


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
	_fill_box_masks(min_corner, max_corner)


## Adds every cell of another selection.
func union(other_selection: VoxelSelection) -> void:
	_make_writable()
	for cell_position in other_selection._selected_cells:
		_selected_cells[cell_position] = true
		_set_mask(cell_position, true)
		_bump_chunk(chunk_base(cell_position), 1)
	revision += 1


## Removes every cell of another selection.
func subtract(other_selection: VoxelSelection) -> void:
	_make_writable()
	for cell_position in other_selection._selected_cells:
		if not _selected_cells.has(cell_position):
			continue
		_selected_cells.erase(cell_position)
		_set_mask(cell_position, false)
		_bump_chunk(chunk_base(cell_position), -1)
	revision += 1


## Returns the number of selected cells.
func count() -> int:
	return _selected_cells.size()


## Returns a read-only view of the selected cells. Use the selection methods
## for writes.
func all_cells() -> Dictionary:
	# Read-only view. Use the selection methods for writes.
	return _selected_cells


## Returns the per-chunk selection masks. Each value holds the x grid, the y
## grid, and the z grid in that order. Each grid holds one 16-bit row for every
## row of the chunk. Every mutation keeps the grids current.
func mask_chunks() -> Dictionary:
	return _chunk_masks


## Returns a copy of the per-chunk masks for a worker or a history record. The
## grids are copied, so a later selection write cannot change the snapshot. A
## packed array that two array elements share does not detach on a write.
func mask_snapshot() -> Dictionary:
	var snapshot := {}
	for location in _chunk_masks:
		var grids: Array = _chunk_masks[location]
		snapshot[location] = [grids[0].duplicate(), grids[1].duplicate(), grids[2].duplicate(), grids[MASK_COUNT]]
	return snapshot


## Returns the selected cells and marks them shared. The next write copies the
## dictionary first, so this snapshot stays frozen.
func capture() -> Dictionary:
	_snapshot_shared = true
	return _selected_cells


## Replaces the selected cells with a captured snapshot. It marks them shared,
## so the next write copies them first. A caller that captured the masks with
## [method mask_snapshot] passes them to skip the rebuild.
func restore(selection_snapshot: Dictionary, mask_snapshot: Dictionary = {}) -> void:
	_selected_cells = selection_snapshot
	_snapshot_shared = true
	if mask_snapshot.is_empty():
		_rebuild_masks()
	else:
		_adopt_masks(mask_snapshot)
	revision += 1


# Installs a mask snapshot. The entry arrays and the grids are copied, so a later
# write to this selection cannot change the snapshot.
func _adopt_masks(masks: Dictionary) -> void:
	_chunk_masks = {}
	_mask_base = Vector3i.MAX
	_mask_chunk = []
	for location in masks:
		var grids: Array = masks[location]
		_chunk_masks[location] = [grids[0].duplicate(), grids[1].duplicate(), grids[2].duplicate(), grids[MASK_COUNT]]


# Rebuilds every chunk mask from the selected cells. A bulk change uses it. The
# cells are grouped by chunk, so each grid is written back once per chunk, not
# once per cell.
func _rebuild_masks() -> void:
	var started_us := Time.get_ticks_usec()
	_chunk_masks = {}
	_mask_base = Vector3i.MAX
	_mask_chunk = []
	var buckets := {}
	for cell_position: Vector3i in _selected_cells:
		var base := Vector3i(cell_position.x >> 4, cell_position.y >> 4, cell_position.z >> 4)
		var bucket = buckets.get(base)
		if bucket == null:
			bucket = []
			buckets[base] = bucket
		bucket.append(cell_position)
	for base: Vector3i in buckets:
		var chunk_masks := _new_masks()
		chunk_masks[MASK_COUNT] = buckets[base].size()
		_chunk_masks[base] = chunk_masks
		_write_mask_batch(chunk_masks, base, buckets[base], true)
	_profile_rebuild_calls += 1
	_profile_rebuild_us += Time.get_ticks_usec() - started_us


# Moves the cell count of one chunk. A chunk that reaches zero leaves the mask
# set, so a snapshot never copies an empty chunk. The count can only be higher
# than the real cell count, because a repeated add still counts once.
func _bump_chunk(base: Vector3i, delta: int) -> void:
	var chunk_masks = _chunk_masks.get(base)
	if chunk_masks == null:
		return
	var remaining: int = chunk_masks[MASK_COUNT] + delta
	if remaining > 0:
		chunk_masks[MASK_COUNT] = remaining
		return
	_chunk_masks.erase(base)
	if base == _mask_base:
		_mask_base = Vector3i.MAX
		_mask_chunk = []


## Returns the chunk that holds one cell.
static func chunk_base(cell_position: Vector3i) -> Vector3i:
	return Vector3i(cell_position.x >> 4, cell_position.y >> 4, cell_position.z >> 4)


# Sets or clears one cell bit in its chunk masks. An erase on a chunk with no
# cells does nothing. The last chunk is cached, because a selection adds cells in
# a mostly spatial order.
func _set_mask(cell_position: Vector3i, value: bool) -> void:
	var base := chunk_base(cell_position)
	var chunk_masks = _chunk_masks.get(base)
	if base == _mask_base and not _mask_chunk.is_empty():
		chunk_masks = _mask_chunk
	else:
		if chunk_masks == null:
			if not value:
				return
			chunk_masks = _new_masks()
			_chunk_masks[base] = chunk_masks
		_mask_base = base
		_mask_chunk = chunk_masks
	_write_mask(chunk_masks, Vector3i(cell_position.x - (base.x << 4), cell_position.y - (base.y << 4), cell_position.z - (base.z << 4)), value)


# Writes one cell bit into the three grids of one chunk.
func _write_mask(chunk_masks: Array, local: Vector3i, value: bool) -> void:
	var x_bit := 1 << local.x
	var x_grid: PackedInt32Array = chunk_masks[0]
	var x_index := local.y * MASK_CHUNK + local.z
	x_grid[x_index] = (x_grid[x_index] | x_bit) if value else (x_grid[x_index] & ~x_bit)
	chunk_masks[0] = x_grid
	var y_bit := 1 << local.y
	var y_grid: PackedInt32Array = chunk_masks[1]
	var y_index := local.z * MASK_CHUNK + local.x
	y_grid[y_index] = (y_grid[y_index] | y_bit) if value else (y_grid[y_index] & ~y_bit)
	chunk_masks[1] = y_grid
	var z_bit := 1 << local.z
	var z_grid: PackedInt32Array = chunk_masks[2]
	var z_index := local.x * MASK_CHUNK + local.y
	z_grid[z_index] = (z_grid[z_index] | z_bit) if value else (z_grid[z_index] & ~z_bit)
	chunk_masks[2] = z_grid


# Writes one batch of cells into the three grids of one chunk. The grids are held
# locally and written back once, so a batch pays one entry write per chunk.
func _write_mask_batch(chunk_masks: Array, base: Vector3i, cells: Array, value: bool) -> void:
	var origin_x := base.x << 4
	var origin_y := base.y << 4
	var origin_z := base.z << 4
	var x_grid: PackedInt32Array = chunk_masks[0]
	var y_grid: PackedInt32Array = chunk_masks[1]
	var z_grid: PackedInt32Array = chunk_masks[2]
	if value:
		for cell: Vector3i in cells:
			var local_x := cell.x - origin_x
			var local_y := cell.y - origin_y
			var local_z := cell.z - origin_z
			x_grid[local_y * MASK_CHUNK + local_z] = x_grid[local_y * MASK_CHUNK + local_z] | (1 << local_x)
			y_grid[local_z * MASK_CHUNK + local_x] = y_grid[local_z * MASK_CHUNK + local_x] | (1 << local_y)
			z_grid[local_x * MASK_CHUNK + local_y] = z_grid[local_x * MASK_CHUNK + local_y] | (1 << local_z)
	else:
		for cell: Vector3i in cells:
			var local_x := cell.x - origin_x
			var local_y := cell.y - origin_y
			var local_z := cell.z - origin_z
			x_grid[local_y * MASK_CHUNK + local_z] = x_grid[local_y * MASK_CHUNK + local_z] & ~(1 << local_x)
			y_grid[local_z * MASK_CHUNK + local_x] = y_grid[local_z * MASK_CHUNK + local_x] & ~(1 << local_y)
			z_grid[local_x * MASK_CHUNK + local_y] = z_grid[local_x * MASK_CHUNK + local_y] & ~(1 << local_z)
	chunk_masks[0] = x_grid
	chunk_masks[1] = y_grid
	chunk_masks[2] = z_grid


# Fills the masks of one box in runs. Each row of a box is one contiguous bit
# range, so a box pays one write per row, not one per cell.
func _fill_box_masks(min_corner: Vector3i, max_corner: Vector3i) -> void:
	_mask_base = Vector3i.MAX
	_mask_chunk = []
	var min_chunk := Vector3i(min_corner.x >> 4, min_corner.y >> 4, min_corner.z >> 4)
	var max_chunk := Vector3i(max_corner.x >> 4, max_corner.y >> 4, max_corner.z >> 4)
	for chunk_x in range(min_chunk.x, max_chunk.x + 1):
		var origin_x := chunk_x << 4
		var x_first := maxi(min_corner.x - origin_x, 0)
		var x_last := mini(max_corner.x - origin_x, MASK_CHUNK - 1)
		var x_mask := ((1 << (x_last - x_first + 1)) - 1) << x_first
		for chunk_y in range(min_chunk.y, max_chunk.y + 1):
			var origin_y := chunk_y << 4
			var y_first := maxi(min_corner.y - origin_y, 0)
			var y_last := mini(max_corner.y - origin_y, MASK_CHUNK - 1)
			var y_mask := ((1 << (y_last - y_first + 1)) - 1) << y_first
			for chunk_z in range(min_chunk.z, max_chunk.z + 1):
				var origin_z := chunk_z << 4
				var z_first := maxi(min_corner.z - origin_z, 0)
				var z_last := mini(max_corner.z - origin_z, MASK_CHUNK - 1)
				var z_mask := ((1 << (z_last - z_first + 1)) - 1) << z_first
				var chunk_masks := _new_masks()
				var x_grid: PackedInt32Array = chunk_masks[0]
				var y_grid: PackedInt32Array = chunk_masks[1]
				var z_grid: PackedInt32Array = chunk_masks[2]
				for y in range(y_first, y_last + 1):
					var row := y * MASK_CHUNK
					for z in range(z_first, z_last + 1):
						x_grid[row + z] = x_mask
				for z in range(z_first, z_last + 1):
					var row := z * MASK_CHUNK
					for x in range(x_first, x_last + 1):
						y_grid[row + x] = y_mask
				for x in range(x_first, x_last + 1):
					var row := x * MASK_CHUNK
					for y in range(y_first, y_last + 1):
						z_grid[row + y] = z_mask
				chunk_masks[0] = x_grid
				chunk_masks[1] = y_grid
				chunk_masks[2] = z_grid
				chunk_masks[MASK_COUNT] = (x_last - x_first + 1) * (y_last - y_first + 1) * (z_last - z_first + 1)
				_chunk_masks[Vector3i(chunk_x, chunk_y, chunk_z)] = chunk_masks


func _new_masks() -> Array:
	var masks := []
	for axis in 3:
		var grid := PackedInt32Array()
		grid.resize(MASK_SIZE)
		masks.append(grid)
	masks.append(0)
	return masks


func _make_writable() -> void:
	if _snapshot_shared:
		_selected_cells = _selected_cells.duplicate()
		_snapshot_shared = false
