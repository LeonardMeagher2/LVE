extends RefCounted

## The pure spray sampler.
##
## The sampler computes the write set of one spray batch from explicit inputs
## only. It reads no Node, no State, and no settings resource. A caller passes a
## frozen frame snapshot, the brush cell, the symmetry axes and origin, the
## selection, the full material, the sizes, the speed, and its own random source.
## The same kernel runs on the main thread inline and on a worker pool thread, so
## a large batch computes outside the input frame and the result never depends on
## where it ran.
##
## The shape cache holds the spot offsets, the spot pattern, and the spot rows.
## One cache instance is shared by the main thread and the workers. Every entry
## is immutable once stored, and a store replaces the whole value under a short
## lock, so a reader never sees a half-built entry and a build never holds the
## lock. Two workers can build the same size at once, and the result is the same.
##
## The occupancy rows of each chunk hold the occupied x bits of every local row.
## The sampler counts and ranks the search candidates from those rows, so a wide
## search never walks the whole reach volume. A material-only write keeps the
## occupancy revision, so a repaint reuses the rows.
##
## A surface index derives the exposed x bits of the same rows. The sampler keeps
## a spot center and a painted cell only when one face neighbor is empty, so a
## spray never changes a buried voxel.
##
## The sampler names only the pure size and occupancy helpers. A caller preloads
## this script.

const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")
## The pure occupancy-row index. It counts and ranks occupied cells inside the
## search sphere, so the sampler never gathers the whole reach volume.
const SprayIndex := preload("./SprayOccupancyIndex.gd")

# The scanline row of one spot sphere. The entries hold one (dy, dz) pair in "x"
# and "y" and the row x-span in "z" (low) and "w" (high).


## One lock-guarded shape cache for the spot sizes.
##
## The cache stores immutable values. A reader gets the value it needs and keeps
## it, so a later store cannot change it. The lock covers one dictionary read or
## one dictionary write, never a build.
class ShapeCache extends RefCounted:
	var _lock := Mutex.new()
	var _offsets := {}
	var _patterns := {}
	var _rows := {}
	var _spans := {}

	## Returns the cached spot offsets of one size, or null.
	func offsets(size: int) -> Variant:
		_lock.lock()
		var value: Variant = _offsets.get(size)
		_lock.unlock()
		return value

	## Stores the spot offsets of one size. The value is immutable from now on.
	func put_offsets(size: int, value: Variant) -> void:
		_lock.lock()
		_offsets[size] = value
		_lock.unlock()

	## Returns the cached spot pattern of one size, or null.
	func pattern(size: int) -> Variant:
		_lock.lock()
		var value: Variant = _patterns.get(size)
		_lock.unlock()
		return value

	## Stores the spot pattern of one size. The value is immutable from now on.
	func put_pattern(size: int, value: Variant) -> void:
		_lock.lock()
		_patterns[size] = value
		_lock.unlock()

	## Returns the cached spot rows of one size, or null.
	func rows(size: int) -> Variant:
		_lock.lock()
		var value: Variant = _rows.get(size)
		_lock.unlock()
		return value

	## Stores the spot rows of one size. The value is immutable from now on.
	func put_rows(size: int, value: Variant) -> void:
		_lock.lock()
		_rows[size] = value
		_lock.unlock()

	## Returns the exact row spans of one size, or null.
	func spans(size: int) -> Variant:
		_lock.lock()
		var value: Variant = _spans.get(size)
		_lock.unlock()
		return value

	## Stores the exact row spans of one size. The value is immutable from now on.
	func put_spans(size: int, value: Variant) -> void:
		_lock.lock()
		_spans[size] = value
		_lock.unlock()

	## Drops every entry. The lock covers the clear only.
	func clear() -> void:
		_lock.lock()
		_offsets.clear()
		_patterns.clear()
		_rows.clear()
		_spans.clear()
		_lock.unlock()

	## Returns the number of cached sizes. It is a diagnostic.
	func size() -> int:
		_lock.lock()
		var count := _offsets.size()
		_lock.unlock()
		return count


## Returns the spot offsets of one size from the cache. A miss builds the offsets
## off the lock and stores them.
static func offsets(cache: ShapeCache, size: int) -> Array[Vector3i]:
	var cached: Variant = cache.offsets(size)
	if cached != null:
		var value: Array[Vector3i] = cached
		return value
	var built := VoxelBrushSize.sphere_offsets(size)
	cache.put_offsets(size, built)
	return built


## Returns the spot pattern of one size from the cache. A miss builds the
## read-only lookup set off the lock and stores it.
static func pattern(cache: ShapeCache, size: int) -> Dictionary:
	var cached: Variant = cache.pattern(size)
	if cached != null:
		var value: Dictionary = cached
		return value
	var built := {}
	for offset in offsets(cache, size):
		built[offset] = true
	built.make_read_only()
	cache.put_pattern(size, built)
	return built


## Returns the exact row spans of one size from the cache. A miss builds the
## table off the lock and stores it. One table serves every query of that size,
## so a wide size pays its square roots once.
static func sphere_spans(cache: ShapeCache, size: int) -> RefCounted:
	var cached: Variant = cache.spans(size)
	if cached != null:
		return cached
	var built := SprayIndex.SphereSpans.build(size)
	cache.put_spans(size, built)
	return built


## Returns the scanline rows of one spot sphere from the cache. A miss builds the
## rows off the lock and stores them.
static func rows(cache: ShapeCache, size: int) -> Array:
	var cached: Variant = cache.rows(size)
	if cached != null:
		var value: Array = cached
		return value
	var built := build_rows(size)
	cache.put_rows(size, built)
	return built


## Returns the scanline rows of one spot sphere. Each row holds one (dy, dz) pair
## in "x", "y" and the row x-span in "z" (low) and "w" (high).
static func build_rows(size: int) -> Array:
	var rows := []
	var first := VoxelBrushSize.first_offset(size)
	var last := VoxelBrushSize.last_offset(size)
	var c := VoxelBrushSize.center_offset(size)
	var limit := VoxelBrushSize.radius_squared(size)
	for dy in range(first, last + 1):
		var along_y := float(dy) - c
		var rest_y := limit - along_y * along_y
		if rest_y < 0.0:
			continue
		for dz in range(first, last + 1):
			var along_z := float(dz) - c
			var rest := rest_y - along_z * along_z
			if rest < 0.0:
				continue
			var span := sqrt(rest)
			var low := maxi(first, ceili(c - span))
			var high := mini(last, floori(c + span))
			if low > high:
				continue
			rows.append(Vector4i(dy, dz, low, high))
	return rows


## Returns the number of occupied cells that the reach range can hold. The result
## caps at the reach cube, so the estimate never counts the same cell twice and
## never grows past the gather volume. It is a legacy benchmark figure. The tool
## gate uses [method work_estimate] instead.
static func occupied_estimate(frame: VoxelFrame, center: Vector3i, reach: int) -> int:
	var side := 2 * reach + 1
	var cube := side * side * side
	var min_chunk := VoxelFrame.chunk_position(center - Vector3i.ONE * reach)
	var max_chunk := VoxelFrame.chunk_position(center + Vector3i.ONE * reach)
	var total := 0
	for x in range(min_chunk.x, max_chunk.x + 1):
		for y in range(min_chunk.y, max_chunk.y + 1):
			for z in range(min_chunk.z, max_chunk.z + 1):
				var chunk: VoxelFrame.Chunk = frame.chunks.get(Vector3i(x, y, z))
				if chunk != null:
					total += chunk.occupied_count
					if total >= cube:
						return cube
	return total


## Returns the chunk locations that one worker sample can read or write. The
## box covers the search sphere, the spot footprint, and every active symmetry
## reflection. A caller passes the result to [method VoxelFrame.copy_chunks].
static func capture_chunks(center: Vector3i, search_size: int, spot_size: int, axes: int, origin_twice: Vector3i) -> Array[Vector3i]:
	return SprayIndex.capture_chunks(center, search_size, spot_size, axes, origin_twice)


## Returns the inline work estimate of one sample. The unit is one indexed row
## operation, not one occupied cell. A caller uses it to choose the inline path
## or the worker path before it pays the sample.
static func work_estimate(frame: VoxelFrame, center: Vector3i, search_size: int, spot_size: int, selection: Dictionary, speed: int, selection_index: RefCounted = null) -> int:
	return SprayIndex.work_estimate(frame, center, search_size, spot_size, selection, speed, selection_index)


## Samples the write set of one spray batch.
##
## The candidate set is the occupied cells of the search sphere. A cell counts
## only when it is exposed, so a spot center always has an empty face neighbor.
## The occupancy rows of each chunk count and rank those cells, so the sampler
## never gathers the whole reach volume and never builds the whole candidate
## array. The lazy partial shuffle draws the same random sequence as the old
## in-place shuffle. Every selected spot then paints its footprint directly
## from the frame, and the footprint keeps only exposed voxels. The optional
## [param job] supplies the cancel checkpoints. A caller that passes
## [param report] receives the candidate count and the work counts in it.
static func sample(center: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext, spot_size: int, search_size: int, speed: int, rng: RandomNumberGenerator, material: PackedFloat32Array, cache: ShapeCache, job: VoxelFrame.EditJob = null, report: Dictionary = {}, selection_index: RefCounted = null) -> Array[Vector3i]:
	var search_spans := sphere_spans(cache, search_size)
	var surface := SprayIndex.SurfaceIndex.new()
	surface.frame = frame
	var candidates := SprayIndex.build_candidates(center, frame, search_size, context.selection, job, selection_index, search_spans, surface)
	report["local"] = 0
	report["legacy_local"] = 0
	report["candidates"] = candidates.total
	report["chunks"] = candidates.chunks_scanned
	report["rows"] = candidates.rows_scanned
	report["index_builds"] = candidates.index_builds
	report["index_grid_reads"] = candidates.index_grid_reads
	report["index_build_slots"] = candidates.index_build_slots
	report["selection_checked"] = candidates.selection_checked
	report["selection_builds"] = candidates.selection_builds
	report["selection_work"] = candidates.selection_work
	if candidates.selection_index != null:
		report["selection_index"] = candidates.selection_index
	var count := mini(speed, candidates.total)
	if count <= 0:
		_add_surface_stats(report, surface)
		report["spots"] = 0
		return []
	# A lazy partial shuffle keeps the old draws and swaps without an index
	# array. The override map holds only the positions the shuffle touched.
	var spots: Array[Vector3i] = []
	var overrides := {}
	for i in count:
		if job and not job.checkpoint(i):
			return []
		var pick := rng.randi_range(i, candidates.total - 1)
		var first: Vector3i = overrides[i] if overrides.has(i) else candidates.candidate(i)
		var second: Vector3i = overrides[pick] if overrides.has(pick) else candidates.candidate(pick)
		overrides[i] = second
		if pick != i:
			overrides[pick] = first
		spots.append(second)
	report["spots"] = spots.size()
	report["rank_calls"] = candidates.rank_calls
	report["rank_rows"] = candidates.rank_rows
	var changes := footprints_selected(spots, frame, context, spot_size, material, cache, job, report, surface)
	_add_surface_stats(report, surface)
	report["row_ops"] = int(report.get("rows", 0)) + int(report.get("rank_rows", 0)) + int(report.get("footprint_rows", 0)) + int(report.get("selection_work", 0))
	if job and not job.checkpoint(0):
		return []
	return _expanded_cells(changes, frame, context, job, true)


## A read view of the occupied cells of one frozen frame.
##
## The view caches the raw material grid of every chunk it reads, including the
## chunks that the frame does not hold. One lookup costs one chunk dictionary
## read, one cached grid read, and one native array read, so a mirrored
## destination far outside the sampled region costs the same as a local one. The
## view is per job, and it reads no Node and no live frame.
class Occupancy extends RefCounted:
	## The frozen frame to read. The caller sets it before the first lookup.
	var frame: VoxelFrame
	## The cached grids, keyed by chunk coordinate. An empty grid marks a chunk
	## that the frame does not hold.
	var grids := {}

	## Returns true when the frozen frame holds the cell.
	func occupied(cell: Vector3i) -> bool:
		return _material_id(cell) > 0

	## Returns true when the frozen frame holds the cell and at least one of its
	## six face neighbors is empty.
	func exposed(cell: Vector3i) -> bool:
		if not occupied(cell):
			return false
		for direction in VoxelFrame.DIRECTIONS:
			if not occupied(cell + direction):
				return true
		return false

	# Returns the material id of one cell, or zero when the cell is empty.
	func _material_id(cell: Vector3i) -> int:
		var location := VoxelFrame.chunk_position(cell)
		var cached: Variant = grids.get(location)
		if cached == null:
			var chunk: VoxelFrame.Chunk = frame.chunks.get(location)
			cached = chunk.grid if chunk != null else PackedInt32Array()
			grids[location] = cached
		var grid: PackedInt32Array = cached
		if grid.is_empty():
			return 0
		var local := cell - location * VoxelFrame.CHUNK_SIZE
		return grid[local.x + VoxelFrame.CHUNK_SIZE * (local.y + VoxelFrame.CHUNK_SIZE * local.z)]


## Expands a change set through the symmetry and the selection with a raw
## occupancy view.
##
## The mask order, the loop order, the selection filter, the existing-only filter,
## and the original-overlap priority match [method
## VoxelFrame.EditContext.expand], so the result holds the same cells, the same
## materials, and the same key order. The view reads the whole frozen frame, so a
## mirrored destination outside the gathered region is exact. The caller passes
## `existing_only` true and no matching material, which is the only supported
## form. An optional [param surface_only] also requires an empty face neighbor at
## the destination, so a mirrored copy of an exposed voxel stays out when the
## mirror is buried.
static func expand_occupied(changes: Dictionary, occupancy: Occupancy, axes: int, origin_twice: Vector3i, selection: Dictionary, job: VoxelFrame.EditJob = null, surface_only := false) -> Dictionary:
	var expanded := {}
	var masks: Array[int] = []
	for mask in 8:
		if (mask & ~axes) == 0:
			masks.append(mask)
	var filtered := not selection.is_empty()
	var completed := 0
	for cell: Vector3i in changes:
		var value: PackedFloat32Array = changes[cell]
		for mask in masks:
			var destination := _reflect(cell, mask, origin_twice)
			var held := occupancy.exposed(destination) if surface_only else occupancy.occupied(destination)
			if (not filtered or selection.has(destination)) and held:
				expanded[destination] = value
			completed += 1
			if job and completed % 4096 == 0 and not job.checkpoint(completed):
				return {}
	if axes == 0:
		return expanded
	# Preserve the original materials where the original and the reflected
	# patterns overlap.
	for cell: Vector3i in changes:
		var held := occupancy.exposed(cell) if surface_only else occupancy.occupied(cell)
		if (not filtered or selection.has(cell)) and held:
			expanded[cell] = changes[cell]
		completed += 1
		if job and completed % 4096 == 0 and not job.checkpoint(completed):
			return {}
	return expanded


## Returns the mirror of one cell for one symmetry mask, exactly as
## [method VoxelFrame.EditContext.reflect] does.
static func _reflect(cell: Vector3i, mask: int, origin_twice: Vector3i) -> Vector3i:
	var destination := cell
	for axis in 3:
		if mask & (1 << axis):
			destination[axis] = origin_twice[axis] - cell[axis]
	return destination


## Samples the write set from an already gathered local set. The spot sphere is
## the shared brush sphere of the spot diameter, and the search size is the
## shared brush sphere of that width, so an even size keeps the brush alignment.
## The sample keeps only exposed voxels, like [method sample].
static func sample_local(center: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext, local: Array[Vector3i], spot_size: int, search_size: int, speed: int, rng: RandomNumberGenerator, material: PackedFloat32Array, cache: ShapeCache, job: VoxelFrame.EditJob = null, report: Dictionary = {}) -> Array[Vector3i]:
	var surface := SprayIndex.SurfaceIndex.new()
	surface.frame = frame
	var candidates: Array[Vector3i] = []
	for cell in candidate_cells(center, local, search_size):
		if surface.exposed(cell):
			candidates.append(cell)
	report["candidates"] = candidates.size()
	var count := mini(speed, candidates.size())
	if count <= 0:
		return []
	# A partial shuffle picks distinct centers without replacement. The candidate
	# array is fresh, so the shuffle runs in place and needs no index array.
	var spots: Array[Vector3i] = []
	for i in count:
		var pick := rng.randi_range(i, candidates.size() - 1)
		var swap := candidates[i]
		candidates[i] = candidates[pick]
		candidates[pick] = swap
		spots.append(candidates[i])
	var changes := footprints(spots, local, spot_size, material, cache, job, surface)
	# Every change is already occupied, exposed, and selection-filtered, so an
	# identity context needs no expansion. A symmetry or selection context still
	# expands, because its mirrored destinations must exist and be exposed too.
	# The expansion reads the frozen frame through a raw occupancy view, so a
	# mirrored destination outside the gathered region is exact and costs one
	# array read.
	var cells: Array[Vector3i] = []
	if context.axes == 0 and context.selection.is_empty():
		if job and not job.checkpoint(0):
			return []
		cells.assign(changes.keys())
		return cells
	return _expanded_cells(changes, frame, context, job, true)


## Returns the voxels that the selected spot centers paint, read directly from
## the frozen frame.
##
## The spot sphere of every selected center is unioned by scanline rows, and each
## merged span reads the chunk occupancy rows. The union therefore visits only
## the occupied cells of the spots, not the whole search-plus-spot reach. An
## optional [param surface] restricts every painted cell to an exposed voxel, so
## a spot never recolors a buried cell. The result holds the same cells as
## [method footprints] for the same occupied local set, with the same selection,
## material, and surface filter.
static func footprints_selected(spots: Array[Vector3i], frame: VoxelFrame, context: VoxelFrame.EditContext, spot_size: int, material: PackedFloat32Array, cache: ShapeCache, job: VoxelFrame.EditJob = null, report: Dictionary = {}, surface: RefCounted = null) -> Dictionary:
	var changes := {}
	if spots.is_empty():
		report["footprint_cells"] = 0
		report["footprint_visits"] = 0
		report["footprint_rows"] = 0
		return changes
	if spot_size == 1:
		for spot in spots:
			if surface == null or surface.exposed(spot):
				changes[spot] = material
		report["footprint_cells"] = changes.size()
		report["footprint_visits"] = changes.size()
		report["footprint_rows"] = 0
		return changes
	# A sparse frame is cheaper to scan per spot than to union every spot row.
	# The chunk occupied counts bound the scan without touching a grid slot.
	var first := VoxelBrushSize.first_offset(spot_size)
	var last := VoxelBrushSize.last_offset(spot_size)
	var min_spot := spots[0]
	var max_spot := spots[0]
	for spot in spots:
		min_spot = Vector3i(mini(min_spot.x, spot.x), mini(min_spot.y, spot.y), mini(min_spot.z, spot.z))
		max_spot = Vector3i(maxi(max_spot.x, spot.x), maxi(max_spot.y, spot.y), maxi(max_spot.z, spot.z))
	var min_chunk := VoxelFrame.chunk_position(min_spot + Vector3i.ONE * first)
	var max_chunk := VoxelFrame.chunk_position(max_spot + Vector3i.ONE * last)
	var occupied_hint := 0
	for x in range(min_chunk.x, max_chunk.x + 1):
		for y in range(min_chunk.y, max_chunk.y + 1):
			for z in range(min_chunk.z, max_chunk.z + 1):
				var chunk: VoxelFrame.Chunk = frame.chunks.get(Vector3i(x, y, z))
				if chunk != null:
					occupied_hint += chunk.occupied_count
	var stats := {"index_builds": 0, "index_grid_reads": 0, "index_build_slots": 0}
	if occupied_hint <= spots.size() * 4:
		var scanned := footprints_scan(spots, frame, context, spot_size, material, cache, job, report, stats, surface)
		_add_footprint_stats(report, stats)
		return scanned
	var spot_rows := rows(cache, spot_size)
	var selection: Dictionary = context.selection
	var filtered := not selection.is_empty()
	var by_row := {}
	var completed := 0
	for spot in spots:
		for row in spot_rows:
			var key := Vector2i(spot.y + row.x, spot.z + row.y)
			var span := Vector2i(spot.x + row.z, spot.x + row.w)
			var bucket: Variant = by_row.get(key)
			if bucket == null:
				by_row[key] = [span]
			else:
				bucket.append(span)
			completed += 1
			if job and completed % 4096 == 0 and not job.checkpoint(completed):
				return {}
	report["footprint_rows"] = by_row.size()
	var visits := 0
	for key: Vector2i in by_row:
		var spans: Array = by_row[key]
		spans.sort()
		var first_span: Vector2i = spans[0]
		var low := first_span.x
		var high := first_span.y
		for i in range(1, spans.size()):
			var span: Vector2i = spans[i]
			if span.x <= high + 1:
				high = maxi(high, span.y)
			else:
				visits += _emit_row_span(changes, frame, key, low, high, filtered, selection, material, stats, surface)
				low = span.x
				high = span.y
			completed += 1
			if job and completed % 4096 == 0 and not job.checkpoint(completed):
				return {}
		visits += _emit_row_span(changes, frame, key, low, high, filtered, selection, material, stats, surface)
		completed += 1
		if job and completed % 4096 == 0 and not job.checkpoint(completed):
			return {}
	report["footprint_cells"] = changes.size()
	report["footprint_visits"] = visits
	_add_footprint_stats(report, stats)
	return changes


# Adds the real chunk row builds of one footprint phase to the sample report.
static func _add_footprint_stats(report: Dictionary, stats: Dictionary) -> void:
	report["index_builds"] = int(report.get("index_builds", 0)) + int(stats.get("index_builds", 0))
	report["index_grid_reads"] = int(report.get("index_grid_reads", 0)) + int(stats.get("index_grid_reads", 0))
	report["index_build_slots"] = int(report.get("index_build_slots", 0)) + int(stats.get("index_build_slots", 0))


# Adds the chunk row work that the surface index paid to the sample report. The
# surface index builds a boundary neighbor row that the count walk never visits,
# so it owns that count.
static func _add_surface_stats(report: Dictionary, surface: RefCounted) -> void:
	report["index_builds"] = int(report.get("index_builds", 0)) + surface.index_builds
	report["index_grid_reads"] = int(report.get("index_grid_reads", 0)) + surface.index_grid_reads
	report["index_build_slots"] = int(report.get("index_build_slots", 0)) + surface.index_build_slots


# Scans the occupied cells of every spot sphere directly. It walks the chunks of
# the spot box and reads one row mask at a time, so a sparse frame costs the real
# occupied cells instead of every row of every spot. A dense frame keeps the row
# union, because the scan would repeat the overlapping spot cells. An optional
# surface index restricts the emitted cells to exposed voxels.
static func footprints_scan(spots: Array[Vector3i], frame: VoxelFrame, context: VoxelFrame.EditContext, spot_size: int, material: PackedFloat32Array, cache: ShapeCache, job: VoxelFrame.EditJob = null, report: Dictionary = {}, stats: Dictionary = {}, surface: RefCounted = null) -> Dictionary:
	var changes := {}
	var selection: Dictionary = context.selection
	var filtered := not selection.is_empty()
	var spans := sphere_spans(cache, spot_size)
	var first := VoxelBrushSize.first_offset(spot_size)
	var last := VoxelBrushSize.last_offset(spot_size)
	var completed := 0
	var visits := 0
	for spot in spots:
		var min_chunk := VoxelFrame.chunk_position(spot + Vector3i.ONE * first)
		var max_chunk := VoxelFrame.chunk_position(spot + Vector3i.ONE * last)
		for x in range(min_chunk.x, max_chunk.x + 1):
			for y in range(min_chunk.y, max_chunk.y + 1):
				for z in range(min_chunk.z, max_chunk.z + 1):
					var chunk: VoxelFrame.Chunk = frame.chunks.get(Vector3i(x, y, z))
					if chunk == null or not SprayIndex.chunk_intersects(spot, spot_size, chunk):
						continue
					var was_current := chunk.occupancy_index_current()
					var index := chunk.occupancy_rows()
					if index == null:
						continue
					if not was_current:
						stats["index_builds"] = int(stats.get("index_builds", 0)) + 1
						stats["index_grid_reads"] = int(stats.get("index_grid_reads", 0)) + index.grid_reads
						stats["index_build_slots"] = int(stats.get("index_build_slots", 0)) + index.build_slots
					var origin := chunk.origin()
					for row in VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE:
						completed += 1
						if job and completed % 4096 == 0 and not job.checkpoint(completed):
							return {}
						if index.counts[row] == 0:
							continue
						var local_y := row & (VoxelFrame.CHUNK_SIZE - 1)
						var local_z := row >> VoxelFrame.CHUNK_SHIFT
						var world_y := origin.y + local_y
						var world_z := origin.z + local_z
						var relative: Vector2i = spans.span(world_y - spot.y, world_z - spot.z)
						if relative.x > relative.y:
							continue
						visits += _emit_chunk_row(changes, chunk, index, row, world_y, world_z, spot.x + relative.x, spot.x + relative.y, filtered, selection, material, surface)
					completed += 1
					if job and not job.checkpoint(completed):
						return {}
	report["footprint_cells"] = changes.size()
	report["footprint_visits"] = visits
	report["footprint_rows"] = completed
	return changes


# Emits the occupied cells of one merged world row span. The span is split by
# chunk, so each chunk row mask answers the whole span. An optional surface
# index intersects the row mask. Returns the number of occupied cells that the
# span visited.
static func _emit_row_span(changes: Dictionary, frame: VoxelFrame, key: Vector2i, low: int, high: int, filtered: bool, selection: Dictionary, material: PackedFloat32Array, stats: Dictionary = {}, surface: RefCounted = null) -> int:
	var visits := 0
	var y := key.x
	var z := key.y
	var chunk_y := y >> VoxelFrame.CHUNK_SHIFT
	var chunk_z := z >> VoxelFrame.CHUNK_SHIFT
	var local_y := y & (VoxelFrame.CHUNK_SIZE - 1)
	var local_z := z & (VoxelFrame.CHUNK_SIZE - 1)
	var row := SprayIndex.row_index(local_y, local_z)
	var first_chunk := low >> VoxelFrame.CHUNK_SHIFT
	var last_chunk := high >> VoxelFrame.CHUNK_SHIFT
	for chunk_x in range(first_chunk, last_chunk + 1):
		var chunk: VoxelFrame.Chunk = frame.chunks.get(Vector3i(chunk_x, chunk_y, chunk_z))
		if chunk == null:
			continue
		var was_current := chunk.occupancy_index_current()
		var index := chunk.occupancy_rows()
		if index == null:
			continue
		if not was_current and not stats.is_empty():
			stats["index_builds"] = int(stats.get("index_builds", 0)) + 1
			stats["index_grid_reads"] = int(stats.get("index_grid_reads", 0)) + index.grid_reads
			stats["index_build_slots"] = int(stats.get("index_build_slots", 0)) + index.build_slots
		visits += _emit_chunk_row(changes, chunk, index, row, y, z, low, high, filtered, selection, material, surface)
	return visits


# Emits the occupied cells of one chunk row inside one world x span. Returns the
# number of occupied cells that the span visited. An optional surface index
# intersects the row mask, so a buried cell stays out.
static func _emit_chunk_row(changes: Dictionary, chunk: VoxelFrame.Chunk, index: VoxelFrame.OccupancyRows, row: int, y: int, z: int, low: int, high: int, filtered: bool, selection: Dictionary, material: PackedFloat32Array, surface: RefCounted = null) -> int:
	var origin_x := chunk.location.x * VoxelFrame.CHUNK_SIZE
	var local_low := maxi(low, origin_x) - origin_x
	var local_high := mini(high, origin_x + VoxelFrame.CHUNK_SIZE - 1) - origin_x
	if local_low > local_high:
		return 0
	var mask := index.masks[row]
	if surface != null:
		mask &= surface.masks_for(chunk.location)[row]
	var bits := mask & SprayIndex.span_mask(local_low, local_high)
	if bits == 0:
		return 0
	var visits := 0
	for local_x in range(local_low, local_high + 1):
		if bits & (1 << local_x) == 0:
			continue
		visits += 1
		var cell := Vector3i(origin_x + local_x, y, z)
		if filtered and not selection.has(cell):
			continue
		changes[cell] = material
	return visits


# Expands one change set through the frozen symmetry and selection. An identity
# context returns the keys as they are. An optional surface rule also requires
# an empty face neighbor at each destination.
static func _expanded_cells(changes: Dictionary, frame: VoxelFrame, context: VoxelFrame.EditContext, job: VoxelFrame.EditJob, surface_only := false) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	if context.axes == 0 and context.selection.is_empty():
		if job and not job.checkpoint(0):
			return []
		cells.assign(changes.keys())
		return cells
	var occupancy := Occupancy.new()
	occupancy.frame = frame
	cells.assign(expand_occupied(changes, occupancy, context.axes, context.origin_twice, context.selection, job, surface_only).keys())
	return cells


## Returns the occupied cells that the selection allows inside the reach ball.
##
## It walks the chunks of the reach range only, so an empty region costs nothing
## and no large offset array is built. It reads each chunk grid slot directly, so
## it allocates no per-chunk cell array. The cells come in the same grid order as
## the chunk `world_cells` walk.
static func local_cells(center: Vector3i, reach: int, frame: VoxelFrame, context: VoxelFrame.EditContext, job: VoxelFrame.EditJob = null) -> Array[Vector3i]:
	var min_chunk := VoxelFrame.chunk_position(center - Vector3i.ONE * reach)
	var max_chunk := VoxelFrame.chunk_position(center + Vector3i.ONE * reach)
	var limit := reach * reach
	var selection: Dictionary = context.selection
	var filtered := not selection.is_empty()
	var chunk_size := VoxelFrame.CHUNK_SIZE
	var cells: Array[Vector3i] = []
	var completed := 0
	for x in range(min_chunk.x, max_chunk.x + 1):
		for y in range(min_chunk.y, max_chunk.y + 1):
			for z in range(min_chunk.z, max_chunk.z + 1):
				var chunk: VoxelFrame.Chunk = frame.chunks.get(Vector3i(x, y, z))
				if chunk == null:
					continue
				var origin := chunk.location * chunk_size
				var grid: PackedInt32Array = chunk.grid
				for slot in grid.size():
					if grid[slot] == 0:
						continue
					var cell := origin + Vector3i(slot % chunk_size, (slot / chunk_size) % chunk_size, slot / (chunk_size * chunk_size))
					if Vector3(cell - center).length_squared() > limit:
						continue
					if filtered and not selection.has(cell):
						continue
					cells.append(cell)
					completed += 1
					if job and completed % 4096 == 0 and not job.checkpoint(completed):
						return []
	return cells


## Returns the occupied local cells inside the spray search size.
##
## The search sphere lies inside the integer ball of `reach(search_size)`, so a
## cell outside that ball can never be a candidate. The cheap integer test keeps
## the per-cell sphere test off the cells that the reach gather added for the
## spot footprints. The candidate list keeps the gather order, so the random
## selection is unchanged.
static func candidate_cells(center: Vector3i, local: Array[Vector3i], search_size: int) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var shell := VoxelBrushSize.reach(search_size)
	var limit := shell * shell
	for cell in local:
		var offset := cell - center
		if offset.x * offset.x + offset.y * offset.y + offset.z * offset.z > limit:
			continue
		if VoxelBrushSize.contains_sphere(search_size, offset):
			cells.append(cell)
	return cells


## Returns the voxels that the spot centers paint, keyed by cell position.
##
## Each spot covers every local voxel inside a sphere of the spot diameter.
## Diameter 1 paints the spot center alone.
##
## A sparse local set tests every local cell against every spot. A dense local
## set unions the spot spheres by scanline rows, because one wide spot holds
## 137376 cells and a dense batch can hold up to 64 spots. The row union groups
## the spans by their world (y, z) row and sorts each row with the native array
## sort, which compares two `Vector2i` spans lexicographically. The row keys and
## the spans hold the world coordinates as they are, so a batch anywhere in the
## world gives the exact union and no coordinate is packed into a fixed-width
## field.
##
## An optional [param job] supplies the cancel checkpoints. A dense union checks
## while it builds the row spans and while it sorts and emits them, so a wide
## batch stops soon after a cancel and never returns a partial dictionary.
## An optional [param surface] drops the buried cells at the end.
static func footprints(spots: Array[Vector3i], local: Array[Vector3i], spot_size: int, material: PackedFloat32Array, cache: ShapeCache, job: VoxelFrame.EditJob = null, surface: RefCounted = null) -> Dictionary:
	var changes := {}
	# Diameter 1 paints the spot center alone, so the changes are the centers and
	# no sphere test is needed.
	if spot_size == 1:
		for spot in spots:
			changes[spot] = material
		return _exposed_changes(changes, surface)
	var spot_rows := rows(cache, spot_size)
	var completed := 0
	if local.size() <= spot_rows.size():
		# The pattern dict is cached by diameter, so the build runs once per
		# cache and not once per batch.
		var spot_pattern := pattern(cache, spot_size)
		for spot in spots:
			for cell in local:
				completed += 1
				if spot_pattern.has(cell - spot):
					changes[cell] = material
				if job and completed % 4096 == 0 and not job.checkpoint(completed):
					return {}
		return _exposed_changes(changes, surface)
	var allowed := {}
	for cell in local:
		allowed[cell] = true
	# Each row holds one (dy, dz) pair and the x-span of the sphere on that row.
	# The union of the spots groups the spans by their world (y, z) row. The spans
	# sort with the native compare on two world x coordinates, so the batch origin
	# and the world coordinate need no packing.
	var by_row := {}
	for spot in spots:
		for row in spot_rows:
			var key := Vector2i(spot.y + row.x, spot.z + row.y)
			var span := Vector2i(spot.x + row.z, spot.x + row.w)
			var bucket: Variant = by_row.get(key)
			if bucket == null:
				by_row[key] = [span]
			else:
				bucket.append(span)
			completed += 1
			if job and completed % 4096 == 0 and not job.checkpoint(completed):
				return {}
	if job and not job.checkpoint(completed):
		return {}
	for key: Vector2i in by_row:
		var spans: Array = by_row[key]
		spans.sort()
		var first: Vector2i = spans[0]
		var lo := first.x
		var hi := first.y
		for i in range(1, spans.size()):
			var span: Vector2i = spans[i]
			if span.x <= hi + 1:
				hi = maxi(hi, span.y)
			else:
				_add_span(changes, allowed, key.x, key.y, lo, hi, material)
				lo = span.x
				hi = span.y
			completed += 1
			if job and completed % 4096 == 0 and not job.checkpoint(completed):
				return {}
		_add_span(changes, allowed, key.x, key.y, lo, hi, material)
		completed += 1
		if job and completed % 4096 == 0 and not job.checkpoint(completed):
			return {}
	return _exposed_changes(changes, surface)


# Drops the buried cells of one change set. It returns the same dictionary when
# no surface index is given.
static func _exposed_changes(changes: Dictionary, surface: RefCounted) -> Dictionary:
	if surface == null:
		return changes
	var exposed := {}
	for cell: Vector3i in changes:
		if surface.exposed(cell):
			exposed[cell] = changes[cell]
	return exposed


# Writes one merged span into the changes. A cell outside the local set stays
# out, so a spot never paints an empty cell.
static func _add_span(changes: Dictionary, allowed: Dictionary, y: int, z: int, lo: int, hi: int, material: PackedFloat32Array) -> void:
	for x in range(lo, hi + 1):
		var cell := Vector3i(x, y, z)
		if allowed.has(cell):
			changes[cell] = material


## Returns the identity and the voxel revision of every chunk that holds one of
## these cells, keyed by chunk coordinate.
##
## The frame snapshot is a copy-on-write view, so a chunk object stays the one
## the snapshot read until a later write copies it. A caller compares this
## witness against the live frame, so a stale sample is detected with one test
## per chunk instead of one test per cell.
static func witness(frame: VoxelFrame, cells: Array[Vector3i]) -> Dictionary:
	var out := {}
	for cell in cells:
		var location := VoxelFrame.chunk_position(cell)
		if out.has(location):
			continue
		var chunk: VoxelFrame.Chunk = frame.chunks.get(location)
		if chunk != null:
			out[location] = [chunk, chunk.voxel_revision]
	return out
