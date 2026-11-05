class_name VoxelRegionSearch
extends RefCounted

## Searches one snapshot frame for a material.
##
## One search serves the bucket fill and the wand. A connected search floods the
## six face neighbors from a seed. A disconnected search scans every occupied
## cell. The caller keeps its own policy for the result.
##
## The search only reads the frame, so a worker can run it beside the live
## document. A canceled [param job] makes the search return [code]false[/code],
## and the caller must discard the result. The search writes [param value] into
## [param result] for every match, so the caller needs no conversion pass.

# One region search serves the bucket fill and the wand. Both need the same walk
# over one snapshot frame: a connected flood through the six face neighbors, or a
# scan of every occupied cell. The caller keeps its own policy. The fill paints
# the matches and treats the selection mask as a barrier. The wand builds a
# selection, expands it by symmetry, and merges it by mode.
#
# Contract:
# - `frame` is a snapshot. The search only reads it, so a worker can run it beside
#   the live document.
# - `result` starts empty. The search writes `value` for every match. The caller
#   receives its own structure directly, so it needs no conversion pass.
# - A connected search requires `seed_cell` to be an occupied cell that holds
#   `target_material`. A seed that does not match adds nothing and leaves the
#   result empty.
# - A disconnected search ignores the seed and scans the frame, so the caller can
#   pass any cell. It visits every occupied cell of the frame.
# - A connected search walks the six face neighbors only. It never scans the whole
#   frame, so a small island in a large frame stays cheap.
# - A non-empty `selection_mask` blocks traversal and matching. The seed is not
#   tested against the mask, because the caller already rejects a seed it cannot
#   edit.
# - The search calls `job.checkpoint()` at entry, at every 4096 examined cells, and
#   at each chunk boundary of the disconnected scan. It returns false when the job
#   was cancelled, and the caller must discard `result`.
# - An optional `stream` callable receives the found cells in batches while the
#   search runs, so a caller can publish partial work. It runs on the searching
#   thread and takes ownership of each batch array. The search still fills `result`
#   with the exact final set, so a streaming caller and an atomic caller agree.
# - Material ids are local to a chunk. The search never compares ids across chunks.

## The chunk edge length in cells.
const CHUNK_SIZE := VoxelFrame.CHUNK_SIZE
## The cell count of one chunk.
const CHUNK_CELLS := CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE
# Hoisted so the hot compare does not look the constant up on another class.
## The float count of one material.
const MATERIAL_STRIDE := VoxelFrame.MATERIAL_STRIDE
## The six face directions.
const DIRECTIONS := VoxelFrame.DIRECTIONS
# The cells one streamed batch holds. A batch bounds both the handoff memory and
# the work a consumer does between two checks.
## The cell count of one streamed batch.
const STREAM_BATCH := 512


# A bounded handoff from the searching worker to the main thread. The worker pushes
# a batch and waits while the queue is full, so the producer cannot run away from
# the consumer. The consumer never waits. `cancel` wakes a waiting producer, so a
# cancelled operation always lets its worker finish.
## A bounded handoff from a searching worker to the main thread.
##
## The producer waits while the queue is full, so it cannot run away from the
## consumer. The consumer never waits. [method cancel] wakes a waiting producer.
class BatchQueue extends RefCounted:
	## The maximum queued batch count.
	const LIMIT := 4

	var _batches: Array = []
	var _mutex := Mutex.new()
	var _free := Semaphore.new()
	var _cancelled := false

	# Take ownership of one batch. Returns false when the queue was cancelled, and
	# the producer must then stop.
	## Takes ownership of one batch. Returns [code]false[/code] when the queue was
	## canceled, and the producer must then stop.
	func push(batch: Dictionary) -> bool:
		while true:
			_mutex.lock()
			if _cancelled:
				_mutex.unlock()
				return false
			if _batches.size() < LIMIT:
				_batches.append(batch)
				_mutex.unlock()
				return true
			_mutex.unlock()
			_free.wait()
		return false

	# The next batch, or an empty dictionary when none waits. The main thread calls
	# this. A pushed batch is never empty.
	## Returns the next batch, or an empty dictionary when none waits. Call it on
	## the main thread. A pushed batch is never empty.
	func take() -> Dictionary:
		_mutex.lock()
		var batch := {}
		if not _batches.is_empty():
			batch = _batches.pop_front()
		_mutex.unlock()
		if not batch.is_empty():
			_free.post()
		return batch

	# Refuse every later push and wake a waiting producer.
	## Refuses every later push and wakes a waiting producer.
	func cancel() -> void:
		_mutex.lock()
		_cancelled = true
		_mutex.unlock()
		_free.post()

	## Returns [code]true[/code] when the queue was canceled.
	func is_cancelled() -> bool:
		_mutex.lock()
		var value := _cancelled
		_mutex.unlock()
		return value

	## Returns [code]true[/code] when no batch waits.
	func is_empty() -> bool:
		_mutex.lock()
		var value := _batches.is_empty()
		_mutex.unlock()
		return value

	# The queued batch count, for a diagnostic read from another thread.
	## Returns the queued batch count. A diagnostic can read it from another
	## thread.
	func depth() -> int:
		_mutex.lock()
		var value := _batches.size()
		_mutex.unlock()
		return value


# A consumer cursor over one bounded queue. It owns the queue, the keys of the
# batch in progress, and the cursor into them, so the pending keys and their
# position always move together. Both the streamed fill and the streamed wand
# consume their queue through `apply_slice`. It calls only `take`, so a full queue
# still blocks the producer and never the consumer. The fields stay public, so a
# caller can read the pending batch without a property call.
## A consumer cursor over one bounded [BatchQueue].
##
## It owns the queue, the keys of the batch in progress, and the cursor into
## them. The fields are public, so a hot loop reads them without a property call.
class BatchCursor extends RefCounted:
	## The queue that the cursor consumes.
	var queue: BatchQueue
	## The keys of the batch in progress.
	var keys: Array = []
	## The cursor into [member keys].
	var cursor := 0
	# A callback that reads or applies a slice must not consume the same cursor
	# again. The guard refuses that nested call, so the outer slice keeps its end.
	var _applying := false

	func _init(batch_queue: BatchQueue = null) -> void:
		queue = batch_queue

	# True when the queue is drained and every key of the current batch is applied.
	# It does not report that the producer finished. The caller tests its worker
	# task separately.
	## Returns [code]true[/code] when the queue is drained and every key of the
	## current batch is applied. It does not report that the producer finished.
	func is_done() -> bool:
		return cursor >= keys.size() and queue.is_empty()

	# The end of the next slice, or -1 when no key waits. Loads the next queued
	# batch only when the current keys are consumed. A pushed batch is never empty,
	# so a loaded batch always holds at least one key.
	## Returns the end of the next slice, or -1 when no key waits. It loads the
	## next queued batch only when the current keys are consumed.
	func next_end(limit: int) -> int:
		if cursor >= keys.size():
			var batch := queue.take()
			if batch.is_empty():
				return -1
			keys = batch.keys()
			cursor = 0
		return mini(cursor + limit, keys.size())

	# Hand one bounded slice to `apply`. It receives the keys and the [start, end)
	# range of the slice. The cursor advances only after `apply` returns true, so a
	# caller that refuses a stale slice keeps it for the next owner. A nested call
	# from inside `apply` returns false, so a callback cannot rewind the cursor it
	# is consuming. A cursor without a queue yields no slice.
	## Hands one bounded slice to [param apply]. It receives the keys and the
	## [code][start, end)[/code] range of the slice. The cursor advances only
	## after [param apply] returns [code]true[/code], so a caller that refuses a
	## stale slice keeps it. A nested call from inside [param apply] returns
	## [code]false[/code]. A cursor without a queue yields no slice.
	func apply_slice(limit: int, apply: Callable) -> bool:
		if queue == null or _applying:
			return false
		var end := next_end(limit)
		if end <= cursor:
			return false
		var start := cursor
		_applying = true
		var accepted: bool = apply.call(keys, start, end)
		_applying = false
		if not accepted:
			return false
		cursor = end
		return true


## Searches [param frame] and fills [param result] with every match. A
## [param connected] search floods the six face neighbors from [param seed_cell].
## A disconnected search scans every occupied cell. A non-empty
## [param selection_mask] blocks traversal and matching. Returns [code]false[/code]
## when [param job] cancels, and the caller must discard [param result].
## [param stream] receives the found cells in batches while the search runs.
## [param slice_axis] and [param slice_index] bound the search to one layer when
## the axis is not -1. A flood must not cross a layer, or a fill would paint
## disconnected patches of the slice.
static func find(result: Dictionary, frame: VoxelFrame, seed_cell: Vector3i, target_material: PackedFloat32Array, connected: bool, value: Variant = true, selection_mask: Dictionary = {}, job: VoxelFrame.EditJob = null, stream: Callable = Callable(), slice_axis := -1, slice_index := 0) -> bool:
	if frame == null:
		return true
	# The entry check makes a cancellation that arrived before the call deterministic.
	if job and not job.checkpoint(0):
		return false
	if connected:
		if slice_axis >= 0 and seed_cell[slice_axis] != slice_index:
			return true
		return _find_connected(result, frame, seed_cell, target_material, value, selection_mask, job, stream, slice_axis, slice_index)
	return _find_occupied(result, frame, target_material, value, selection_mask, job, stream, slice_axis, slice_index)


# A flood through the six face neighbors. The chunk of the current cell is held
# between steps, so a step inside one chunk needs no frame lookup. Its grid and
# material table are held too, because a property read on another object costs more
# than an index into a local. The local slot and its bounds are computed inline, so
# a probe avoids the `material_id` and `cell_slot` calls. The walk order and the
# result insertion order are unchanged, and the helper reads the frame only.
static func _find_connected(result: Dictionary, frame: VoxelFrame, seed_cell: Vector3i, target_material: PackedFloat32Array, value: Variant, selection_mask: Dictionary, job: VoxelFrame.EditJob, stream: Callable, slice_axis := -1, slice_index := 0) -> bool:
	var seed_chunk: VoxelFrame.Chunk = frame.chunks.get(VoxelFrame.chunk_position(seed_cell))
	if not _chunk_matches(seed_chunk, seed_cell, target_material):
		return true
	var streaming := stream.is_valid()
	var batch: Array[Vector3i] = []
	var pending: Array[Vector3i] = [seed_cell]
	result[seed_cell] = value
	if streaming:
		batch.append(seed_cell)
	var mask_active := not selection_mask.is_empty()
	var examined := 0
	var current_location := Vector3i.MAX
	var current_chunk: VoxelFrame.Chunk = null
	var current_grid := PackedInt32Array()
	var current_materials := PackedFloat32Array()
	var current_origin := Vector3i.ZERO
	var cached := false
	var matches := {}
	while not pending.is_empty():
		var cell_position: Vector3i = pending.pop_back()
		var location := VoxelFrame.chunk_position(cell_position)
		if location != current_location:
			current_location = location
			current_chunk = frame.chunks.get(location)
			if current_chunk:
				current_grid = current_chunk.grid
				current_materials = current_chunk.materials
				current_origin = location * CHUNK_SIZE
			cached = _cache_pays(current_chunk)
			matches.clear()
		var origin_x := current_origin.x
		var origin_y := current_origin.y
		var origin_z := current_origin.z
		for direction in DIRECTIONS:
			var neighbor: Vector3i = cell_position + direction
			if result.has(neighbor):
				continue
			if slice_axis >= 0 and neighbor[slice_axis] != slice_index:
				continue
			if mask_active and not selection_mask.has(neighbor):
				continue
			var local_x := neighbor.x - origin_x
			var local_y := neighbor.y - origin_y
			var local_z := neighbor.z - origin_z
			if local_x >= 0 and local_y >= 0 and local_z >= 0 and local_x < CHUNK_SIZE and local_y < CHUNK_SIZE and local_z < CHUNK_SIZE:
				var slot := local_x + CHUNK_SIZE * (local_y + CHUNK_SIZE * local_z)
				if cached:
					if not _id_matches_cached(current_materials, current_grid[slot], target_material, matches):
						continue
				elif not _id_matches(current_materials, current_grid[slot], target_material):
					continue
			else:
				var neighbor_location := VoxelFrame.chunk_position(neighbor)
				var neighbor_chunk: VoxelFrame.Chunk = frame.chunks.get(neighbor_location)
				if neighbor_chunk == null:
					continue
				var neighbor_origin := neighbor_location * CHUNK_SIZE
				var neighbor_local_x := neighbor.x - neighbor_origin.x
				var neighbor_local_y := neighbor.y - neighbor_origin.y
				var neighbor_local_z := neighbor.z - neighbor_origin.z
				var neighbor_slot := neighbor_local_x + CHUNK_SIZE * (neighbor_local_y + CHUNK_SIZE * neighbor_local_z)
				if not _id_matches(neighbor_chunk.materials, neighbor_chunk.grid[neighbor_slot], target_material):
					continue
			result[neighbor] = value
			pending.append(neighbor)
			if streaming:
				batch.append(neighbor)
				if batch.size() >= STREAM_BATCH:
					stream.call(batch)
					batch = []
		examined += 1
		if job and examined % 4096 == 0 and not job.checkpoint(result.size()):
			return false
	if streaming and not batch.is_empty():
		stream.call(batch)
	return true


# A scan of every occupied cell. The grid slots are walked in order, so the cell
# position follows from the slot and no position array is built. Each distinct
# material id of a chunk is compared once when the chunk holds few ids.
static func _find_occupied(result: Dictionary, frame: VoxelFrame, target_material: PackedFloat32Array, value: Variant, selection_mask: Dictionary, job: VoxelFrame.EditJob, stream: Callable, slice_axis := -1, slice_index := 0) -> bool:
	var streaming := stream.is_valid()
	var batch: Array[Vector3i] = []
	var mask_active := not selection_mask.is_empty()
	var examined := 0
	for chunk: VoxelFrame.Chunk in frame.chunks.values():
		# A sparse frame can hold one cell per chunk, so the slot walk would run a
		# long way between occupied-cell checkpoints. The chunk boundary bounds that
		# wait. `examined` still counts occupied cells, so the reported progress and
		# its total stay consistent with the caller's stage total.
		if job and not job.checkpoint(examined):
			return false
		var origin := chunk.origin()
		var grid := chunk.grid
		var materials := chunk.materials
		var cached := _cache_pays(chunk)
		var matches := {}
		for slot in CHUNK_CELLS:
			var id := grid[slot]
			if id == 0:
				continue
			var cell_position := origin + Vector3i(slot % CHUNK_SIZE, (slot / CHUNK_SIZE) % CHUNK_SIZE, slot / (CHUNK_SIZE * CHUNK_SIZE))
			var hit := _id_matches_cached(materials, id, target_material, matches) if cached else _id_matches(materials, id, target_material)
			if hit and (slice_axis < 0 or cell_position[slice_axis] == slice_index) and (not mask_active or selection_mask.has(cell_position)):
				result[cell_position] = value
				if streaming:
					batch.append(cell_position)
					if batch.size() >= STREAM_BATCH:
						stream.call(batch)
						batch = []
			examined += 1
			if job and examined % 4096 == 0 and not job.checkpoint(examined):
				return false
	if streaming and not batch.is_empty():
		stream.call(batch)
	return true


# The id cache costs two dictionary steps per cell and saves one compare per
# repeated id. It pays only when the chunk holds clearly more cells than table
# entries, which is the bulk-written chunk. A chunk written cell by cell holds one
# entry per cell, and there the cache costs more than the compare it replaces.
static func _cache_pays(chunk: VoxelFrame.Chunk) -> bool:
	if chunk == null:
		return false
	return chunk.occupied_count > 2 * (chunk.materials.size() / MATERIAL_STRIDE)


# True when one world cell holds the target material. A missing chunk and an empty
# cell both report false.
static func _chunk_matches(chunk: VoxelFrame.Chunk, cell_position: Vector3i, target_material: PackedFloat32Array) -> bool:
	if chunk == null:
		return false
	return _id_matches(chunk.materials, chunk.material_id(cell_position), target_material)


static func _id_matches_cached(materials: PackedFloat32Array, id: int, target_material: PackedFloat32Array, cache: Dictionary) -> bool:
	if id == 0:
		return false
	if cache.has(id):
		return cache[id]
	var equal := _id_matches(materials, id, target_material)
	cache[id] = equal
	return equal


# The match rule: all nine stored material values must agree.
static func _id_matches(materials: PackedFloat32Array, id: int, target_material: PackedFloat32Array) -> bool:
	if id == 0:
		return false
	var base := (id - 1) * MATERIAL_STRIDE
	for offset in MATERIAL_STRIDE:
		if materials[base + offset] != target_material[offset]:
			return false
	return true
