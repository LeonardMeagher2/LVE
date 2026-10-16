extends VoxelTool

const INLINE_EDIT_LIMIT := 4096
const BrushSettings := preload("./BrushToolSettings.gd")

var _settings := preload("./settings.tres")
var _filter := PixelPerfectStroke.new()
var _source_document: VoxelDocument
var _source_frame: VoxelFrame
var _stroke_open := false
var _end_requested := false
var _pending_centers: Array[Vector3i] = []
var _stroke_pattern := {}
var _stroke_diameter := 1
var _stroke_shape := 0
var _stroke_pattern_size := 1
var _stroke_color := Color.WHITE
var _paint_existing := false
var _erase_existing := false
var _selection_mask := {}
var _edit_context: VoxelFrame.EditContext
var _job: BrushJob
var _operation_id := 0
var _cursor_axis := -1
var _last_pick: PickResult
var _hover_job: BrushSettings.PatternJob
var _hover_operation_id := 0

class BrushJob extends VoxelFrame.EditJob:
	var centers: Array[Vector3i] = []
	var pattern := {}
	var material_pattern := {}
	var replace_materials := false
	var diameter := 1
	var shape := 0
	var color := Color.WHITE
	var paint_existing := false
	var erase_existing := false
	var selection_mask := {}
	var edited_frame: VoxelFrame
	var cell_colors := {}
	var cell_materials := {}
	var changed_chunks: Array[Vector3i] = []
	var revision := 0

	func run() -> void:
		if pattern.is_empty() and shape != BrushSettings.BrushShape.SELECTION:
			pattern = BrushSettings.build_pattern(diameter, shape, self)
		if not checkpoint(0):
			return
		stage("Preparing brush", centers.size() * pattern.size())
		var completed := 0
		for center in centers:
			for offset: Vector3i in pattern:
				var cell_position := center + offset
				if edit_context or ((selection_mask.is_empty() or selection_mask.has(cell_position)) and (not paint_existing or edited_frame.has(cell_position))):
					var source_color: Color = pattern[offset]
					cell_colors[cell_position] = Color.TRANSPARENT if erase_existing else (color if source_color == Color.TRANSPARENT else source_color)
					if replace_materials:
						cell_materials[cell_position] = material_pattern.get(offset, VoxelFrame.DEFAULT_MATERIAL)
				completed += 1
				if completed % 4096 == 0 and not checkpoint(completed):
					return
		stage("Applying brush", cell_colors.size())
		changed_chunks = apply_cells(edited_frame, cell_colors, paint_existing)
		cell_colors = applied_cell_colors
		if replace_materials:
			apply_materials()

	# The material pattern replaces the material of every applied cell.
	func apply_materials() -> void:
		var applied_materials: Dictionary = edit_context.expand(cell_materials, edited_frame, paint_existing, null, self) if edit_context else cell_materials
		edited_frame.set_materials(applied_materials, self)


func _enter_tree() -> void:
	State.edit_context_changing.connect(_cancel_edit)
	_settings.changed.connect(_on_settings_changed)


func _ready() -> void:
	State.color_changed.connect(_on_color_changed)
	_on_color_changed(State.current_color)
	visible = false


func _exit_tree() -> void:
	_cancel_edit()
	if _job and _job.worker_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_job.worker_task_id)
	_job = null
	if _hover_job:
		_hover_job.cancel()
		WorkerThreadPool.wait_for_task_completion(_hover_job.worker_task_id)
		_hover_job = null
	State.finish_operation(_hover_operation_id)
	_hover_operation_id = 0
	State.edit_context_changing.disconnect(_cancel_edit)
	_settings.changed.disconnect(_on_settings_changed)


func _on_color_changed(color: Color) -> void:
	$Cursor.set_brush_color(color)
	_cursor_axis = -1
	if _source_frame == null and _last_pick:
		update_visual(_last_pick)


func _on_settings_changed() -> void:
	if _hover_job:
		_hover_job.cancel()
	_on_color_changed(State.current_color)


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event.is_action_pressed("ui_cancel") and _stroke_open:
		_cancel_edit()
		return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if _stroke_open or _job:
			return true
		var ray := _ray(pos)
		if _pick_start(ray[0], ray[1]).target == VoxelPicking.NONE:
			return false
	return super.handle_input(event, pos)


func begin_stroke() -> void:
	super.begin_stroke()
	_filter.reset()
	_source_document = State.document
	_source_frame = State.get_current_voxel_frame()
	_stroke_open = true
	_end_requested = false
	_stroke_pattern = {}
	_stroke_diameter = _settings.diameter
	_stroke_shape = _settings.shape
	_stroke_pattern_size = _settings.estimated_size()
	_stroke_color = State.current_color
	_paint_existing = _settings.mode == _settings.BrushMode.PAINT
	_erase_existing = _settings.mode == _settings.BrushMode.ERASER
	_selection_mask = State.selection.capture()
	_edit_context = State.drawing_context()


func _apply_pick(target: Vector3i, hit: Vector3i) -> void:
	if _stroke_pattern.is_empty():
		_stroke_pattern = _settings.pattern()
	var center := hit if _paint_existing else target
	if center == VoxelPicking.NONE:
		return
	_queue_centers([center])


func _apply_stroke_to(to: Vector3i) -> void:
	var centers: Array[Vector3i] = []
	if _settings.pixel_perfect:
		centers = _filter.feed(to)
	else:
		centers = StrokeLine.cells(_last_target, to)
		centers.pop_front()
	_queue_centers(centers)


func _queue_centers(centers: Array[Vector3i]) -> void:
	_pending_centers.append_array(centers)
	if _job == null:
		_start_edit()


func _start_edit() -> void:
	if _pending_centers.is_empty():
		return
	_job = BrushJob.new()
	_job.centers = _pending_centers
	_pending_centers = []
	_job.pattern = _stroke_pattern
	_job.diameter = _stroke_diameter
	_job.shape = _stroke_shape
	_job.color = _stroke_color
	_job.paint_existing = _paint_existing or _erase_existing
	_job.erase_existing = _erase_existing
	_job.selection_mask = _selection_mask
	_job.edit_context = _edit_context
	_job.edited_frame = _source_frame.copy_frame()
	var work := _job.estimate_work(_job.centers.size() * _stroke_pattern_size)
	if work <= INLINE_EDIT_LIMIT:
		_job.run()
		_finish_edit()
	else:
		_operation_id = State.begin_operation("Erasing brush" if _erase_existing else "Painting brush", work, true, self)
		_job.worker_task_id = WorkerThreadPool.add_task(_job.run, true, "Brush stroke")


func _process(_delta: float) -> void:
	_update_hover()
	if _job:
		if not WorkerThreadPool.is_task_completed(_job.worker_task_id):
			var progress := _job.progress()
			State.update_operation(_operation_id, progress[1], progress[2], progress[0])
			return
		WorkerThreadPool.wait_for_task_completion(_job.worker_task_id)
		_finish_edit()
	if _stroke_open:
		_start_edit()
		if _end_requested and _job == null:
			_finish_stroke()


func _finish_edit() -> void:
	var job := _job
	_job = null
	if _stroke_open and State.document == _source_document and State.get_current_voxel_frame() == _source_frame:
		_stroke_pattern = job.pattern
		_settings.cache_pattern(job.diameter, job.shape, job.pattern)
		_source_frame.restore(job.edited_frame.capture())
		State.document._bounds_dirty = true
		if not job.changed_chunks.is_empty():
			State.chunks_changed.emit(State.current_frame, job.changed_chunks)
	State.finish_operation(_operation_id)
	_operation_id = 0


func _end() -> void:
	if _settings.pixel_perfect:
		_queue_centers(_filter.flush())
	_end_requested = true
	_stroke_active = false
	if _job == null:
		_finish_stroke()


func _finish_stroke() -> void:
	super._end()
	_stroke_open = false
	_end_requested = false
	_source_document = null
	_source_frame = null
	_edit_context = null


func end_stroke() -> void:
	State.end_stroke("Erase" if _erase_existing else "Stroke")


func _cancel_edit() -> void:
	if _job:
		_job.cancel()
	if _hover_job:
		_hover_job.cancel()
	State.finish_operation(_hover_operation_id)
	_hover_operation_id = 0
	_last_pick = null
	_cursor_axis = -1
	if has_node("Cursor"):
		$Cursor.show_selection(null)
	_pending_centers = []
	if _stroke_open:
		State.cancel_stroke()
	_stroke_open = false
	_end_requested = false
	_stroke_active = false
	_plane = null
	_last_target = VoxelPicking.NONE
	_source_document = null
	_source_frame = null
	_edit_context = null
	visible = false
	State.finish_operation(_operation_id)
	_operation_id = 0


func _pick_start(origin: Vector3, dir: Vector3) -> PickResult:
	var pick := super._pick_start(origin, dir)
	if _settings.mode in [_settings.BrushMode.PAINT, _settings.BrushMode.ERASER] or pick.add_target == VoxelPicking.NONE:
		return pick
	pick.target = pick.add_target
	pick.plane = VoxelPicking.view_plane(pick.target, origin, _forward())
	return pick


func pick_drag(request: PickRequest) -> PickResult:
	if _settings.mode != _settings.BrushMode.PAINT:
		return super.pick_drag(request)
	return VoxelPicking.start_pick(request.origin, request.dir, request.frame, request.forward)


func update_visual(pick: PickResult) -> void:
	if pick.plane == null:
		pick.plane = _plane
	_last_pick = pick
	if pick.target == VoxelPicking.NONE or (_settings.mode == _settings.BrushMode.PAINT and pick.hit == VoxelPicking.NONE):
		visible = false
		return
	var axis := _plane.axis if _stroke_active else pick.plane.axis
	if axis != _cursor_axis:
		_show_brush_shape(axis)
	position = Vector3(pick.target)
	visible = true


func _show_brush_shape(axis: int) -> void:
	var pattern := _settings.pattern()
	if pattern.is_empty() and _settings.shape != _settings.BrushShape.SELECTION:
		if _hover_job == null:
			_hover_job = _settings.PatternJob.new()
			_hover_job.diameter = _settings.diameter
			_hover_job.shape = _settings.shape
			_hover_operation_id = State.begin_operation("Preparing brush preview", _settings.estimated_size(), false, self)
			_hover_job.worker_task_id = WorkerThreadPool.add_task(_hover_job.run, false, "Brush shape")
		return
	var cube_diameter: int = _settings.diameter if _settings.shape == _settings.BrushShape.CUBE else 0
	var use_voxel_colors: bool = _settings.shape == _settings.BrushShape.SELECTION
	$Cursor.show_voxels(pattern, Color.WHITE if use_voxel_colors else State.current_color, _settings.mode == _settings.BrushMode.ERASER, cube_diameter, use_voxel_colors)
	_cursor_axis = axis


func _update_hover() -> void:
	if _hover_job == null or not WorkerThreadPool.is_task_completed(_hover_job.worker_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(_hover_job.worker_task_id)
	var job := _hover_job
	_hover_job = null
	State.finish_operation(_hover_operation_id)
	_hover_operation_id = 0
	if job.checkpoint(0):
		_settings.cache_pattern(job.diameter, job.shape, job.pattern)
	if _last_pick and not _stroke_open:
		_cursor_axis = -1
		update_visual(_last_pick)
