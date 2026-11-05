extends "./SelectTool.gd"

## The wand selection tool.
##
## A click selects the connected region of the picked material. A large
## selection streams its cells, and the live selection grows while the search
## runs. One open stroke holds the whole change for a single undo action.

# The main-thread work one frame spends merging streamed selection batches. The
# worker waits when the queue fills, so the budget bounds both the merge cost and
# the handoff memory. The budget covers only the merge. The publication that
# follows it copies the selection once for the preview, and that copy is outside
# the budget, so the budget is not a hard frame-cost claim.
## The main-thread merge budget per frame in microseconds.
const PUBLISH_BUDGET_US := 2000
# One merge step. A batch expanded by symmetry can hold thousands of cells, so it
# is applied in slices that each recheck the budget.
## The cell count of one merge slice.
const MERGE_SLICE := 256

var _source_document: VoxelDocument
var _source_frame: VoxelFrame
var _job: WandJob
# Cancelled jobs whose worker is still winding down. Each one is joined exactly
# once, so no pool task is left behind when a cancel or a tool switch retires it.
var _retired_jobs: Array[WandJob] = []
var _reaping := false
var _operation_id := 0

## One cancellable wand selection job.
##
## The job searches a frame snapshot for the target material. A streaming job
## pushes its found cells to [member batch_queue]. [method
## VoxelFrame.EditJob.run] is the worker body.
class WandJob extends VoxelFrame.EditJob:
	## The frame snapshot to search.
	var source_frame: VoxelFrame
	## The picked seed cell.
	var seed_cell := Vector3i.ZERO
	## The full material that the search matches.
	var target_material := VoxelFrame.material(Color.TRANSPARENT)
	## Whether the search floods the six face neighbors.
	var connected := true
	## The selection before this operation.
	var previous_selection := {}
	## The selection mode.
	var mode := 0
	## The result selection, keyed by cell position.
	var result := {}
	## The matched cells.
	var matching_cells := {}
	# A streaming job carries a bounded queue. The search pushes the cells it finds,
	# and the main thread grows the live selection, so the selection and its outline
	# are visible before the search ends.
	## The bounded handoff queue of a streaming job, or null.
	var batch_queue: VoxelRegionSearch.BatchQueue
	# The consumer merges one large expanded batch in small slices, so the frame
	# budget is respected inside a batch. The cursor owns the batch keys and the
	# position into them.
	## The consumer cursor over [member batch_queue].
	var batch_cursor: VoxelRegionSearch.BatchCursor

	## Searches and builds the result selection. This is the worker body.
	func run() -> void:
		stage("Finding connected voxels" if connected else "Finding matching voxels", -1 if connected else source_frame.count())
		# The wand ignores the current selection as a barrier, so it passes no mask.
		# The floor slice still bounds the flood, so a selection stays on the layer.
		var stream: Callable = Callable(self, "_stream_batch") if batch_queue != null else Callable()
		var slice_axis := edit_context.slice_axis if edit_context else -1
		var slice_index := edit_context.slice_index if edit_context else 0
		matching_cells = {}
		if not VoxelRegionSearch.find(matching_cells, source_frame, seed_cell, target_material, connected, true, {}, self, stream, slice_axis, slice_index):
			return
		if not checkpoint(0):
			return
		if edit_context:
			matching_cells = edit_context.expand(matching_cells, source_frame, false, null, self)
		if not checkpoint(0):
			return
		stage("Applying selection mode", matching_cells.size())
		result = {} if mode == 0 else previous_selection.duplicate()
		var completed := 0
		for cell_position in matching_cells:
			if mode == 2:
				result.erase(cell_position)
			else:
				result[cell_position] = true
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return

	# One batch of raw matches, expanded by the captured edit context. The queue
	# takes ownership. A refused push cancels the job, because the consumer stopped.
	func _stream_batch(cells: Array[Vector3i]) -> void:
		var expanded := {}
		for cell_position in cells:
			expanded[cell_position] = true
		if edit_context:
			expanded = edit_context.expand(expanded, source_frame, false, null, self)
		if not batch_queue.push(expanded):
			cancel()


func _enter_tree() -> void:
	# A tool switch re-enters this node, so the connection is added once.
	if not State.edit_context_changing.is_connected(_cancel_selection):
		State.edit_context_changing.connect(_cancel_selection)


# A tool switch detaches this node but does not destroy it. The running selection
# keeps its captured settings, and the service loop below is not tied to
# `_process`, so the operation finishes and publishes after a switch. The context
# connection stays live, because a frame or document change must still cancel.
func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# This node cannot await after it is destroyed, so the rollback and every join
	# run here. The reaper is not started, because its await could resume on a
	# freed node. A destroyed tool rolls back its own stroke only.
	var live := _job
	_job = null
	var tx := _edit
	_edit = null
	_source_document = null
	_source_frame = null
	if tx != null:
		State.cancel_edit(tx)
	State.finish_operation(_operation_id)
	_operation_id = 0
	var joins: Array[WandJob] = _retired_jobs.duplicate()
	_retired_jobs.clear()
	if live != null:
		joins.append(live)
	for job in joins:
		job.cancel()
		if job.batch_queue != null:
			job.batch_queue.cancel()
	# This is the one place a join may block. The cancelled queue lets the worker
	# finish, so the wait is bounded.
	for job in joins:
		if job.worker_task_id != -1:
			WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
	if State.edit_context_changing.is_connected(_cancel_selection):
		State.edit_context_changing.disconnect(_cancel_selection)


## Handles one input event. A left press selects the picked region. Escape
## cancels a running selection.
func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event.is_action_pressed("ui_cancel") and _job:
		_cancel_selection()
		return true
	if event is InputEventMouseButton:
		if event.button_index != MOUSE_BUTTON_LEFT:
			return false
		if event.pressed and _job == null:
			var ray := _ray(pos)
			_commit(_pick_start(ray[0], ray[1]).hit)
		return true
	if event is InputEventMouseMotion and event.button_mask == 0:
		var ray := _ray(pos)
		update_visual(_pick_start(ray[0], ray[1]))
		return true
	return false


func _commit(seed_cell: Vector3i) -> void:
	if _job or State.edit_busy() or seed_cell == VoxelPicking.NONE or not State.has_cell(seed_cell):
		return
	_source_document = State.document
	_source_frame = State.get_current_voxel_frame()
	_job = WandJob.new()
	_job.source_frame = _source_frame.copy_frame()
	_job.edit_context = State.selection_context()
	_job.seed_cell = seed_cell
	_job.target_material = _source_frame.get_material(seed_cell)
	_job.connected = _settings.connected
	_job.previous_selection = State.selection.capture()
	_job.mode = _settings.mode
	var work := _job.estimate_work(_source_frame.count() + State.selection.count())
	if work <= 4096:
		# A small selection stays one step, so it lands at once.
		_job.run()
		_finish_selection()
		return
	# A large selection streams its cells. The live selection grows while the search
	# runs, and one open stroke holds the whole change for a single undo action.
	_job.batch_queue = VoxelRegionSearch.BatchQueue.new()
	_job.batch_cursor = VoxelRegionSearch.BatchCursor.new(_job.batch_queue)
	_edit = State.begin_edit()
	if _edit == null:
		_job = null
		_source_document = null
		_source_frame = null
		return
	_operation_id = State.begin_operation("Selecting", work, true, self, _cancel_selection)
	# Start from the mode's own baseline, so a replace drops the previous selection
	# instead of keeping it until the final result lands. Add and subtract keep it.
	if _job.mode == 0:
		State.selection.clear()
	_publish_selection()
	_job.worker_task_id = WorkerThreadPool.add_task(_job.run, true, "Wand selection")
	_service_selection()


# Service the streamed selection. This is a coroutine on the tool, not `_process`,
# so a tool switch that detaches the node cannot stall the operation.
func _service_selection() -> void:
	var job := _job
	# Apply every batch the worker produces, with the per-frame budget. The loop only
	# ends when the worker is done and its queue is empty, so no found cell is lost.
	while job != null and _selection_current(job):
		var done := WorkerThreadPool.is_task_completed(job.worker_task_id)
		_drain_selection_batches(job)
		if done and job.batch_cursor.is_done():
			break
		var progress := job.progress()
		# The worker counts found cells, not applied cells, so the overall
		# selection has no reliable total. Report unknown until it finishes.
		State.update_operation(_operation_id, progress[1], -1, progress[0])
		await State.get_tree().process_frame
	if job == null or not _selection_current(job):
		# The cancel path retired this job, and the reaper joins its worker.
		return
	# Cancel the queue before the wait, so a producer that is blocked on a full queue
	# can always finish.
	job.batch_queue.cancel()
	WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
	_finish_selection()


# Apply the batches the worker already found. The work stops at the frame budget,
# and one batch is merged in small slices, so an expanded symmetry batch that can
# hold thousands of cells cannot overrun the frame. A stale context drops the
# batches. One pass runs per frame, and the progressive outline path coalesces the
# snapshots it publishes.
func _drain_selection_batches(job: WandJob) -> void:
	var changed := false
	var started_us := Time.get_ticks_usec()
	var cursor := job.batch_cursor
	var slice_apply := _apply_selection_slice.bind(job)
	while cursor.apply_slice(MERGE_SLICE, slice_apply):
		changed = true
		if not _selection_current(job):
			return
		if Time.get_ticks_usec() - started_us >= PUBLISH_BUDGET_US:
			break
	if changed:
		_publish_selection()


# Merge one slice into the live selection. A stale context refuses the slice before
# it changes the selection, so the cursor keeps it for the next owner.
func _apply_selection_slice(keys: Array, start: int, end: int, job: WandJob) -> bool:
	if not _selection_current(job):
		return false
	for index in range(start, end):
		var cell_position: Vector3i = keys[index]
		if job.mode == 2:
			State.selection.erase(cell_position)
		else:
			State.selection.add(cell_position)
	return true


# Tell the views that the live selection changed. The drain runs once per frame, so
# a merge publishes at most once per frame. The progressive outline path coalesces
# those snapshots, so a publish never cancels the outline that is already building.
func _publish_selection() -> void:
	State.selection_changed.emit()


func _selection_current(job: WandJob) -> bool:
	return _job == job and State.document == _source_document and State.get_current_voxel_frame() == _source_frame


# True while a streamed selection owns an open stroke. The preview uses this to
# choose its progressive outline path. A small selection lands at once, so it
# never reports a stream.
## Returns [code]true[/code] while a streamed selection owns an open stroke. The
## preview uses this to choose its progressive outline path.
func is_streaming() -> bool:
	return _job != null and _edit != null


# Keep a cancelled job until its worker finishes, then join it once. The reaper
# awaits frames, so the main thread never blocks on an unfinished task.
func _retire_job(job: WandJob) -> void:
	job.cancel()
	if job.batch_queue != null:
		job.batch_queue.cancel()
	_retired_jobs.append(job)
	_reap_retired_jobs()


func _reap_retired_jobs() -> void:
	if _reaping:
		return
	_reaping = true
	while not _retired_jobs.is_empty():
		var job := _retired_jobs[0]
		if job.worker_task_id != -1:
			while not WorkerThreadPool.is_task_completed(job.worker_task_id):
				await State.get_tree().process_frame
			WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
		_retired_jobs.pop_front()
	_reaping = false


func _finish_selection() -> void:
	var job := _job
	_job = null
	if job == null:
		return
	var committed := job.checkpoint(0) and State.document == _source_document and State.get_current_voxel_frame() == _source_frame
	# Capture the handle, the operation, and the source before the history and
	# selection signals. A handler that starts a new selection on this tool keeps
	# its own, so this cleanup must consume only the captured state.
	var tx := _edit
	_edit = null
	var operation_id := _operation_id
	_operation_id = 0
	_source_document = null
	_source_frame = null
	if committed:
		if tx == null:
			tx = State.begin_edit()
		if tx != null:
			State.selection.restore(job.result)
			State.finish_edit(tx, "Wand selection")
			_publish_selection()
	elif tx != null:
		# A stale result never stays, so release the handle the tool still owns.
		State.cancel_edit(tx)
	State.finish_operation(operation_id)


# A cancel request or a context change. Only the stroke this tool opened is rolled
# back, so an idle wand never disturbs an edit that another tool owns.
func _cancel_selection() -> void:
	var job := _job
	if job == null and _edit == null:
		return
	_job = null
	if job:
		_retire_job(job)
	# Clear the stream state before the cancel signals, so a handler that opens a
	# new selection keeps its own captured state. A streamed selection already
	# changed the live selection, so the restore puts the frame and the selection
	# back. A partial result never stays.
	var tx := _edit
	_edit = null
	_source_document = null
	_source_frame = null
	# Capture the operation before the signals, so the cleanup finishes only this
	# operation, never a replacement one a handler started.
	var operation_id := _operation_id
	_operation_id = 0
	if tx != null:
		State.cancel_edit(tx)
		_publish_selection()
	State.finish_operation(operation_id)
