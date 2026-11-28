extends VoxelTool


const PUBLISH_BUDGET_US := 2000
const APPLY_SLICE_MIN := 64
const APPLY_SLICE_MAX := 512
const NOTIFY_MIN_FRAMES := 3
const NOTIFY_MIN_INTERVAL_US := 20000

var _settings := preload("./PaintSettings.tres")
var _source_document: VoxelDocument
var _source_frame: VoxelFrame
var _replacement_material := VoxelFrame.material(Color.TRANSPARENT)
var _stroke_connected := true
var _pending_seeds: Array[Vector3i] = []
var _queued_seeds := {}
var _fill_running := false
var _release_pending := false
var _fill_revision := 0
var _operation_id := 0
var _search_jobs: Array[FillJob] = []
var _batch_cursor := VoxelRegionSearch.BatchCursor.new()
var _slice_cells := 128
var _changed_chunks := {}
var _last_emit_frame := -1
var _last_emit_us := 0

class FillJob extends VoxelFrame.EditJob:
	var source_frame: VoxelFrame
	var selection_mask: Dictionary = {}
	var seed_cell := Vector3i.ZERO
	var target_material := VoxelFrame.material(Color.TRANSPARENT)
	var connected := true
	var replacement_material := VoxelFrame.material(Color.TRANSPARENT)
	var changed_chunks: Array[Vector3i] = []
	var apply_changes := true
	var matching_cells := {}
	var batch_queue: VoxelRegionSearch.BatchQueue

	func run() -> void:
		stage("Finding connected voxels" if connected else "Finding matching voxels", -1 if connected else source_frame.count())
		var changes := {}
		var stream: Callable = Callable(self, "_stream_batch") if batch_queue != null else Callable()
		var slice_axis := edit_context.slice_axis if edit_context else -1
		var slice_index := edit_context.slice_index if edit_context else 0
		var slice_count := edit_context.slice_count if edit_context else 1
		if not VoxelRegionSearch.find(changes, source_frame, seed_cell, target_material, connected, replacement_material, selection_mask, self, stream, slice_axis, slice_index, slice_count):
			return
		matching_cells = changes
		if apply_changes:
			stage("Applying fill", changes.size())
			applied_uniform = replacement_material
			if _context_is_identity():
				applied_cells = changes
				if not checkpoint(0):
					return
				changed_chunks = source_frame.set_cells(applied_cells, self, applied_uniform)
			else:
				changed_chunks = apply_cells(source_frame, changes, true, target_material)

	func _stream_batch(cells: Array[Vector3i]) -> void:
		var expanded := {}
		for cell_position in cells:
			expanded[cell_position] = replacement_material
		expanded = _expand_fill_batch(expanded)
		if not batch_queue.push(expanded):
			cancel()

	func _context_is_identity() -> bool:
		return edit_context == null or (edit_context.axes == 0 and edit_context.selection.is_empty())

	func _expand_fill_batch(changes: Dictionary) -> Dictionary:
		if _context_is_identity():
			return changes
		return edit_context.expand(changes, source_frame, true, target_material, self)


func _enter_tree() -> void:
	if not State.edit_context_changing.is_connected(_interrupt_fill):
		State.edit_context_changing.connect(_interrupt_fill)


func _exit_tree() -> void:
	finish_on_switch()
	if not _fill_running and State.edit_context_changing.is_connected(_interrupt_fill):
		State.edit_context_changing.disconnect(_interrupt_fill)


func finish_on_switch() -> void:
	_release_pending = true
	if not _fill_running:
		_finish_fill_stroke()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		abort_stroke()
		var operation_id := _operation_id
		_operation_id = 0
		State.finish_operation(operation_id)
		for search_job in _search_jobs:
			search_job.cancel()
			if search_job.batch_queue != null:
				search_job.batch_queue.cancel()
			WorkerThreadPool.wait_for_task_completion(search_job.worker_task_id)
		if State.edit_context_changing.is_connected(_interrupt_fill):
			State.edit_context_changing.disconnect(_interrupt_fill)


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
	if event is InputEventMouseMotion and _stroke_active and event.button_mask == 0:
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
		if open_stroke() == null:
			return
		_stroke_active = true
		_source_document = State.document
		_source_frame = State.get_current_voxel_frame()
		_replacement_material = State.current_material.duplicate()
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
	var frame_deadline_us := Time.get_ticks_usec() + PUBLISH_BUDGET_US
	while not _pending_seeds.is_empty() and _fill_current(fill_revision):
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
			search_job.run()
			if not _fill_current(fill_revision):
				break
			_source_frame.apply_published(search_job.changed_chunks, search_job.source_frame)
			_mark_changed(search_job.changed_chunks)
			_flush_chunk_notifications(fill_revision, false)
			if Time.get_ticks_usec() >= frame_deadline_us:
				await State.get_tree().process_frame
				if not _fill_current(fill_revision):
					break
				frame_deadline_us = Time.get_ticks_usec() + PUBLISH_BUDGET_US
		else:
			search_job.batch_queue = VoxelRegionSearch.BatchQueue.new()
			search_job.apply_changes = false
			_batch_cursor = VoxelRegionSearch.BatchCursor.new(search_job.batch_queue)
			search_job.worker_task_id = WorkerThreadPool.add_task(search_job.run, true, "Fill edit")
			_search_jobs.append(search_job)
			while true:
				if not _fill_current(fill_revision):
					break
				var done := WorkerThreadPool.is_task_completed(search_job.worker_task_id)
				_drain_fill_batches(search_job, fill_revision, frame_deadline_us)
				if not _fill_current(fill_revision):
					break
				if done and _batch_cursor.is_done():
					break
				var progress := search_job.progress()
				State.update_operation(operation_id, progress[1], -1, progress[0])
				await State.get_tree().process_frame
				frame_deadline_us = Time.get_ticks_usec() + PUBLISH_BUDGET_US
			search_job.batch_queue.cancel()
			WorkerThreadPool.wait_for_task_completion(search_job.worker_task_id)
			_search_jobs.erase(search_job)
			if fill_revision == _fill_revision:
				_batch_cursor = VoxelRegionSearch.BatchCursor.new()
	_flush_chunk_notifications(fill_revision, true)
	State.finish_operation(operation_id)
	if fill_revision == _fill_revision:
		_fill_running = false
		_operation_id = 0
		if _release_pending:
			_finish_fill_stroke()
	if not is_inside_tree() and not _fill_running and State.edit_context_changing.is_connected(_interrupt_fill):
		State.edit_context_changing.disconnect(_interrupt_fill)


func _drain_fill_batches(search_job: FillJob, fill_revision: int, deadline_us: int) -> void:
	var slice_apply := _apply_fill_slice.bind(search_job, fill_revision)
	while Time.get_ticks_usec() < deadline_us:
		if not _batch_cursor.apply_slice(_slice_cells, slice_apply):
			break
	_flush_chunk_notifications(fill_revision, false)


func _apply_fill_slice(keys: Array, start: int, end: int, search_job: FillJob, fill_revision: int) -> bool:
	if not _fill_current(fill_revision):
		return false
	var slice := {}
	for index in range(start, end):
		slice[keys[index]] = search_job.replacement_material
	var slice_started_us := Time.get_ticks_usec()
	_mark_changed(_source_frame.set_cells(slice, search_job, search_job.replacement_material))
	_retune_slice(end - start, Time.get_ticks_usec() - slice_started_us)
	return true


func _retune_slice(applied: int, slice_us: int) -> void:
	if applied <= 0 or slice_us <= 0:
		return
	var per_cell_us := float(slice_us) / float(applied)
	_slice_cells = clampi(int(float(PUBLISH_BUDGET_US) / per_cell_us), APPLY_SLICE_MIN, APPLY_SLICE_MAX)


func _mark_changed(chunks: Array[Vector3i]) -> void:
	if chunks.is_empty():
		return
	_source_document._bounds_dirty = true
	for chunk_location in chunks:
		_changed_chunks[chunk_location] = true


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
	var location := _source_document.find_cel(_source_frame)
	if location.x >= 0:
		State.chunks_changed.emit(location.y, changed)


func _fill_current(fill_revision: int) -> bool:
	return fill_revision == _fill_revision and _source_document == State.document and _source_frame != null and _source_frame == State.get_current_voxel_frame()


func _finish_fill_stroke() -> void:
	if not _stroke_active:
		return
	_source_document = null
	_source_frame = null
	_queued_seeds.clear()
	_changed_chunks.clear()
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
	_batch_cursor = VoxelRegionSearch.BatchCursor.new()
	_changed_chunks.clear()
	_fill_running = false
	_source_document = null
	_source_frame = null
	_stroke_active = false
	_plane = null
	_last_target = VoxelPicking.NONE
	var operation_id := _operation_id
	_operation_id = 0
	abort_stroke()
	State.finish_operation(operation_id)


func is_settled() -> bool:
	return not _fill_running


func driver_fill(seed_cell: Vector3i) -> Error:
	if driver_is_busy():
		return ERR_BUSY
	if not State.has_cell(seed_cell):
		return ERR_INVALID_DATA
	_release_pending = true
	_queue_seed(seed_cell)
	if _edit == null and not _fill_running:
		_release_pending = false
	return OK


func driver_is_busy() -> bool:
	return _fill_running or _edit != null
