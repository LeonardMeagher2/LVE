class_name SculptQueryContext
extends RefCounted

## An exact read-only query context for one frame snapshot.
##
## The context answers one question in constant time: does an infinite column
## along one axis hold any occupied cell? [method SculptGeometry.surface_along]
## uses it only for an exactly cardinal normal and an empty change set. An empty
## column then returns [constant VoxelPicking.NONE] without a bounded walk, which
## is exactly what the walk returns: a cardinal walk never leaves its column, so
## no occupied cell can exist.
##
## A non-cardinal normal, a pending change, and a non-empty column all fall back
## to the exact walk, so the query result never changes. The context belongs to
## one worker job. It builds one index per axis on first use and never mutates the
## frame.

var _frame: VoxelFrame
var _columns := {}


func _init(frame: VoxelFrame) -> void:
	_frame = frame


## Returns true when the infinite column through [param cell] along [param axis]
## holds no occupied cell. The first call for an axis builds its index.
func column_empty(axis: int, cell: Vector3i) -> bool:
	if not _columns.has(axis):
		_columns[axis] = _build(axis)
	var columns: Dictionary = _columns[axis]
	var u := (axis + 1) % 3
	var v := (axis + 2) % 3
	return not columns.has(Vector2i(cell[u], cell[v]))


## Returns true when the context has already built the index of one axis.
func has_axis(axis: int) -> bool:
	return _columns.has(axis)


# The occupied off-axis columns of one axis, read once from the frame snapshot.
# One occupied cell marks its whole column, because the query only asks whether
# any cell exists on it.
func _build(axis: int) -> Dictionary:
	var columns := {}
	if _frame == null:
		return columns
	var u := (axis + 1) % 3
	var v := (axis + 2) % 3
	var size := VoxelFrame.CHUNK_SIZE
	for location: Vector3i in _frame.chunks:
		var chunk: VoxelFrame.Chunk = _frame.chunks[location]
		var origin := location * size
		var grid := chunk.grid
		for slot in grid.size():
			if grid[slot] == 0:
				continue
			var local := Vector3i(slot % size, (slot / size) % size, slot / (size * size))
			var world := origin + local
			columns[Vector2i(world[u], world[v])] = true
	return columns
