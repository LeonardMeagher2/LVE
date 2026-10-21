extends HBoxContainer

## The paint option bar.
##
## It shows the options of the active paint tool. The brush section edits the
## paintbrush diameter, the shape, and the pixel-perfect flag. The fill section
## edits the connected option. The spray section edits the spot diameter, the
## spray radius, and the speed.

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
	var tool: int = _settings.tool
	$Brush.visible = tool == _settings.Tools.PAINTBRUSH
	$Fill.visible = tool == _settings.Tools.FILL
	$Spray.visible = tool == _settings.Tools.SPRAY
	$Brush/Diameter.set_value_no_signal(_settings.diameter)
	var shape_buttons := [$Brush/Shape/Cube, $Brush/Shape/Sphere, $Brush/Shape/Selection]
	shape_buttons[_settings.shape].button_pressed = true
	_refresh_selection_availability()
	$Brush/Diameter.visible = _settings.shape != _settings.BrushShape.SELECTION
	$Brush/PixelPerfect.set_pressed_no_signal(_settings.pixel_perfect)
	$Brush/ShapeSeparator.visible = $Brush/Diameter.visible
	$Fill/Connected.set_pressed_no_signal(_settings.connected)
	$Spray/SpotSize.set_value_no_signal(_settings.spot_diameter)
	$Spray/SprayRadius.set_value_no_signal(_settings.spray_radius)
	$Spray/Speed.set_value_no_signal(_settings.speed)


# Updates only the selection-source button. A cell or chunk change can cross the
# empty-frame boundary, so the button is the only control that reacts to it.
func _refresh_selection_availability() -> void:
	var frame := State.get_current_voxel_frame()
	$Brush/Shape/Selection.disabled = _source_job != null or State.edit_busy() or frame == null or (frame.count() == 0 and _settings.selection_pattern.is_empty())


func _on_cells_changed(_frame: int, _affected: Array[Vector3i]) -> void:
	_refresh_selection_availability()


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
		# The shared helper owns the launch, the progress pump, and the join. The
		# context check runs once per pumped frame. The closure captures this job
		# and its source context, so a stale pump cannot cancel a newer job.
		await State.run_edit_job(job, operation_id, "Voxel brush", func() -> void:
			if State.document != document or State.get_current_voxel_frame() != frame or not is_inside_tree():
				job.cancel()
		)
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
		_source_job.wait_for_worker()
		_source_job = null
	State.finish_operation(_operation_id)
	_operation_id = 0


func _on_pixel_perfect_toggled(toggled_on: bool) -> void:
	_settings.pixel_perfect = toggled_on


func _on_connected_toggled(toggled_on: bool) -> void:
	_settings.connected = toggled_on


func _on_spot_size_changed(value: float) -> void:
	_settings.spot_diameter = int(value)


func _on_spray_radius_changed(value: float) -> void:
	_settings.spray_radius = int(value)


func _on_speed_changed(value: float) -> void:
	_settings.speed = int(value)
