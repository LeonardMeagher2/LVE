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
## The sampler names only the pure size helper. A caller preloads this script.

const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")

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

	## Drops every entry. The lock covers the clear only.
	func clear() -> void:
		_lock.lock()
		_offsets.clear()
		_patterns.clear()
		_rows.clear()
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
## never grows past the gather volume. A caller uses it to choose the inline path
## or the worker path before it pays the gather.
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


## Samples the write set of one spray batch.
##
## The gather reads the occupied cells of the reach range, the candidate pool is
## the search sphere inside the range, and the partial shuffle picks distinct
## spot centers. Every spot then paints its footprint. The optional [param job]
## supplies the cancel checkpoints. A caller that passes [param report] receives
## the gathered and the candidate cell counts in it.
static func sample(center: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext, spot_size: int, search_size: int, speed: int, rng: RandomNumberGenerator, material: PackedFloat32Array, cache: ShapeCache, job: VoxelFrame.EditJob = null, report: Dictionary = {}) -> Array[Vector3i]:
	var reach := VoxelBrushSize.reach(search_size) + VoxelBrushSize.reach(spot_size)
	var local := local_cells(center, reach, frame, context, job)
	report["local"] = local.size()
	return sample_local(center, frame, context, local, spot_size, search_size, speed, rng, material, cache, job, report)


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
		var location := VoxelFrame.chunk_position(cell)
		var cached: Variant = grids.get(location)
		if cached == null:
			var chunk: VoxelFrame.Chunk = frame.chunks.get(location)
			cached = chunk.grid if chunk != null else PackedInt32Array()
			grids[location] = cached
		var grid: PackedInt32Array = cached
		if grid.is_empty():
			return false
		var local := cell - location * VoxelFrame.CHUNK_SIZE
		return grid[local.x + VoxelFrame.CHUNK_SIZE * (local.y + VoxelFrame.CHUNK_SIZE * local.z)] > 0


## Expands a change set through the symmetry and the selection with a raw
## occupancy view.
##
## The mask order, the loop order, the selection filter, the existing-only filter,
## and the original-overlap priority match [method
## VoxelFrame.EditContext.expand], so the result holds the same cells, the same
## materials, and the same key order. The view reads the whole frozen frame, so a
## mirrored destination outside the gathered region is exact. The caller passes
## `existing_only` true and no matching material, which is the only supported
## form.
static func expand_occupied(changes: Dictionary, occupancy: Occupancy, axes: int, origin_twice: Vector3i, selection: Dictionary, job: VoxelFrame.EditJob = null) -> Dictionary:
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
			if (not filtered or selection.has(destination)) and occupancy.occupied(destination):
				expanded[destination] = value
			completed += 1
			if job and completed % 4096 == 0 and not job.checkpoint(completed):
				return {}
	if axes == 0:
		return expanded
	# Preserve the original materials where the original and the reflected
	# patterns overlap.
	for cell: Vector3i in changes:
		if (not filtered or selection.has(cell)) and occupancy.occupied(cell):
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
static func sample_local(center: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext, local: Array[Vector3i], spot_size: int, search_size: int, speed: int, rng: RandomNumberGenerator, material: PackedFloat32Array, cache: ShapeCache, job: VoxelFrame.EditJob = null, report: Dictionary = {}) -> Array[Vector3i]:
	var candidates := candidate_cells(center, local, search_size)
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
	var changes := footprints(spots, local, spot_size, material, cache, job)
	# Every change is already occupied and selection-filtered, so an identity
	# context needs no expansion. A symmetry or selection context still expands,
	# because its mirrored destinations must exist too. The expansion reads the
	# frozen frame through a raw occupancy view, so a mirrored destination outside
	# the gathered region is exact and costs one array read.
	var cells: Array[Vector3i] = []
	if context.axes == 0 and context.selection.is_empty():
		if job and not job.checkpoint(0):
			return []
		cells.assign(changes.keys())
		return cells
	var occupancy := Occupancy.new()
	occupancy.frame = frame
	cells.assign(expand_occupied(changes, occupancy, context.axes, context.origin_twice, context.selection, job).keys())
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
static func footprints(spots: Array[Vector3i], local: Array[Vector3i], spot_size: int, material: PackedFloat32Array, cache: ShapeCache, job: VoxelFrame.EditJob = null) -> Dictionary:
	var changes := {}
	# Diameter 1 paints the spot center alone, so the changes are the centers and
	# no sphere test is needed.
	if spot_size == 1:
		for spot in spots:
			changes[spot] = material
		return changes
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
		return changes
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
	return changes


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
