extends "./SelectTool.gd"

const FillTool := preload("res://plugins/Fill/FillTool.gd")

var _source_document: VoxelDocument
var _source_frame: VoxelFrame
var _job: WandJob
var _operation_id := 0

class WandJob extends FillTool.FillJob:
	var previous_selection := {}
	var mode := 0
	var result := {}

	func run() -> void:
		apply_changes = false
		super.run()
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


func _enter_tree() -> void:
	State.edit_context_changing.connect(_cancel_selection)


func _exit_tree() -> void:
	_cancel_selection()
	if _job and _job.worker_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_job.worker_task_id)
	_job = null
	State.edit_context_changing.disconnect(_cancel_selection)


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
	_job.target_color = _source_frame.get_color(seed_cell)
	_job.connected = _settings.connected
	_job.previous_selection = State.selection.capture()
	_job.mode = _settings.mode
	var work := _job.estimate_work(_source_frame.count() + State.selection.count())
	if work <= 4096:
		_job.run()
		_finish_selection()
	else:
		_operation_id = State.begin_operation("Selecting matching voxels", work, true, self)
		_job.worker_task_id = WorkerThreadPool.add_task(_job.run, true, "Wand selection")


func _process(_delta: float) -> void:
	if _job == null:
		return
	if not WorkerThreadPool.is_task_completed(_job.worker_task_id):
		var progress := _job.progress()
		State.update_operation(_operation_id, progress[1], progress[2], progress[0])
		return
	WorkerThreadPool.wait_for_task_completion(_job.worker_task_id)
	_finish_selection()


func _finish_selection() -> void:
	var job := _job
	_job = null
	if job.checkpoint(0) and State.document == _source_document and State.get_current_voxel_frame() == _source_frame:
		State.begin_stroke()
		State.selection.restore(job.result)
		State.end_stroke("Wand selection")
		State.selection_changed.emit()
	State.finish_operation(_operation_id)
	_operation_id = 0
	_source_document = null
	_source_frame = null


func _cancel_selection() -> void:
	if _job:
		_job.cancel()
	_source_document = null
	_source_frame = null
	State.finish_operation(_operation_id)
	_operation_id = 0
