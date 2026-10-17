extends VoxelTool

var _settings := preload("./settings.tres")
var _source_document: VoxelDocument
var _source_frame: VoxelFrame
var _replacement_material := VoxelFrame.material(Color.TRANSPARENT)
var _pending_seeds: Array[Vector3i] = []
var _fill_running := false
var _release_pending := false
var _fill_revision := 0
var _operation_id := 0
var _search_jobs: Array[FillJob] = []

class FillJob extends VoxelFrame.EditJob:
	var source_frame: VoxelFrame
	var selection_mask: Dictionary = {}
	var seed_cell := Vector3i.ZERO
	var target_color := Color.TRANSPARENT
	var connected := true
	var replacement_material := VoxelFrame.material(Color.TRANSPARENT)
	var changed_chunks: Array[Vector3i] = []
	var apply_changes := true
	var matching_cells := {}

	func run() -> void:
		var replacement := replacement_material
		var changes := {}
		if not connected:
			stage("Finding matching voxels", source_frame.count())
			var examined := 0
			for chunk in source_frame.chunks.values():
				for cell_position in chunk.cells:
					if chunk.get_color(cell_position) == target_color and (selection_mask.is_empty() or selection_mask.has(cell_position)):
						changes[cell_position] = replacement
					examined += 1
					if examined % 4096 == 0 and not checkpoint(examined):
						return
		else:
			stage("Finding connected voxels", -1)
			var pending: Array[Vector3i] = [seed_cell]
			changes[seed_cell] = replacement
			var examined := 0
			while not pending.is_empty():
				var cell_position: Vector3i = pending.pop_back()
				for direction in VoxelFrame.DIRECTIONS:
					var neighbor: Vector3i = cell_position + direction
					if changes.has(neighbor) or (not selection_mask.is_empty() and not selection_mask.has(neighbor)):
						continue
					if source_frame.get_color(neighbor) == target_color:
						changes[neighbor] = replacement
						pending.append(neighbor)
				examined += 1
				if examined % 4096 == 0 and not checkpoint(changes.size()):
					return
		matching_cells = changes
		if apply_changes:
			stage("Applying fill", changes.size())
			changed_chunks = apply_cells(source_frame, changes, true, target_color)


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
		for search_job in _search_jobs:
			search_job.cancel()
			WorkerThreadPool.wait_for_task_completion(search_job.worker_task_id)


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
					_pending_seeds.append(cell_position)
			_last_target = pick.target
			if not _fill_running:
				_process_seeds()
		update_visual(pick)
		return true
	return super.handle_input(event, pos) if not _stroke_active else false


func _queue_seed(seed_cell: Vector3i) -> void:
	if seed_cell == VoxelPicking.NONE or not State.can_edit(seed_cell) or not State.has_cell(seed_cell):
		return
	var frame := State.get_current_voxel_frame()
	var chunk: VoxelFrame.Chunk = frame.chunks.get(VoxelFrame.chunk_position(seed_cell))
	var replacement := _replacement_material if _stroke_active else State.current_material
	if chunk.matches(seed_cell, replacement):
		return
	if not _stroke_active:
		begin_stroke()
		_stroke_active = true
		_source_document = State.document
		_source_frame = State.get_current_voxel_frame()
		_replacement_material = State.current_material.duplicate()
		_fill_revision += 1
	_pending_seeds.append(seed_cell)
	if not _fill_running:
		_process_seeds()


func _process_seeds() -> void:
	_fill_running = true
	var fill_revision := _fill_revision
	var operation_id := State.begin_operation("Finding matching voxels", -1, true, self)
	_operation_id = operation_id
	while not _pending_seeds.is_empty() and _fill_current(fill_revision):
		var seed_cell: Vector3i = _pending_seeds.pop_front()
		if not _source_frame.has(seed_cell) or not State.can_edit(seed_cell):
			continue
		var chunk: VoxelFrame.Chunk = _source_frame.chunks.get(VoxelFrame.chunk_position(seed_cell))
		if chunk.matches(seed_cell, _replacement_material):
			continue
		var search_job := FillJob.new()
		search_job.source_frame = _source_frame.copy_frame()
		search_job.edit_context = State.drawing_context()
		search_job.selection_mask = State.selection.capture()
		search_job.seed_cell = seed_cell
		search_job.target_color = _source_frame.get_color(seed_cell)
		search_job.connected = _settings.connected
		search_job.replacement_material = _replacement_material
		if search_job.estimate_work(search_job.source_frame.count()) <= 4096:
			search_job.run()
		else:
			search_job.worker_task_id = WorkerThreadPool.add_task(search_job.run, true, "Fill edit")
			_search_jobs.append(search_job)
			while not WorkerThreadPool.is_task_completed(search_job.worker_task_id):
				var progress := search_job.progress()
				State.update_operation(operation_id, progress[1], progress[2], progress[0], "%d voxels found" % progress[1] if progress[2] < 0 else "")
				await State.get_tree().process_frame
			WorkerThreadPool.wait_for_task_completion(search_job.worker_task_id)
			_search_jobs.erase(search_job)
		if not _fill_current(fill_revision):
			break
		_source_frame.restore(search_job.source_frame.capture())
		if not search_job.changed_chunks.is_empty():
			_source_document._bounds_dirty = true
			State.chunks_changed.emit(_source_document.frames.find(_source_frame), search_job.changed_chunks)
	State.finish_operation(operation_id)
	if fill_revision == _fill_revision:
		_fill_running = false
		_operation_id = 0
		if _release_pending:
			_finish_fill_stroke()
	if not is_inside_tree() and not _fill_running and State.edit_context_changing.is_connected(_interrupt_fill):
		State.edit_context_changing.disconnect(_interrupt_fill)


func _fill_current(fill_revision: int) -> bool:
	return fill_revision == _fill_revision and _source_document == State.document and _source_frame != null and _source_frame == State.get_current_voxel_frame()


func _finish_fill_stroke() -> void:
	if not _stroke_active:
		return
	_end()
	_source_document = null
	_source_frame = null


func _interrupt_fill() -> void:
	_fill_revision += 1
	for search_job in _search_jobs:
		search_job.cancel()
	_pending_seeds.clear()
	if _stroke_active:
		cancel_stroke()
		_stroke_active = false
		_plane = null
		_last_target = VoxelPicking.NONE
	_fill_running = false
	_source_document = null
	_source_frame = null
	State.finish_operation(_operation_id)
	_operation_id = 0


func is_settled() -> bool:
	return not _fill_running

