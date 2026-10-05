extends "res://Plugins/Brush/BrushTool.gd"

var _anchor := VoxelPicking.NONE
var _endpoint := VoxelPicking.NONE
var _mouse_pressed := false
var _dragged := false
var _line_snapshot: VoxelFrame
var _revision := 0
var _preview_requested := false
var _commit_requested := false
var _preview_result: BrushJob


func _enter_tree() -> void:
	super._enter_tree()
	State.cells_changed.connect(_on_cells_changed)
	State.chunks_changed.connect(_on_cells_changed)
	State.selection_changed.connect(_cancel_edit)
	State.floor_plane_changed.connect(_cancel_edit)


func _exit_tree() -> void:
	super._exit_tree()
	State.cells_changed.disconnect(_on_cells_changed)
	State.chunks_changed.disconnect(_on_cells_changed)
	State.selection_changed.disconnect(_cancel_edit)
	State.floor_plane_changed.disconnect(_cancel_edit)


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event.is_action_pressed("ui_cancel") and _anchor != VoxelPicking.NONE:
		_cancel_edit()
		return true
	if event.is_action_pressed("ui_accept") and _anchor != VoxelPicking.NONE:
		_request_commit()
		return true
	if event is InputEventMouseButton:
		if event.button_index != MOUSE_BUTTON_LEFT:
			return false
		if _commit_requested:
			return true
		var ray := _ray(pos)
		if event.pressed:
			_mouse_pressed = true
			if _anchor == VoxelPicking.NONE:
				var pick := _pick_start(ray[0], ray[1])
				if pick.target == VoxelPicking.NONE:
					return false
				_begin_line(pick)
			else:
				var pick := _pick_endpoint(ray[0], ray[1])
				if pick.target != VoxelPicking.NONE:
					_update_endpoint(pick.target)
					_request_commit()
		else:
			_mouse_pressed = false
			if _anchor != VoxelPicking.NONE and _dragged:
				var pick := _pick_endpoint(ray[0], ray[1], true)
				if pick.target != VoxelPicking.NONE:
					_update_endpoint(pick.target)
				_request_commit()
		return true
	if event is InputEventMouseMotion:
		var ray := _ray(pos)
		if _anchor != VoxelPicking.NONE:
			if not _commit_requested:
				var pick := _pick_endpoint(ray[0], ray[1], _mouse_pressed)
				if pick.target != VoxelPicking.NONE:
					_dragged = _dragged or (_mouse_pressed and pick.target != _anchor)
					_update_endpoint(pick.target)
			return true
		if event.button_mask == 0:
			update_visual(_pick_start(ray[0], ray[1]))
			return true
	return false


func _pick_start(origin: Vector3, dir: Vector3) -> PickResult:
	var pick := VoxelPicking.start_pick(origin, dir, State.get_current_voxel_frame(), _forward())
	if pick.add_target != VoxelPicking.NONE:
		pick.target = pick.add_target
		pick.plane = VoxelPicking.view_plane(pick.target, origin, _forward())
	return pick


func pick_drag(request: PickRequest) -> PickResult:
	_plane = VoxelPicking.view_plane(_anchor, request.origin, request.forward)
	return VoxelPicking.drag_pick(request.origin, request.dir, request.frame, _plane)


func _pick_endpoint(origin: Vector3, dir: Vector3, plane_only := false) -> PickResult:
	if not plane_only:
		var pick := _pick_start(origin, dir)
		if pick.hit != VoxelPicking.NONE:
			return pick
	return _pick_drag(origin, dir)


func _begin_line(pick: PickResult) -> void:
	_source_document = State.document
	_source_frame = State.get_current_voxel_frame()
	_line_snapshot = _source_frame.copy_frame()
	_plane = pick.plane
	_anchor = pick.target
	_endpoint = VoxelPicking.NONE
	_dragged = false
	_stroke_pattern = _settings.pattern()
	_stroke_diameter = _settings.diameter
	_stroke_shape = _settings.shape
	_stroke_pattern_size = _settings.estimated_size()
	_stroke_color = State.current_color
	_selection_mask = State.selection.capture()
	_update_endpoint(_anchor)


func _update_endpoint(endpoint: Vector3i) -> void:
	if endpoint == _endpoint:
		return
	_endpoint = endpoint
	_request_preview()


func _request_preview() -> void:
	_revision += 1
	_preview_requested = true
	_preview_result = null
	if _job:
		_job.cancel()
	else:
		_start_preview()


func _start_preview() -> void:
	_preview_requested = false
	_job = _create_preview_job()
	_job.centers = _preview_centers()
	_job.pattern = _stroke_pattern
	_job.diameter = _stroke_diameter
	_job.shape = _stroke_shape
	_job.color = _stroke_color
	_job.selection_mask = _selection_mask
	_job.edited_frame = _line_snapshot.copy_frame()
	_job.revision = _revision
	var work := _job.centers.size() * _stroke_pattern_size
	if work <= INLINE_EDIT_LIMIT:
		_job.run()
		_finish_preview()
	else:
		if not State.has_operation(_operation_id):
			_operation_id = State.begin_operation("Preparing line", work, true, self)
		_job.worker_task_id = WorkerThreadPool.add_task(_job.run, true, "Line preview")


func _create_preview_job() -> BrushJob:
	return BrushJob.new()


func _preview_centers() -> Array[Vector3i]:
	return StrokeLine.cells(_anchor, _endpoint)


func _process(_delta: float) -> void:
	if _anchor == VoxelPicking.NONE:
		_update_hover()
	if _job:
		if not WorkerThreadPool.is_task_completed(_job.worker_task_id):
			var progress := _job.progress()
			State.update_operation(_operation_id, progress[1], progress[2], "Preparing line", progress[0])
			return
		WorkerThreadPool.wait_for_task_completion(_job.worker_task_id)
		_finish_preview()
	if _preview_requested and _anchor != VoxelPicking.NONE:
		_start_preview()
	if _job == null and not _preview_requested:
		State.finish_operation(_operation_id)
		_operation_id = 0
		if _commit_requested:
			_commit_line()


func _finish_preview() -> void:
	var job := _job
	_job = null
	if job.revision != _revision or _anchor == VoxelPicking.NONE:
		return
	_preview_result = job
	_settings.cache_pattern(job.diameter, job.shape, job.pattern)
	_stroke_pattern = job.pattern
	_show_preview(job)
	visible = not job.cell_colors.is_empty()


func _show_preview(job: BrushJob) -> void:
	position = Vector3.ZERO
	$Cursor.show_voxels(job.cell_colors, _stroke_color, false, 0, _stroke_shape == _settings.BrushShape.SELECTION)


func _request_commit() -> void:
	_commit_requested = true
	if _job == null and not _preview_requested:
		_commit_line()


func _commit_line() -> void:
	if _preview_result == null:
		return
	var job := _preview_result
	var frame := _source_frame
	var context_valid := State.document == _source_document and State.get_current_voxel_frame() == frame
	_cancel_edit()
	if not context_valid:
		return
	State.begin_stroke()
	frame.restore(job.edited_frame.capture())
	State.document._bounds_dirty = true
	State.end_stroke("Line")
	if not job.changed_chunks.is_empty():
		State.chunks_changed.emit(State.current_frame, job.changed_chunks)


func _cancel_edit() -> void:
	_anchor = VoxelPicking.NONE
	_endpoint = VoxelPicking.NONE
	_mouse_pressed = false
	_dragged = false
	_revision += 1
	_preview_requested = false
	_commit_requested = false
	_preview_result = null
	_line_snapshot = null
	super._cancel_edit()


func _on_cells_changed(_frame: int, _affected: Array[Vector3i]) -> void:
	if _anchor != VoxelPicking.NONE:
		_cancel_edit()


func _on_settings_changed() -> void:
	if _anchor == VoxelPicking.NONE:
		super._on_settings_changed()
	else:
		_stroke_pattern = _settings.pattern()
		_stroke_diameter = _settings.diameter
		_stroke_shape = _settings.shape
		_stroke_pattern_size = _settings.estimated_size()
		_request_preview()


func _on_color_changed(color: Color) -> void:
	super._on_color_changed(color)
	if _anchor != VoxelPicking.NONE:
		_stroke_color = color
		_request_preview()


func update_visual(pick: PickResult) -> void:
	if pick.target == VoxelPicking.NONE:
		visible = false
		return
	if pick.plane.axis != _cursor_axis:
		_show_brush_shape(pick.plane.axis)
	_last_pick = pick
	position = Vector3(pick.target)
	visible = true
