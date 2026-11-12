extends "res://plugins/brush/BrushTool.gd"

## The line tool.
##
## A press sets the anchor. A drag or a second click sets the endpoint and
## commits one line. Enter commits the line. Escape and a context change
## discard it. The line stamps the brush pattern along the path.

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
	if not State.cells_changed.is_connected(_on_cells_changed):
		State.cells_changed.connect(_on_cells_changed)
	if not State.chunks_changed.is_connected(_on_cells_changed):
		State.chunks_changed.connect(_on_cells_changed)
	if not State.selection_changed.is_connected(_cancel_edit):
		State.selection_changed.connect(_cancel_edit)
	if not State.floor_plane_changed.is_connected(_cancel_edit):
		State.floor_plane_changed.connect(_cancel_edit)
	# The anchor froze its symmetry and slice at the press, so a change must
	# discard the line instead of committing it with the old scope.
	if not State.symmetry_changed.is_connected(_cancel_edit):
		State.symmetry_changed.connect(_cancel_edit)
	if not State.slice_changed.is_connected(_cancel_edit):
		State.slice_changed.connect(_cancel_edit)


func _exit_tree() -> void:
	super._exit_tree()
	# The preview runner awaits `State.run_edit_job`, so it continues after this
	# detach. The preview is discarded here and its worker joined once. The runner
	# adopts only its own job, so it cannot publish this preview.
	if _job:
		_job.cancel()
		_job.wait_for_worker()
		_job = null
	State.finish_operation(_operation_id)
	_operation_id = 0
	if State.cells_changed.is_connected(_on_cells_changed):
		State.cells_changed.disconnect(_on_cells_changed)
	if State.chunks_changed.is_connected(_on_cells_changed):
		State.chunks_changed.disconnect(_on_cells_changed)
	if State.selection_changed.is_connected(_cancel_edit):
		State.selection_changed.disconnect(_cancel_edit)
	if State.floor_plane_changed.is_connected(_cancel_edit):
		State.floor_plane_changed.disconnect(_cancel_edit)
	if State.symmetry_changed.is_connected(_cancel_edit):
		State.symmetry_changed.disconnect(_cancel_edit)
	if State.slice_changed.is_connected(_cancel_edit):
		State.slice_changed.disconnect(_cancel_edit)
	# `tree_exited` releases the context subscriptions after this exit.


# The line keeps its preview discard policy. Only the stroke tool commits on a
# switch, so the line drops its pending preview.
## Discards the pending preview on a tool or mode switch. A line never commits
## on a switch.
func finish_on_switch() -> void:
	_cancel_edit()


## Handles one input event. It sets the anchor, the endpoint, and the commit.
## Escape cancels and Enter commits.
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
	var pick := VoxelPicking.start_pick(origin, dir, State.get_current_voxel_frame(), _forward(), State.slice_enabled)
	if pick.add_target != VoxelPicking.NONE:
		pick.target = pick.add_target
		if not State.slice_enabled:
			pick.plane = VoxelPicking.view_plane(pick.target, origin, _forward())
	return pick


## Returns the drag pick on the plane through the anchor. The slice plane stays
## the drag plane while the slice is on.
func pick_drag(request: PickRequest) -> PickResult:
	if not State.slice_enabled:
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
	_stroke_offsets = _settings.pattern_offsets()
	_stroke_material_pattern = _settings.selection_material_pattern.duplicate(true) if _settings.shape == StampSettings.BrushShape.SELECTION else {}
	_stroke_diameter = _settings.diameter
	_stroke_shape = _settings.shape
	_stroke_pattern_size = _settings.estimated_size()
	_stroke_color = State.current_color
	_stroke_material = State.current_material.duplicate()
	_edit_context = State.drawing_context()
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
	_job.offsets = _stroke_offsets
	if not _job.replace_materials:
		_job.material_pattern = _stroke_material_pattern
	_job.diameter = _stroke_diameter
	_job.shape = _stroke_shape
	_job.material = _stroke_material
	_job.edit_context = _edit_context
	# The preview writes its own frame. `job_frame` shares the frozen line
	# snapshot, so a preview costs the cells it writes, not the whole frame.
	_job.edited_frame = VoxelFrame.job_frame(_line_snapshot)
	_job.revision = _revision
	var work := _job.estimate_work(_job.centers.size() * _stroke_pattern_size)
	if work <= INLINE_EDIT_LIMIT:
		_job.run()
		_finish_preview()
		_service_preview()
		return
	# One runner owns this preview batch. It pumps the progress and joins the
	# worker even when a tool switch detaches this node.
	var job := _job
	var operation_id := _begin_preview_operation(work)
	await State.run_edit_job(job, operation_id, "Line preview", _cancel_preview_if_stale.bind(job))
	# A cancel or a detach can clear or replace `_job` while the runner waits. The
	# runner adopts only the job it started, so it cannot publish a stale preview
	# or finish a newer operation.
	if _job != job:
		return
	_finish_preview()
	_finish_preview_operation(operation_id)
	_service_preview()


# Cancels one preview worker when its request is no longer current. The runner
# calls this once per pumped frame, so a superseded preview stops early.
func _cancel_preview_if_stale(job: BrushJob) -> void:
	if _job != job or _anchor == VoxelPicking.NONE or job.revision != _revision:
		job.cancel()


## Returns the operation id that reports the preview progress. A subclass that
## already owns a longer operation returns that id.
func _begin_preview_operation(work: int) -> int:
	if not State.has_operation(_operation_id):
		_operation_id = State.begin_operation("Preparing line", work, true, self)
	return _operation_id


## Finishes the operation that reports the preview progress. A subclass that
## shares a longer operation keeps it open.
func _finish_preview_operation(operation_id: int) -> void:
	State.finish_operation(operation_id)
	if _operation_id == operation_id:
		_operation_id = 0


# Continues the preview after one job finishes or is discarded. A newer request
# wins, and a commit waits for the newest preview.
func _service_preview() -> void:
	if _preview_requested and _anchor != VoxelPicking.NONE:
		_start_preview()
		return
	if _job == null and not _preview_requested and _commit_requested:
		_commit_line()


func _create_preview_job() -> BrushJob:
	return BrushJob.new()


func _preview_centers() -> Array[Vector3i]:
	return StrokeLine.cells(_anchor, _endpoint)


func _process(_delta: float) -> void:
	if _anchor == VoxelPicking.NONE:
		_update_hover()


func _finish_preview() -> void:
	var job := _job
	_job = null
	if job.revision != _revision or _anchor == VoxelPicking.NONE:
		return
	_preview_result = job
	_settings.cache_pattern(job.diameter, job.shape, job.pattern, job.offsets)
	_stroke_pattern = job.pattern
	_stroke_offsets = job.offsets
	_show_preview(job)
	visible = not job.applied_cells.is_empty()


func _show_preview(job: BrushJob) -> void:
	position = Vector3.ZERO
	$Cursor.set_brush_material(_stroke_material)
	var use_voxel_colors := _stroke_shape == _settings.BrushShape.SELECTION
	$Cursor.show_voxels(job.applied_cells if use_voxel_colors else _preview_colors(job), _stroke_color, false, 0, use_voxel_colors)


# The preview shows the applied cells. Each color comes from the applied material.
func _preview_colors(job: BrushJob) -> Dictionary:
	var colors := {}
	for cell_position in job.applied_cells:
		colors[cell_position] = VoxelFrame.material_color(job.applied_cells[cell_position])
	return colors


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
	var tx := State.begin_edit()
	if tx == null:
		return
	# Publish the cells the preview wrote. The snapshot is unchanged, so an
	# unchanged chunk stays as it is.
	frame.apply_published(job.changed_chunks, job.edited_frame)
	State.document._bounds_dirty = true
	State.finish_edit(tx, "Line")
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


func _on_cells_changed(_frame: int, _cells: Array[Vector3i]) -> void:
	if _anchor != VoxelPicking.NONE:
		_cancel_edit()


func _on_settings_changed() -> void:
	if _anchor == VoxelPicking.NONE:
		super._on_settings_changed()
	else:
		_stroke_pattern = _settings.pattern()
		_stroke_offsets = _settings.pattern_offsets()
		_stroke_material_pattern = _settings.selection_material_pattern.duplicate(true) if _settings.shape == StampSettings.BrushShape.SELECTION else {}
		_stroke_diameter = _settings.diameter
		_stroke_shape = _settings.shape
		_stroke_pattern_size = _settings.estimated_size()
		_request_preview()


func _on_color_changed(color: Color) -> void:
	super._on_color_changed(color)
	if _anchor != VoxelPicking.NONE:
		_stroke_color = color
		_stroke_material = State.current_material.duplicate()
		_request_preview()


## Updates the brush cursor for one pick. A line in progress shows its own
## preview.
func update_visual(pick: PickResult) -> void:
	if pick.target == VoxelPicking.NONE:
		visible = false
		return
	if pick.plane.axis != _cursor_axis:
		_show_brush_shape(pick.plane.axis)
	_last_pick = pick
	position = Vector3(pick.target)
	visible = true
