extends VoxelTool

## The bucket fill tool.
##
## A press fills the picked region with the current material. The tool queues
## one seed per visited cell during a drag. A small fill runs at once. A large
## fill streams its cells from a worker, and the main thread applies them in
## bounded slices. The stroke commits as one history action on release. Escape
## and a context change roll it back.

# The main-thread work one frame spends applying streamed fill batches. The worker
# waits when the queue fills, so this budget bounds both the frame cost and the
# handoff memory. Every seed of one frame shares the budget.
## The main-thread work budget per frame in microseconds.
const PUBLISH_BUDGET_US := 2000
# The destinations one set_cells call applies. A raw search batch of 512 cells can
# expand to eight times that through symmetry, and one indivisible call of that size
# can overrun the frame budget. The slice size follows the measured cost of the
# last call, so a fast machine applies more per call and a slow one less. The
# pending batch keeps its place across frames, so no destination is dropped.
## The minimum destination count of one apply slice.
const APPLY_SLICE_MIN := 64
## The maximum destination count of one apply slice.
const APPLY_SLICE_MAX := 512
# A changed-chunk notification wakes the renderer, which rebuilds the surfaces of
# the listed chunks. A notification every frame makes the earlier rebuilds
# obsolete, so the fill coalesces its chunk ids and notifies on this cadence. The
# first notification leaves at once, so a partial surface still installs early.
# The end of the operation always flushes the rest.
## The minimum frame gap between chunk notifications.
const NOTIFY_MIN_FRAMES := 3
## The minimum time gap between chunk notifications in microseconds.
const NOTIFY_MIN_INTERVAL_US := 20000

var _settings := preload("./settings.tres")
var _source_document: VoxelDocument
var _source_frame: VoxelFrame
var _replacement_material := VoxelFrame.material(Color.TRANSPARENT)
# The connected option is read once, when the stroke starts. A later option change
# must not alter the seeds a running stroke already queued.
var _stroke_connected := true
var _pending_seeds: Array[Vector3i] = []
# Every position the current stroke queued. A repeated position is a no-op: the
# first fill leaves the cell on the replacement material, and the fill skips a seed
# whose cell already matches. So a drag that repeats a cell can drop the repeat
# safely. The set holds distinct positions the cursor visited, including empty and
# out-of-model cells, so its size follows the stroke length, not the model volume.
var _queued_seeds := {}
var _fill_running := false
var _release_pending := false
var _fill_revision := 0
var _operation_id := 0
var _search_jobs: Array[FillJob] = []
# The expanded batch the main thread is partway through. The cursor owns the keys
# and the position into them, so a cancelled operation drops the rest. Only the
# current operation may clear it: a stale coroutine leaves a newer cursor alone.
var _batch_cursor := VoxelRegionSearch.BatchCursor.new()
# The cells the next slice applies. It follows the measured cost of the last slice.
var _slice_cells := 128
# The changed chunk ids the operation has not notified yet.
var _changed_chunks := {}
var _last_emit_frame := -1
var _last_emit_us := 0

## One cancellable fill job.
##
## The job searches a frame snapshot for the target material and applies the
## replacement. A streaming job pushes its found cells to [member batch_queue].
## [method VoxelFrame.EditJob.run] is the worker body.
class FillJob extends VoxelFrame.EditJob:
	## The frame snapshot to search and write.
	var source_frame: VoxelFrame
	## The cells that the fill may change. An empty mask allows every cell.
	var selection_mask: Dictionary = {}
	## The seed cell of a connected fill.
	var seed_cell := Vector3i.ZERO
	## The full material that the search matches.
	var target_material := VoxelFrame.material(Color.TRANSPARENT)
	## Whether the search floods the six face neighbors.
	var connected := true
	## The material that the fill writes to every match.
	var replacement_material := VoxelFrame.material(Color.TRANSPARENT)
	## The chunk locations that the fill changed.
	var changed_chunks: Array[Vector3i] = []
	## Whether the job applies the changes. A streaming job leaves this false.
	var apply_changes := true
	## The matched cells and their replacement material.
	var matching_cells := {}
	# A streaming job carries a bounded queue. The search pushes the cells it finds,
	# and the main thread applies them, so the fill is visible before the search ends.
	## The bounded handoff queue of a streaming job, or null.
	var batch_queue: VoxelRegionSearch.BatchQueue

	## Searches and applies the fill. This is the worker body.
	func run() -> void:
		stage("Finding connected voxels" if connected else "Finding matching voxels", -1 if connected else source_frame.count())
		# The shared search writes the replacement material straight into the change
		# map, so the result needs no second conversion pass.
		var changes := {}
		var stream: Callable = Callable(self, "_stream_batch") if batch_queue != null else Callable()
		if not VoxelRegionSearch.find(changes, source_frame, seed_cell, target_material, connected, replacement_material, selection_mask, self, stream):
			return
		matching_cells = changes
		if apply_changes:
			stage("Applying fill", changes.size())
			# The fill writes one replacement material to every matched cell, so the
			# batch is uniform. The hint lets a partial chunk write one shared row
			# instead of one row per cell.
			applied_uniform = replacement_material
			# An identity context writes exactly what `apply_cells` writes, minus the
			# redundant per-cell filter. The non-identity path keeps the base method.
			if _context_is_identity():
				applied_cells = changes
				if not checkpoint(0):
					return
				changed_chunks = source_frame.set_cells(applied_cells, self, applied_uniform)
			else:
				changed_chunks = apply_cells(source_frame, changes, true, target_material)

	# One batch of found cells, expanded by the captured edit context. The queue takes
	# ownership of the dictionary. A refused push cancels the job, because the
	# consumer stopped.
	func _stream_batch(cells: Array[Vector3i]) -> void:
		var expanded := {}
		for cell_position in cells:
			expanded[cell_position] = replacement_material
		expanded = _expand_fill_batch(expanded)
		if not batch_queue.push(expanded):
			cancel()

	# True when the edit context adds nothing to the search result. The shared search
	# proves every cell it returns is occupied and holds the full target material, so
	# with no symmetry axes and an empty selection `EditContext.expand` only rechecks
	# those same predicates for each cell. That recheck is redundant here.
	#
	# This guard is safe only for this caller. A non-empty selection keeps the
	# expansion, because the search adds its seed without a mask test and the context
	# must drop a seed that the selection excludes. A nonzero axes keeps it, because
	# each reflected cell must still be tested for occupancy and its full material. A
	# brush passes `existing_only` for cells that can be empty, so its filter is
	# load-bearing and must stay.
	func _context_is_identity() -> bool:
		return edit_context == null or (edit_context.axes == 0 and edit_context.selection.is_empty())

	# The expansion one batch needs. An identity context returns the batch unchanged,
	# so the queue still takes one owned dictionary and no cell is filtered.
	func _expand_fill_batch(changes: Dictionary) -> Dictionary:
		if _context_is_identity():
			return changes
		return edit_context.expand(changes, source_frame, true, target_material, self)


func _enter_tree() -> void:
	if not State.edit_context_changing.is_connected(_interrupt_fill):
		State.edit_context_changing.connect(_interrupt_fill)


func _exit_tree() -> void:
	_release_pending = true
	if not _fill_running:
		_finish_fill_stroke()
		State.edit_context_changing.disconnect(_interrupt_fill)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# A freed tool cannot finish its own edit, so release it here. Otherwise the
		# active edit outlives the tool and blocks every later edit.
		if _edit != null:
			State.cancel_edit(_edit)
			_edit = null
		for search_job in _search_jobs:
			search_job.cancel()
			if search_job.batch_queue != null:
				search_job.batch_queue.cancel()
			WorkerThreadPool.wait_for_task_completion(search_job.worker_task_id)
		if State.edit_context_changing.is_connected(_interrupt_fill):
			State.edit_context_changing.disconnect(_interrupt_fill)


## Handles one input event. A press fills the picked region. A drag queues one
## seed per visited cell. Escape cancels a running fill.
func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event is InputEventKey and event.is_action_pressed("ui_cancel") and _stroke_active:
		_interrupt_fill()
		return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _fill_running:
				return true
			var ray := _ray(pos)
			var pick := _pick_start(ray[0], ray[1])
			_plane = pick.plane
			_last_target = pick.target
			_release_pending = false
			_queue_seed(pick.hit)
			update_visual(pick)
		else:
			_release_pending = true
			if not _fill_running:
				_finish_fill_stroke()
		return true
	if event is InputEventMouseMotion and _stroke_active and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		var ray := _ray(pos)
		var pick := _pick_drag(ray[0], ray[1])
		if pick.target != VoxelPicking.NONE and pick.target != _last_target:
			for cell_position in StrokeLine.cells(_last_target, pick.target):
				if cell_position != _last_target:
					_enqueue_seed(cell_position)
			_last_target = pick.target
			if not _fill_running:
				_process_seeds()
		update_visual(pick)
		return true
	return super.handle_input(event, pos) if not _stroke_active else false


# Queue one stroke seed, once. A drag can pass the same cell more than once, and a
# repeated seed is a no-op, so the repeat is dropped here.
func _enqueue_seed(seed_cell: Vector3i) -> void:
	if _queued_seeds.has(seed_cell):
		return
	_queued_seeds[seed_cell] = true
	_pending_seeds.append(seed_cell)


func _queue_seed(seed_cell: Vector3i) -> void:
	if seed_cell == VoxelPicking.NONE or not State.can_edit(seed_cell) or not State.has_cell(seed_cell):
		return
	var frame := State.get_current_voxel_frame()
	var chunk: VoxelFrame.Chunk = frame.chunks.get(VoxelFrame.chunk_position(seed_cell))
	var replacement := _replacement_material if _stroke_active else State.current_material
	if chunk.matches(seed_cell, replacement):
		return
	if not _stroke_active:
		_edit = State.begin_edit()
		if _edit == null:
			return
		_stroke_active = true
		_source_document = State.document
		_source_frame = State.get_current_voxel_frame()
		_replacement_material = State.current_material.duplicate()
		# Capture the connected option with the material and the context, so every
		# seed this stroke queues keeps the setting it started with.
		_stroke_connected = _settings.connected
		_queued_seeds.clear()
		_changed_chunks.clear()
		_last_emit_frame = -1
		_last_emit_us = 0
		_fill_revision += 1
	_enqueue_seed(seed_cell)
	if not _fill_running:
		_process_seeds()


func _process_seeds() -> void:
	_fill_running = true
	var fill_revision := _fill_revision
	var operation_id := State.begin_operation("Filling", -1, true, self, _interrupt_fill)
	_operation_id = operation_id
	# Every seed of this frame shares one deadline, so a drag cannot chain completed
	# seeds without end in a single frame.
	var frame_deadline_us := Time.get_ticks_usec() + PUBLISH_BUDGET_US
	while not _pending_seeds.is_empty() and _fill_current(fill_revision):
		# A queue of seeds the fill skips still costs a scan each. The frame budget
		# covers that scan too, so one frame cannot walk a long skip queue.
		if Time.get_ticks_usec() >= frame_deadline_us:
			await State.get_tree().process_frame
			if not _fill_current(fill_revision):
				break
			frame_deadline_us = Time.get_ticks_usec() + PUBLISH_BUDGET_US
		var seed_cell: Vector3i = _pending_seeds.pop_front()
		if not _source_frame.has(seed_cell) or not State.can_edit(seed_cell):
			continue
		var chunk: VoxelFrame.Chunk = _source_frame.chunks.get(VoxelFrame.chunk_position(seed_cell))
		if chunk.matches(seed_cell, _replacement_material):
			continue
		var search_job := FillJob.new()
		search_job.source_frame = _source_frame.copy_frame()
		search_job.edit_context = _edit.edit_context
		search_job.selection_mask = State.selection.capture()
		search_job.seed_cell = seed_cell
		search_job.target_material = _source_frame.get_material(seed_cell)
		search_job.connected = _stroke_connected
		search_job.replacement_material = _replacement_material
		if search_job.estimate_work(search_job.source_frame.count()) <= 4096:
			# A small fill stays one step, so it lands at once.
			search_job.run()
			if not _fill_current(fill_revision):
				break
			_source_frame.restore(search_job.source_frame.capture())
			_mark_changed(search_job.changed_chunks)
			_flush_chunk_notifications(fill_revision, false)
			if Time.get_ticks_usec() >= frame_deadline_us:
				await State.get_tree().process_frame
				if not _fill_current(fill_revision):
					break
				frame_deadline_us = Time.get_ticks_usec() + PUBLISH_BUDGET_US
		else:
			# A large fill streams its cells. The main thread applies them in bounded
			# slices, so the fill grows while the search still runs.
			search_job.batch_queue = VoxelRegionSearch.BatchQueue.new()
			search_job.apply_changes = false
			_batch_cursor = VoxelRegionSearch.BatchCursor.new(search_job.batch_queue)
			search_job.worker_task_id = WorkerThreadPool.add_task(search_job.run, true, "Fill edit")
			_search_jobs.append(search_job)
			# Apply every batch the worker produces, in slices under the frame budget.
			# The loop only ends when the worker is done and its queue and pending
			# slice are empty, so no found cell is dropped.
			while true:
				if not _fill_current(fill_revision):
					break
				var done := WorkerThreadPool.is_task_completed(search_job.worker_task_id)
				_drain_fill_batches(search_job, fill_revision, frame_deadline_us)
				# A notification the drain emitted can cancel this fill or start a new
				# one. Recheck before this coroutine reads the shared cursor again.
				if not _fill_current(fill_revision):
					break
				if done and _batch_cursor.is_done():
					break
				var progress := search_job.progress()
				# The worker counts found cells, not applied cells, so the overall
				# fill has no reliable total. Report unknown until it finishes.
				State.update_operation(operation_id, progress[1], -1, progress[0])
				await State.get_tree().process_frame
				frame_deadline_us = Time.get_ticks_usec() + PUBLISH_BUDGET_US
			# Cancel the queue before the wait, so a producer that is blocked on a full
			# queue can always finish. This handle is this coroutine's own, so it is
			# reaped here exactly once and the newer job is left alone.
			search_job.batch_queue.cancel()
			WorkerThreadPool.wait_for_task_completion(search_job.worker_task_id)
			_search_jobs.erase(search_job)
			# The pending slice belongs to the current operation. A stale coroutine
			# must not clear it, because a newer fill may own it now. The cursor is
			# dropped, so its queue reference is released after the join above. The
			# job still held the queue for the cancel before that join.
			if fill_revision == _fill_revision:
				_batch_cursor = VoxelRegionSearch.BatchCursor.new()
	# The final state always reaches the renderer, even when the cadence held the
	# last batches back. A stale coroutine is refused inside the flush.
	_flush_chunk_notifications(fill_revision, true)
	# Only this coroutine's own operation id, never the current one.
	State.finish_operation(operation_id)
	if fill_revision == _fill_revision:
		_fill_running = false
		_operation_id = 0
		if _release_pending:
			_finish_fill_stroke()
	# The current fill state, not this coroutine's: a newer running fill keeps the
	# connection, so a stale coroutine cannot disconnect it.
	if not is_inside_tree() and not _fill_running and State.edit_context_changing.is_connected(_interrupt_fill):
		State.edit_context_changing.disconnect(_interrupt_fill)


# Apply the pending batch in bounded slices, then take the next batch, until the
# frame deadline or the queue runs out. A slice keeps one set_cells call short, and
# the cursor keeps the rest for the next frame, so no destination is dropped. A
# stale context drops the work. The changed chunk ids coalesce for one notification.
func _drain_fill_batches(search_job: FillJob, fill_revision: int, deadline_us: int) -> void:
	while Time.get_ticks_usec() < deadline_us:
		var end := _batch_cursor.next_end(_slice_cells)
		if end < 0:
			break
		if not _fill_current(fill_revision):
			break
		var start := _batch_cursor.cursor
		var keys: Array = _batch_cursor.keys
		var slice := {}
		for index in range(start, end):
			slice[keys[index]] = search_job.replacement_material
		var slice_started_us := Time.get_ticks_usec()
		_mark_changed(_source_frame.set_cells(slice, null, search_job.replacement_material))
		_batch_cursor.cursor = end
		_retune_slice(end - start, Time.get_ticks_usec() - slice_started_us)
	_flush_chunk_notifications(fill_revision, false)


# Size the next slice from the measured cost of the last one, so one set_cells call
# aims at the frame budget. A fast machine grows the slice and a slow one shrinks
# it. The slice never drops below the minimum, so the work still advances.
func _retune_slice(applied: int, slice_us: int) -> void:
	if applied <= 0 or slice_us <= 0:
		return
	var per_cell_us := float(slice_us) / float(applied)
	_slice_cells = clampi(int(float(PUBLISH_BUDGET_US) / per_cell_us), APPLY_SLICE_MIN, APPLY_SLICE_MAX)


# Remember the changed chunks for the next notification. The set drops duplicates,
# because a chunk can change in several slices and frames.
func _mark_changed(chunks: Array[Vector3i]) -> void:
	if chunks.is_empty():
		return
	_source_document._bounds_dirty = true
	for chunk_location in chunks:
		_changed_chunks[chunk_location] = true


# Send the coalesced chunk ids when the cadence allows it, or when the caller forces
# the flush at the end. The first notification of an operation leaves at once. A
# stale revision belongs to a cancelled operation, so it must not emit: the coalesced
# ids and the source frame may already describe a newer operation.
func _flush_chunk_notifications(fill_revision: int, force: bool) -> void:
	if fill_revision != _fill_revision:
		return
	if _changed_chunks.is_empty():
		return
	if _source_frame == null or _source_document == null:
		_changed_chunks.clear()
		return
	if not force and _last_emit_frame >= 0:
		var now := Time.get_ticks_usec()
		if Engine.get_process_frames() - _last_emit_frame < NOTIFY_MIN_FRAMES and now - _last_emit_us < NOTIFY_MIN_INTERVAL_US:
			return
	_emit_chunk_notifications()


func _emit_chunk_notifications() -> void:
	var changed: Array[Vector3i] = []
	changed.assign(_changed_chunks.keys())
	_changed_chunks.clear()
	_last_emit_us = Time.get_ticks_usec()
	_last_emit_frame = Engine.get_process_frames()
	State.chunks_changed.emit(_source_document.frames.find(_source_frame), changed)


func _fill_current(fill_revision: int) -> bool:
	return fill_revision == _fill_revision and _source_document == State.document and _source_frame != null and _source_frame == State.get_current_voxel_frame()


func _finish_fill_stroke() -> void:
	if not _stroke_active:
		return
	# Clear the fill state before the close signals, so a handler that opens a new
	# stroke keeps its own captured state.
	_source_document = null
	_source_frame = null
	_queued_seeds.clear()
	_changed_chunks.clear()
	# Drop the cursor so its queue reference is released with the stroke.
	_batch_cursor = VoxelRegionSearch.BatchCursor.new()
	_end()


func _interrupt_fill() -> void:
	_fill_revision += 1
	for search_job in _search_jobs:
		search_job.cancel()
		if search_job.batch_queue != null:
			search_job.batch_queue.cancel()
	_pending_seeds.clear()
	_queued_seeds.clear()
	# The cancel restores the frame, so the pending slice and the coalesced chunk
	# ids describe a frame that no longer exists and are dropped with the seeds.
	# The job still holds its queue for the cancel, so dropping the cursor here only
	# releases this tool's reference to it.
	_batch_cursor = VoxelRegionSearch.BatchCursor.new()
	_changed_chunks.clear()
	# Clear the fill state before the cancel signals, so a handler that opens a new
	# stroke keeps its own captured state.
	_fill_running = false
	_source_document = null
	_source_frame = null
	_stroke_active = false
	_plane = null
	_last_target = VoxelPicking.NONE
	# Capture the operation before the signals, so the cleanup finishes only this
	# operation, never a replacement one a handler started.
	var operation_id := _operation_id
	_operation_id = 0
	abort_stroke()
	State.finish_operation(operation_id)


## Returns [code]true[/code] when no fill runs.
func is_settled() -> bool:
	return not _fill_running
