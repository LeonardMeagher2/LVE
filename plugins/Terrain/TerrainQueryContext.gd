class_name TerrainQueryContext
extends RefCounted

## An exact read-only query context for one frame snapshot.
##
## The context answers one question in constant time: does an infinite column
## along one axis hold any occupied cell? [method TerrainGeometry.surface_along]
## uses it only for an exactly cardinal normal and an empty change set. An empty
## column then returns [constant VoxelPicking.NONE] without a bounded walk, which
## is exactly what the walk returns: a cardinal walk never leaves its column, so
## no occupied cell can exist on it.
##
## A non-cardinal normal, a pending change, and a non-empty column all fall back
## to the exact walk, so the query result never changes. The context belongs to
## one worker job. It builds one index per axis on first use and never mutates the
## frame.
##
## The context also carries the occupied bounds of the same snapshot. Every read
## cell of a walk holds a point of its ray, and every occupied cell box lies inside
## the bounds, so a ray that misses the grown bounds reads nothing. That reject
## works for any normal and needs no index build.
##
## The index reads only the chunks of the given frame. A hover passes its bounded
## surface or map snapshot, so the build is bounded by the request read region and
## never by distant source data. An optional job supplies the cancel checkpoints
## of a worker. A cancelled build leaves no index, and every later query falls
## back to the exact walk.

## The slots scanned between two cancel checkpoints of one index build. One chunk
## holds this many slots, so a build checks once per chunk.
const CHECKPOINT := 4096
## The world margin added to the local occupied bounds of the ray reject. One unit
## is one cell, so it covers a grazing ray and the float rounding of the bounds.
const BOUNDS_MARGIN := 1.0

var _frame: VoxelFrame
var _columns := {}
var _cancelled := false
var _column_index := true
var _local_bounds := AABB()
var _has_local_bounds := false
# The job that owns the build, held weakly so the context never extends its life.
var _job: WeakRef
## The axis indexes that completed.
var builds := 0
## The index builds that started. A cancelled build leaves this above
## [member builds], so a partial scan is never hidden.
var build_attempts := 0
## The grid slots that the build actually read. One completed axis build reads
## every slot of every chunk of the bound frame.
var grid_reads := 0
## The column queries that the index answered. It counts queries, not grid slots.
var column_queries := 0
## The ray rejects asked of the local bounds, and the ones the bounds proved empty.
## They count bounds tests, not grid slots or column queries.
var bounds_queries := 0
var bounds_rejects := 0


## Binds one frame snapshot. [param job] is optional and supplies the cancel
## checkpoints of a worker. [param column_index] enables the per-axis column index
## of [method column_empty], so a caller that keeps the bare walk passes
## [code]false[/code] and still gets the bounds reject.
func _init(frame: VoxelFrame, job: VoxelFrame.EditJob = null, column_index := true) -> void:
	_frame = frame
	_job = weakref(job) if job != null else null
	_column_index = column_index


## Returns true when the infinite column through [param cell] along [param axis]
## holds no occupied cell. The first call for an axis builds its index. A context
## without the column index always reports a non-empty column, so the walk runs.
func column_empty(axis: int, cell: Vector3i) -> bool:
	if not _column_index or _cancelled:
		return false
	if not _columns.has(axis):
		var built := _build(axis)
		if _cancelled:
			return false
		_columns[axis] = built
		builds += 1
	column_queries += 1
	var columns: Dictionary = _columns[axis]
	var u := (axis + 1) % 3
	var v := (axis + 2) % 3
	return not columns.has(Vector2i(cell[u], cell[v]))


## Returns true when the whole ray of one query misses the occupied bounds of the
## snapshot, so every read cell of its walk is empty.
##
## Every cell the walk reads holds a point of the ray, and every occupied cell box
## lies inside the bounds. A ray that misses the bounds therefore cannot read an
## occupied cell, so the exact walk would return [constant VoxelPicking.NONE]. The
## point pre-check keeps the inside queries on the walk without two ray tests.
func misses_bounds(point: Vector3, normal: Vector3) -> bool:
	if _cancelled or normal == Vector3.ZERO:
		return false
	var bounds := _local_bounds_of()
	if not bounds.has_volume():
		return false
	bounds_queries += 1
	if bounds.has_point(point):
		return false
	# The ray is infinite, so no walk bound is needed: if neither direction meets
	# the grown bounds, no visited cell can be occupied.
	if bounds.grow(BOUNDS_MARGIN).intersects_ray(point, normal) != null:
		return false
	if bounds.grow(BOUNDS_MARGIN).intersects_ray(point, -normal) != null:
		return false
	bounds_rejects += 1
	return true


## Returns true when the context has already built the index of one axis.
func has_axis(axis: int) -> bool:
	return _columns.has(axis)


# The occupied bounds of the bound snapshot, read once and cached. The snapshot
# belongs to one request, so no other thread reads it.
func _local_bounds_of() -> AABB:
	if not _has_local_bounds:
		_local_bounds = _frame.get_bounds() if _frame != null else AABB()
		_has_local_bounds = true
	return _local_bounds


# The occupied off-axis columns of one axis, read once from the frame snapshot.
# One occupied cell marks its whole column, because the query only asks whether
# any cell exists on it. A cancelled build keeps no partial index.
func _build(axis: int) -> Dictionary:
	var columns := {}
	if _frame == null:
		return columns
	build_attempts += 1
	var u := (axis + 1) % 3
	var v := (axis + 2) % 3
	var size := VoxelFrame.CHUNK_SIZE
	var scanned := 0
	for location: Vector3i in _frame.chunks:
		var chunk: VoxelFrame.Chunk = _frame.chunks[location]
		var origin := location * size
		var rows := chunk.occupancy_rows()
		for row in rows.masks.size():
			var mask := rows.masks[row]
			if mask == 0:
				continue
			var local_y := row % size
			var local_z := row / size
			while mask != 0:
				var local_x := VoxelFrame.Chunk.first_column(mask)
				mask &= mask - 1
				scanned += 1
				if scanned % CHECKPOINT == 0 and not _checkpoint(scanned):
					_cancelled = true
					return {}
				grid_reads += 1
				var world := origin + Vector3i(local_x, local_y, local_z)
				columns[Vector2i(world[u], world[v])] = true
	return columns


# Reports the scanned slots to the owning job and returns false when it must
# stop. A missing job never cancels.
func _checkpoint(completed: int) -> bool:
	if _job == null:
		return true
	var job: VoxelFrame.EditJob = _job.get_ref() as VoxelFrame.EditJob
	if job == null:
		return true
	return job.checkpoint(completed)
