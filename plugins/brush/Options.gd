extends HBoxContainer

var _settings := preload("./settings.tres")
var _source_job: VoxelFrame.EditJob
var _operation_id := 0


func _ready() -> void:
	_settings.changed.connect(_sync)
	State.selection_changed.connect(_sync)
	State.frame_changed.connect(_sync)
	State.cells_changed.connect(_on_cells_changed)
	State.chunks_changed.connect(_on_cells_changed)
	State.activity_changed.connect(_sync)
	_sync()


func _sync() -> void:
	$Diameter.set_value_no_signal(_settings.diameter)
	var shape_buttons := [$Shape/Cube, $Shape/Sphere, $Shape/Selection]
	shape_buttons[_settings.shape].button_pressed = true
	var frame := State.get_current_voxel_frame()
	$Shape/Selection.disabled = _source_job != null or State.edit_busy() or frame == null or (frame.count() == 0 and _settings.selection_pattern.is_empty())
	$Diameter.visible = _settings.shape != _settings.BrushShape.SELECTION
	$PixelPerfect.visible = _settings.mode != _settings.BrushMode.LINE
	$PixelPerfect.set_pressed_no_signal(_settings.pixel_perfect)
	$ShapeSeparator.visible = $Diameter.visible


func _on_diameter_changed(value: float) -> void:
	_settings.diameter = int(value)


func _on_cube_pressed() -> void:
	_settings.shape = _settings.BrushShape.CUBE


func _on_sphere_pressed() -> void:
	_settings.shape = _settings.BrushShape.SPHERE


func _on_selection_pressed() -> void:
	if State.edit_busy() or _source_job:
		return
	var document := State.document
	var frame := State.get_current_voxel_frame()
	if frame.count() == 0:
		if not _settings.selection_pattern.is_empty():
			_settings.shape = _settings.BrushShape.SELECTION
		_sync()
		return
	var job := _settings.CopyJob.new()
	job.source_frame = frame.copy_frame()
	job.selection_mask = State.selection.capture()
	_source_job = job
	_sync()
	var source_count := job.selection_mask.size() if not job.selection_mask.is_empty() else frame.count()
	var operation_id := State.begin_operation("Preparing voxel brush", source_count, true, self)
	_operation_id = operation_id
	if source_count <= 4096:
		job.run()
	else:
		job.worker_task_id = WorkerThreadPool.add_task(job.run, true, "Voxel brush")
		while job.worker_task_id >= 0 and not WorkerThreadPool.is_task_completed(job.worker_task_id):
			if State.document != document or State.get_current_voxel_frame() != frame or not is_inside_tree():
				job.cancel()
			var progress := job.progress()
			State.update_operation(operation_id, progress[1], progress[2], progress[0])
			await State.get_tree().process_frame
		if job.worker_task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
			job.worker_task_id = -1
	State.finish_operation(operation_id)
	if _source_job == job:
		_source_job = null
		_operation_id = 0
	if is_inside_tree() and State.document == document and State.get_current_voxel_frame() == frame and job.checkpoint(job.pattern.size()):
		_settings.use_selection(job.pattern, job.pattern_materials)
	if is_inside_tree():
		_sync()


func _exit_tree() -> void:
	if _source_job:
		_source_job.cancel()
		if _source_job.worker_task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(_source_job.worker_task_id)
			_source_job.worker_task_id = -1
		_source_job = null
	State.finish_operation(_operation_id)
	_operation_id = 0


func _on_cells_changed(_frame: int, _affected: Array[Vector3i]) -> void:
	_sync()

func _on_pixel_perfect_toggled(toggled_on: bool) -> void:
	_settings.pixel_perfect = toggled_on
