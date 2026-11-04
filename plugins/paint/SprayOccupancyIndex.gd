class_name SprayOccupancyIndex
extends RefCounted

## Pure occupancy-row helpers for the spray sampler.
##
## The spray samples distinct occupied spot centers from the search sphere. A
## chunk already stores its 16-cube grid, so this script reads one occupied row
## at a time instead of walking every cell of the reach ball. Row k holds the
## local row (y, z), where k is `y + CHUNK_SIZE * z`. That is the same order as
## the chunk grid slot walk, so the candidate order stays the one the old gather
## produced.
##
## The query box uses the exact canonical cell bounds of the sphere. A size of 64
## at an aligned origin therefore covers 64 cells and four chunks per axis, not
## the wider integer reach box. A chunk that misses the sphere is filtered by the
## doubled integer test.
##
## The sphere span uses the same half-cell center and squared radius as
## [method VoxelBrushSize.contains_sphere]. The integer form avoids a float
## boundary drift, so an even size keeps the brush alignment. One [SphereSpans]
## table holds every row span of a size, so a query pays the square root once per
## size, not once per chunk row.
##
## The script names only pure helpers. A caller preloads it.

const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")

# The number of set bits in each 4-bit nibble.
const POPCOUNT4 := [0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4]
# A selection above this count uses per-chunk masks. A smaller selection uses a
# chunk bucket and a native slot sort, which is cheaper than building masks.
const SELECTION_BUCKET_LIMIT := 4096


## Returns the row index of one local row. Row k holds (y, z), where k is
## `y + CHUNK_SIZE * z`.
static func row_index(local_y: int, local_z: int) -> int:
	return local_y + VoxelFrame.CHUNK_SIZE * local_z


## Returns the number of set bits in a 16-bit row mask.
static func popcount16(mask: int) -> int:
	return POPCOUNT4[mask & 15] + POPCOUNT4[(mask >> 4) & 15] + POPCOUNT4[(mask >> 8) & 15] + POPCOUNT4[(mask >> 12) & 15]


## Returns the x bits of one inclusive local span.
static func span_mask(low: int, high: int) -> int:
	if high < low:
		return 0
	return ((1 << (high - low + 1)) - 1) << low


## Returns the occupied cell count of one row inside one inclusive local span.
static func count_in_span(mask: int, low: int, high: int) -> int:
	return popcount16(mask & span_mask(low, high))


## Returns the local x of the rank-th occupied cell inside one inclusive span,
## or -1 when the span holds fewer cells.
static func nth_in_span(mask: int, low: int, high: int, rank: int) -> int:
	var bits := mask & span_mask(low, high)
	for x in range(low, high + 1):
		if bits & (1 << x) == 0:
			continue
		if rank == 0:
			return x
		rank -= 1
	return -1


## Returns the relative world x span of one sphere row, or
## [code]Vector2i(1, 0)[/code] when the row holds no cell.
##
## The test is the integer form of [method VoxelBrushSize.contains_sphere]:
## `(2 * offset + e) squared` on each axis, where e is one for an even size and
## zero for an odd size. The two forms agree exactly.
static func sphere_x_span_relative(size: int, dy: int, dz: int) -> Vector2i:
	var even := 1 if size % 2 == 0 else 0
	var u := 2 * dy + even
	var v := 2 * dz + even
	var rest := size * size - u * u - v * v
	if rest < 0:
		return Vector2i(1, 0)
	var limit := int(sqrt(float(rest)))
	while (limit + 1) * (limit + 1) <= rest:
		limit += 1
	while limit * limit > rest:
		limit -= 1
	var low := 0
	var high := 0
	if even == 0:
		low = -2 * (limit / 2)
		high = 2 * (limit / 2)
	else:
		if limit < 1:
			return Vector2i(1, 0)
		var odd := 2 * ((limit - 1) / 2) + 1
		low = -odd
		high = odd
	return Vector2i((low - even) / 2, (high - even) / 2)


## Returns the world x span of one sphere row, or [code]Vector2i(1, 0)[/code]
## when the row holds no cell.
static func sphere_x_span(center: Vector3i, size: int, y: int, z: int) -> Vector2i:
	var relative := sphere_x_span_relative(size, y - center.y, z - center.z)
	if relative.x > relative.y:
		return relative
	return Vector2i(center.x + relative.x, center.x + relative.y)


## Returns the exact canonical cell bounds of one sphere. The low and high cells
## are inclusive.
static func cell_bounds(center: Vector3i, size: int) -> Array[Vector3i]:
	var first := VoxelBrushSize.first_offset(size)
	var last := VoxelBrushSize.last_offset(size)
	return [center + Vector3i.ONE * first, center + Vector3i.ONE * last]


## Returns [code]true[/code] when one chunk can hold a cell of the sphere. The
## test uses the nearest cell of the chunk box in the doubled integer form, so a
## corner chunk that misses the sphere pays no row scan.
static func chunk_intersects(center: Vector3i, size: int, chunk: VoxelFrame.Chunk) -> bool:
	var origin := chunk.origin()
	var high := origin + Vector3i.ONE * (VoxelFrame.CHUNK_SIZE - 1)
	var even := 1 if size % 2 == 0 else 0
	var u := 2 * (clampi(center.x, origin.x, high.x) - center.x) + even
	var v := 2 * (clampi(center.y, origin.y, high.y) - center.y) + even
	var w := 2 * (clampi(center.z, origin.z, high.z) - center.z) + even
	return u * u + v * v + w * w <= size * size


## Returns the chunk locations that one sample can read or write.
##
## The box covers the search sphere and the selected spot footprint, then every
## active symmetry reflection of that whole box. The box is conservative: the
## spot centers are inside the search sphere, so the sum of the first and last
## offsets covers every footprint and every mirrored footprint. Missing chunks
## are ignored by [method VoxelFrame.copy_chunks]. The cost follows the box, not
## the whole frame.
static func capture_chunks(center: Vector3i, search_size: int, spot_size: int, axes: int, origin_twice: Vector3i) -> Array[Vector3i]:
	var first := VoxelBrushSize.first_offset(search_size) + VoxelBrushSize.first_offset(spot_size)
	var last := VoxelBrushSize.last_offset(search_size) + VoxelBrushSize.last_offset(spot_size)
	var low := center + Vector3i.ONE * first
	var high := center + Vector3i.ONE * last
	var locations := {}
	for mask in 8:
		if (mask & ~axes) != 0:
			continue
		var reflected_low := low
		var reflected_high := high
		for axis in 3:
			if mask & (1 << axis):
				reflected_low[axis] = origin_twice[axis] - high[axis]
				reflected_high[axis] = origin_twice[axis] - low[axis]
		var min_chunk := VoxelFrame.chunk_position(reflected_low)
		var max_chunk := VoxelFrame.chunk_position(reflected_high)
		for x in range(min_chunk.x, max_chunk.x + 1):
			for y in range(min_chunk.y, max_chunk.y + 1):
				for z in range(min_chunk.z, max_chunk.z + 1):
					locations[Vector3i(x, y, z)] = true
	var result: Array[Vector3i] = []
	result.assign(locations.keys())
	return result


## The exact row spans of one sphere size, indexed by relative (dy, dz).
class SphereSpans extends RefCounted:
	## The sphere size in cells.
	var size := 1
	## The first relative offset on each axis.
	var first := 0
	## The relative x span of each row, indexed by `(dy - first) * size + (dz - first)`.
	var spans: Array[Vector2i] = []

	## Returns the relative x span of one relative row, or an empty span.
	func span(dy: int, dz: int) -> Vector2i:
		if dy < first or dz < first or dy >= first + size or dz >= first + size:
			return Vector2i(1, 0)
		return spans[(dy - first) * size + (dz - first)]

	## Builds the span table of one size.
	static func build(value_size: int) -> SphereSpans:
		var result := SphereSpans.new()
		result.size = value_size
		result.first = VoxelBrushSize.first_offset(value_size)
		result.spans.resize(value_size * value_size)
		for dy in range(result.first, result.first + value_size):
			for dz in range(result.first, result.first + value_size):
				result.spans[(dy - result.first) * value_size + (dz - result.first)] = SprayOccupancyIndex.sphere_x_span_relative(value_size, dy, dz)
		return result


## The per-chunk row masks of one selection. The masks are immutable after the
## build. A caller can keep one entry for a frozen selection snapshot.
class SelectionIndex extends RefCounted:
	## The selected x bits of each local row, keyed by chunk location then row.
	var masks_by_chunk := {}
	## The number of selected cells.
	var selected_count := 0

	## Returns the selected row masks of one chunk, or an empty dictionary.
	func masks_for(location: Vector3i) -> Dictionary:
		var bucket: Variant = masks_by_chunk.get(location)
		return bucket if bucket != null else {}

	## Builds the selection masks. An optional [param job] supplies the cancel
	## checkpoints. A cancelled build returns null.
	static func build(selection: Dictionary, job: VoxelFrame.EditJob = null) -> SelectionIndex:
		var result := SelectionIndex.new()
		var completed := 0
		for cell: Vector3i in selection:
			completed += 1
			if job and completed % 4096 == 0 and not job.checkpoint(completed):
				return null
			var location := VoxelFrame.chunk_position(cell)
			var local := cell - location * VoxelFrame.CHUNK_SIZE
			var row := local.y + VoxelFrame.CHUNK_SIZE * local.z
			var bucket: Variant = result.masks_by_chunk.get(location)
			if bucket == null:
				bucket = {}
				result.masks_by_chunk[location] = bucket
			bucket[row] = bucket.get(row, 0) | (1 << local.x)
			result.selected_count += 1
		return result


## The occupied candidates of one search sphere.
##
## The candidate order is the chunk walk order of the old gather: ascending
## chunk x, y, z, then ascending local slot. A small selection keeps the same
## order through a chunk bucket and a native slot sort. A large selection uses
## the same row masks as the occupied cells. The set never builds the whole
## candidate array for the indexed path.
class Candidates extends RefCounted:
	## The candidate count.
	var total := 0
	## The number of candidate lookups.
	var rank_calls := 0
	## The number of chunk rows a candidate lookup read.
	var rank_rows := 0
	## The number of chunks the count walked.
	var chunks_scanned := 0
	## The number of chunk rows the count read.
	var rows_scanned := 0
	## The number of chunk row builds that the count paid.
	var index_builds := 0
	## The dense grid slots that those builds read.
	var index_grid_reads := 0
	## The row masks that those builds wrote.
	var index_build_slots := 0
	## The number of selection entries the bucket path checked.
	var selection_checked := 0
	## The number of selection mask builds the sample paid.
	var selection_builds := 0
	## The row work of the selection path. A bucket check costs half a row op per
	## entry, and a mask build costs one row op per selected cell. A reused index
	## costs nothing here.
	var selection_work := 0
	## The selection index used by this sample, or null.
	var selection_index: RefCounted = null
	var _center := Vector3i.ZERO
	var _size := 1
	var _spans: RefCounted = null
	var _selected: Array[Vector3i] = []
	var _records: Array = []
	var _use_selection := false

	## Returns the candidate at one index in the old gather order.
	func candidate(index: int) -> Vector3i:
		rank_calls += 1
		if _use_selection:
			return _selected[index]
		var low := 0
		var high := _records.size() - 1
		while low <= high:
			var mid := (low + high) / 2
			var record: Array = _records[mid]
			var start: int = record[1]
			var count: int = record[2]
			if index < start:
				high = mid - 1
			elif index >= start + count:
				low = mid + 1
			else:
				var chunk: VoxelFrame.Chunk = record[0]
				var rows := [0]
				var masks := {}
				if selection_index != null:
					masks = selection_index.masks_for(chunk.location)
				var cell := SprayOccupancyIndex._nth_chunk(chunk, _center, _size, _spans, index - start, rows, masks)
				rank_rows += rows[0]
				return cell
		return Vector3i.ZERO


## Builds the occupied candidates of one search sphere. An optional [param job]
## supplies the cancel checkpoints. An optional [param selection_index] reuses
## the masks of a frozen selection. An optional [param spans] reuses the exact
## row table of the search size.
static func build_candidates(center: Vector3i, frame: VoxelFrame, size: int, selection: Dictionary, job: VoxelFrame.EditJob = null, selection_index: RefCounted = null, spans: RefCounted = null) -> Candidates:
	var result := Candidates.new()
	result._center = center
	result._size = size
	result._spans = spans if spans != null else SphereSpans.build(size)
	if selection.is_empty():
		_build_indexed(center, frame, size, result, job)
		return result
	if selection_index != null:
		result.selection_index = selection_index
		_build_indexed(center, frame, size, result, job)
		return result
	if selection.size() <= SELECTION_BUCKET_LIMIT:
		_build_bucket(center, frame, size, selection, job, result)
		return result
	var built := SelectionIndex.build(selection, job)
	if built == null:
		result.total = 0
		return result
	result.selection_builds = 1
	result.selection_work = built.selected_count
	result.selection_index = built
	_build_indexed(center, frame, size, result, job)
	return result


# Counts the candidates from chunk rows. A null selection index counts every
# occupied row. A selection index intersects the selection masks.
static func _build_indexed(center: Vector3i, frame: VoxelFrame, size: int, result: Candidates, job: VoxelFrame.EditJob) -> void:
	var bounds := cell_bounds(center, size)
	var min_chunk := VoxelFrame.chunk_position(bounds[0])
	var max_chunk := VoxelFrame.chunk_position(bounds[1])
	var start := 0
	var completed := 0
	for x in range(min_chunk.x, max_chunk.x + 1):
		for y in range(min_chunk.y, max_chunk.y + 1):
			for z in range(min_chunk.z, max_chunk.z + 1):
				result.chunks_scanned += 1
				var location := Vector3i(x, y, z)
				var chunk: VoxelFrame.Chunk = frame.chunks.get(location)
				var masks := {}
				if result.selection_index != null:
					masks = result.selection_index.masks_for(location)
					if masks.is_empty():
						completed += 1
						if job and completed % 8 == 0 and not job.checkpoint(completed):
							result.total = 0
							result._records.clear()
							return
						continue
				if chunk != null and chunk.occupied_count > 0 and chunk_intersects(center, size, chunk):
					var was_current := chunk.occupancy_index_current()
					if not was_current:
						result.index_builds += 1
					var rows := [0]
					var count := _count_chunk(chunk, center, size, result._spans, rows, masks)
					result.rows_scanned += rows[0]
					if not was_current:
						var built := chunk.occupancy_rows()
						result.index_grid_reads += built.grid_reads
						result.index_build_slots += built.build_slots
					if count > 0:
						result._records.append([chunk, start, count])
						start += count
				completed += 1
				if job and completed % 8 == 0 and not job.checkpoint(completed):
					result.total = 0
					result._records.clear()
					return
	result.total = start


# Builds the ordered selected cells for a small selection. Each chunk bucket is
# sorted by its native integer slot order, so the result keeps the chunk walk
# order of the old gather without one global comparator sort.
static func _build_bucket(center: Vector3i, frame: VoxelFrame, size: int, selection: Dictionary, job: VoxelFrame.EditJob, result: Candidates) -> void:
	var buckets := {}
	var completed := 0
	for cell: Vector3i in selection:
		completed += 1
		result.selection_checked += 1
		if job and completed % 4096 == 0 and not job.checkpoint(completed):
			result.total = 0
			return
		if not frame.has(cell):
			continue
		if not VoxelBrushSize.contains_sphere(size, cell - center):
			continue
		var location := VoxelFrame.chunk_position(cell)
		var bucket: Variant = buckets.get(location)
		if bucket == null:
			bucket = []
			buckets[location] = bucket
		var local := cell - location * VoxelFrame.CHUNK_SIZE
		bucket.append(local.x + VoxelFrame.CHUNK_SIZE * (local.y + VoxelFrame.CHUNK_SIZE * local.z))
	var bounds := cell_bounds(center, size)
	var min_chunk := VoxelFrame.chunk_position(bounds[0])
	var max_chunk := VoxelFrame.chunk_position(bounds[1])
	var cells: Array[Vector3i] = []
	for x in range(min_chunk.x, max_chunk.x + 1):
		for y in range(min_chunk.y, max_chunk.y + 1):
			for z in range(min_chunk.z, max_chunk.z + 1):
				var location := Vector3i(x, y, z)
				var bucket: Variant = buckets.get(location)
				if bucket == null:
					continue
				var slots: Array = bucket
				slots.sort()
				var origin := location * VoxelFrame.CHUNK_SIZE
				for slot: int in slots:
					var local := Vector3i(slot % VoxelFrame.CHUNK_SIZE, (slot / VoxelFrame.CHUNK_SIZE) % VoxelFrame.CHUNK_SIZE, slot / (VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE))
					cells.append(origin + local)
				completed += 1
				if job and not job.checkpoint(completed):
					result.total = 0
					return
	result._use_selection = true
	result._selected = cells
	result.total = cells.size()
	result.selection_work = result.selection_checked / 2


## Returns a cheap conservative work estimate for one sample. The unit is one
## indexed row operation: one local chunk row of a nonempty chunk, one selected
## spot for the rank walk, one footprint row entry, and one selection entry for
## a small bucket or a large mask build. It never counts candidate cells and
## never walks the whole frame: it reads only the chunks of the query box.
##
## The estimate covers the warm sample. It does not include the one-time row
## build of a cold chunk, which reads one dense chunk grid per touched nonempty
## chunk. A caller that needs the cold cost measures `index_builds` and
## `index_grid_reads` from the sample report.
static func work_estimate(frame: VoxelFrame, center: Vector3i, search_size: int, spot_size: int, selection: Dictionary, speed: int, selection_index: RefCounted = null) -> int:
	var search_first := VoxelBrushSize.first_offset(search_size)
	var search_last := VoxelBrushSize.last_offset(search_size)
	var spot_first := VoxelBrushSize.first_offset(spot_size)
	var spot_last := VoxelBrushSize.last_offset(spot_size)
	var low := center + Vector3i.ONE * (search_first + spot_first)
	var high := center + Vector3i.ONE * (search_last + spot_last)
	var min_chunk := VoxelFrame.chunk_position(low)
	var max_chunk := VoxelFrame.chunk_position(high)
	var search_chunks := 0
	var combined_chunks := 0
	var occupied_hint := 0
	for x in range(min_chunk.x, max_chunk.x + 1):
		for y in range(min_chunk.y, max_chunk.y + 1):
			for z in range(min_chunk.z, max_chunk.z + 1):
				var chunk: VoxelFrame.Chunk = frame.chunks.get(Vector3i(x, y, z))
				if chunk == null or chunk.occupied_count == 0:
					continue
				combined_chunks += 1
				occupied_hint += chunk.occupied_count
				if chunk_intersects(center, search_size, chunk):
					search_chunks += 1
	var selection_work := 0
	if not selection.is_empty() and selection_index == null:
		# A small selection walks its own cells and sorts small chunk buckets, so
		# one entry costs half a row operation. A large selection pays a mask
		# build, so one entry costs one row operation.
		if selection.size() <= SELECTION_BUCKET_LIMIT:
			selection_work = selection.size() / 2
		else:
			selection_work = selection.size()
	var spot_count := mini(speed, occupied_hint)
	var footprint_rows := 0
	if spot_size > 1 and spot_count > 0:
		if occupied_hint <= spot_count * 4:
			footprint_rows = spot_count * combined_chunks * VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE
		else:
			footprint_rows = spot_count * spot_size * spot_size
	# The sphere row spans add work beyond the chunk-row loop. The size square
	# bounds the row count; the chunk count bounds the rows the frame can hold.
	var span_work := mini(search_size * search_size, combined_chunks * VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE)
	return search_chunks * VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE + span_work + selection_work + spot_count + footprint_rows


# Returns the occupied cells of one chunk inside the sphere. The caller adds the
# row count to its work report.
static func _count_chunk(chunk: VoxelFrame.Chunk, center: Vector3i, size: int, spans: RefCounted, rows: Array, selection_masks: Dictionary) -> int:
	var origin := chunk.origin()
	var index := chunk.occupancy_rows()
	if index == null:
		return 0
	var total := 0
	for row in VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE:
		rows[0] += 1
		if index.counts[row] == 0:
			continue
		var local_y := row & (VoxelFrame.CHUNK_SIZE - 1)
		var local_z := row >> VoxelFrame.CHUNK_SHIFT
		var y := origin.y + local_y
		var z := origin.z + local_z
		var relative: Vector2i = spans.span(y - center.y, z - center.z)
		if relative.x > relative.y:
			continue
		var low := maxi(center.x + relative.x, origin.x) - origin.x
		var high := mini(center.x + relative.y, origin.x + VoxelFrame.CHUNK_SIZE - 1) - origin.x
		if low > high:
			continue
		var mask := index.masks[row]
		if not selection_masks.is_empty():
			mask &= selection_masks.get(row, 0)
			if mask == 0:
				continue
		total += count_in_span(mask, low, high)
	return total


# Returns the rank-th occupied cell of one chunk inside the sphere. The caller
# adds the row count to its work report.
static func _nth_chunk(chunk: VoxelFrame.Chunk, center: Vector3i, size: int, spans: RefCounted, rank: int, rows: Array, selection_masks: Dictionary) -> Vector3i:
	var origin := chunk.origin()
	var index := chunk.occupancy_rows()
	if index == null:
		return Vector3i.ZERO
	for row in VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE:
		rows[0] += 1
		if index.counts[row] == 0:
			continue
		var local_y := row & (VoxelFrame.CHUNK_SIZE - 1)
		var local_z := row >> VoxelFrame.CHUNK_SHIFT
		var y := origin.y + local_y
		var z := origin.z + local_z
		var relative: Vector2i = spans.span(y - center.y, z - center.z)
		if relative.x > relative.y:
			continue
		var low := maxi(center.x + relative.x, origin.x) - origin.x
		var high := mini(center.x + relative.y, origin.x + VoxelFrame.CHUNK_SIZE - 1) - origin.x
		if low > high:
			continue
		var mask := index.masks[row]
		if not selection_masks.is_empty():
			mask &= selection_masks.get(row, 0)
			if mask == 0:
				continue
		var count := count_in_span(mask, low, high)
		if rank >= count:
			rank -= count
			continue
		var x := nth_in_span(mask, low, high, rank)
		if x >= 0:
			return Vector3i(origin.x + x, y, z)
	return Vector3i.ZERO
