extends VoxelTool

const INLINE_EDIT_LIMIT := 4096
const CLICK_SLOP_PX := 4.0

var _settings := preload("../settings.tres")
var _dragging := false
var _pending := false
var _dragged := false
var _press_pos := Vector2.ZERO
var _track_selection := false
var _cells: Array[Vector3i] = []
var _colors := {}
var _source_bounds := AABB()
var _dest_cells: Array[Vector3i] = []
var _dest_colors := {}
var _destination_bounds := AABB()
var _covered := {}
var _source_document: VoxelDocument
var _source_frame: VoxelFrame
var _preview_revision := 0
var _preview_running := false
var _preview_requested := false
var _commit_requested := false
var _operation_id := 0
var _input_revision := 0
var _grab_waiting := false
var _mouse_down := false
var _queued_drag_ray: Array = []
var _grab_forward := Vector3.FORWARD
var _grab_camera_right := Vector3.RIGHT
var _jobs: Array[VoxelFrame.EditJob] = []
var _active_preview_job: TransformJob
var _symmetry_axes := 0
var _symmetry_origin_twice := Vector3i.ZERO

class SourceJob extends VoxelFrame.EditJob:
	var source_frame: VoxelFrame
	var selection_mask := {}
	var cell_positions: Array[Vector3i] = []
	var cell_colors := {}
	var bounds := AABB()

	func run() -> void:
		if not selection_mask.is_empty():
			stage("Preparing transform", selection_mask.size())
			for cell_position: Vector3i in selection_mask:
				cell_positions.append(cell_position)
				var color := source_frame.get_color(cell_position)
				if color != Color.TRANSPARENT:
					cell_colors[cell_position] = color
				_include_bounds(cell_position)
				if cell_positions.size() % 4096 == 0 and not checkpoint(cell_positions.size()):
					return
		else:
			stage("Preparing transform", source_frame.count())
			for chunk in source_frame.chunks.values():
				for cell_position: Vector3i in chunk.cell_colors:
					cell_positions.append(cell_position)
					cell_colors[cell_position] = chunk.cell_colors[cell_position]
					_include_bounds(cell_position)
				if not checkpoint(cell_positions.size()):
					return

	func _include_bounds(cell_position: Vector3i) -> void:
		var cell_bounds := AABB(Vector3(cell_position) - Vector3.ONE * 0.5, Vector3.ONE)
		bounds = bounds.merge(cell_bounds) if bounds.has_volume() else cell_bounds

class TransformJob extends VoxelFrame.EditJob:
	var source_positions: Array[Vector3i] = []
	var source_colors := {}
	var source_bounds := AABB()
	var old_positions: Array[Vector3i] = []
	var previous_covered := {}
	var edited_frame: VoxelFrame
	var track_selection := false
	var destination_colors := {}
	var destination_positions: Array[Vector3i] = []
	var destination_selection := {}
	var destination_bounds := AABB()
	var covered := {}
	var changed_chunks: Array[Vector3i] = []
	var offset := Vector3i.ZERO
	var symmetry_axes := 0
	var symmetry_origin_twice := Vector3i.ZERO

	func estimated_work() -> int:
		return source_positions.size()

	func run() -> void:
		_reduce_to_fundamental_domain()
		compute_destination()
		if not checkpoint(0):
			return
		_mirror_destination()
		if not checkpoint(0):
			return
		stage("Preparing transform", old_positions.size() + destination_colors.size())
		covered = previous_covered.duplicate()
		var old_shape := {}
		var changes := {}
		var completed := 0
		for cell_position in old_positions:
			old_shape[cell_position] = true
			if not destination_colors.has(cell_position):
				changes[cell_position] = covered.get(cell_position, Color.TRANSPARENT)
				covered.erase(cell_position)
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return
		for cell_position: Vector3i in destination_colors:
			if not old_shape.has(cell_position) and not covered.has(cell_position):
				var previous_color := edited_frame.get_color(cell_position)
				if previous_color != Color.TRANSPARENT:
					covered[cell_position] = previous_color
			changes[cell_position] = destination_colors[cell_position]
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return
		destination_positions.assign(destination_selection.keys() if track_selection else destination_colors.keys())
		stage("Preparing transform bounds", destination_positions.size())
		completed = 0
		for cell_position in destination_positions:
			var cell_bounds := AABB(Vector3(cell_position) - Vector3.ONE * 0.5, Vector3.ONE)
			destination_bounds = destination_bounds.merge(cell_bounds) if destination_bounds.has_volume() else cell_bounds
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return
		stage("Applying transform", changes.size())
		changed_chunks = edited_frame.set_cells(changes, self)

	func compute_destination() -> void:
		stage("Calculating transform", source_positions.size())
		var completed := 0
		for cell_position in source_positions:
			if track_selection:
				destination_selection[cell_position + offset] = true
			if source_colors.has(cell_position):
				destination_colors[cell_position + offset] = source_colors[cell_position]
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return

	func _symmetry_context() -> VoxelFrame.EditContext:
		var context := VoxelFrame.EditContext.new()
		context.axes = symmetry_axes
		context.origin_twice = symmetry_origin_twice
		return context

	# Keep one representative per symmetry orbit. Transform that, then mirror the result.
	# The model stays symmetric and a rotation does not add extra reflected copies.
	func _reduce_to_fundamental_domain() -> void:
		if symmetry_axes == 0:
			return
		var context := _symmetry_context()
		var reduced_positions: Array[Vector3i] = []
		var reduced_colors := {}
		var seen := {}
		for cell_position in source_positions:
			var canonical := context.reflect(cell_position, _canonical_mask(cell_position))
			if seen.has(canonical):
				continue
			seen[canonical] = true
			reduced_positions.append(canonical)
			if source_colors.has(cell_position):
				reduced_colors[canonical] = source_colors[cell_position]
		for canonical: Vector3i in reduced_colors:
			if source_colors.has(canonical):
				reduced_colors[canonical] = source_colors[canonical]
		source_positions = reduced_positions
		source_colors = reduced_colors

	func _canonical_mask(cell_position: Vector3i) -> int:
		var mask := 0
		for axis in 3:
			if symmetry_axes & (1 << axis) and cell_position[axis] * 2 <= symmetry_origin_twice[axis]:
				mask |= 1 << axis
		return mask

	func _mirror_destination() -> void:
		if symmetry_axes == 0:
			return
		stage("Mirroring transform", destination_colors.size() * 2)
		var context := _symmetry_context()
		destination_colors = context.expand(destination_colors, edited_frame, false, null, self)
		if track_selection:
			destination_selection = context.expand(destination_selection, edited_frame, false, null, self)


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event is InputEventMouseButton:
		return _on_mouse_button(event, pos)
	if event is InputEventMouseMotion:
		return _on_mouse_motion(event, pos)
	if event is InputEventKey:
		return _on_key(event)
	return false


func _enter_tree() -> void:
	_settings.commit_requested.connect(_commit)
	_settings.cancel_requested.connect(_cancel)
	if not State.edit_context_changing.is_connected(_finish_context_edit):
		State.edit_context_changing.connect(_finish_context_edit)


func _exit_tree() -> void:
	_settings.commit_requested.disconnect(_commit)
	_settings.cancel_requested.disconnect(_cancel)
	_commit()
	_disconnect_context_if_idle()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for job in _jobs:
			job.cancel()
			WorkerThreadPool.wait_for_task_completion(job.worker_task_id)


func _disconnect_context_if_idle() -> void:
	if not is_inside_tree() and not _preview_running and not _grab_waiting and State.edit_context_changing.is_connected(_finish_context_edit):
		State.edit_context_changing.disconnect(_finish_context_edit)


func _on_mouse_button(event: InputEventMouseButton, pos: Vector2) -> bool:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false
	_mouse_down = event.pressed
	if event.pressed:
		_press_pos = pos
		if not _grab_waiting:
			var ray := _ray(pos)
			_press(ray[0], ray[1])
	else:
		_release()
	return true


func _on_mouse_motion(event: InputEventMouseMotion, pos: Vector2) -> bool:
	if _grab_waiting and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		if (pos - _press_pos).length() < CLICK_SLOP_PX:
			return true
		_queued_drag_ray = _ray(pos)
		return true
	if _dragging and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		if not _dragged and (pos - _press_pos).length() < CLICK_SLOP_PX:
			return true
		var ray := _ray(pos)
		if _update_params(ray[0], ray[1]):
			_apply_preview()
		return true
	return false


func _on_key(event: InputEventKey) -> bool:
	if event.is_action_pressed("ui_accept") and (_dragging or _pending):
		_commit()
		return true
	if event.is_action_pressed("ui_cancel") and (_dragging or _pending):
		_cancel()
		return true
	return false


func _press(origin: Vector3, dir: Vector3) -> void:
	var camera := get_viewport().get_camera_3d()
	_grab_forward = -camera.basis.z if camera else Vector3.FORWARD
	_grab_camera_right = camera.basis.x if camera else Vector3.RIGHT
	var input_revision := _input_revision
	_grab_waiting = true
	_queued_drag_ray = []
	while _preview_running:
		await State.get_tree().process_frame
	if input_revision != _input_revision or not is_inside_tree():
		_grab_waiting = false
		_disconnect_context_if_idle()
		return
	if _dragging or _pending:
		_reanchor()
	else:
		var frame := State.get_current_voxel_frame()
		var source_count := State.selection.count() if not State.selection.is_empty() else frame.count()
		if source_count == 0:
			_grab_waiting = false
			return
		_track_selection = not State.selection.is_empty()
		begin_stroke()
		var symmetry := State.selection_context()
		_symmetry_axes = symmetry.axes
		_symmetry_origin_twice = symmetry.origin_twice
		_source_document = State.document
		_source_frame = frame
		_dragging = true
		_settings.transforming = true
		var preparation_id := State.begin_operation("Preparing transform", source_count, true, self)
		var job := SourceJob.new()
		job.source_frame = frame.copy_frame()
		job.selection_mask = State.selection.capture()
		if source_count <= INLINE_EDIT_LIMIT:
			job.run()
		else:
			job.worker_task_id = WorkerThreadPool.add_task(job.run, true, "Transform source")
			_jobs.append(job)
			while not WorkerThreadPool.is_task_completed(job.worker_task_id):
				_report_job(preparation_id, job)
				await State.get_tree().process_frame
			WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
			_jobs.erase(job)
		State.finish_operation(preparation_id)
		if input_revision != _input_revision or not _context_valid():
			_grab_waiting = false
			_disconnect_context_if_idle()
			return
		_cells = job.cell_positions
		_colors = job.cell_colors
		_source_bounds = job.bounds
	_grab_waiting = false
	_begin_grab(origin, dir)
	_dragging = true
	_dragged = false
	_resume_queued_drag()
	if _commit_requested:
		_commit()
	_disconnect_context_if_idle()


func _resume_queued_drag() -> void:
	if not _queued_drag_ray.is_empty() and _update_params(_queued_drag_ray[0], _queued_drag_ray[1]):
		_apply_preview()
	_queued_drag_ray = []
	if not _mouse_down:
		_release()


func _reanchor() -> void:
	if _dest_cells.is_empty():
		return
	_cells = _dest_cells
	_colors = _dest_colors
	_source_bounds = _destination_bounds
	_dest_cells = []
	_dest_colors = {}


func _release() -> void:
	if _grab_waiting:
		return
	if not _dragging:
		return
	_dragging = false
	if _dragged:
		_pending = true
	elif _on_click_without_drag():
		return
	elif not _pending:
		_clear_grab()
		_settings.transforming = false
		_end()


func _on_click_without_drag() -> bool:
	return false


func _apply_preview() -> void:
	_dragged = true
	_preview_revision += 1
	_preview_requested = true
	if _active_preview_job:
		_active_preview_job.cancel()
	if _preview_running:
		return
	_preview_running = true
	var operation_id := State.begin_operation("Calculating transform", -1, true, self)
	_operation_id = operation_id
	while _preview_requested and _context_valid():
		_preview_requested = false
		var revision := _preview_revision
		var job := _make_job()
		job.symmetry_axes = _symmetry_axes
		job.symmetry_origin_twice = _symmetry_origin_twice
		job.source_positions = _cells
		job.source_colors = _colors
		job.source_bounds = _source_bounds
		job.old_positions.assign(_dest_colors.keys() if not _dest_cells.is_empty() else _colors.keys())
		job.previous_covered = _covered
		job.edited_frame = _source_frame.copy_frame()
		job.track_selection = _track_selection
		_active_preview_job = job
		if job.estimated_work() <= INLINE_EDIT_LIMIT:
			job.run()
		else:
			job.worker_task_id = WorkerThreadPool.add_task(job.run, true, "Transform preview")
			_jobs.append(job)
			while not WorkerThreadPool.is_task_completed(job.worker_task_id):
				_report_job(operation_id, job)
				await State.get_tree().process_frame
			WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
			_jobs.erase(job)
		_active_preview_job = null
		if revision != _preview_revision or not _context_valid() or not State.has_operation(operation_id):
			continue
		_source_frame.restore(job.edited_frame.capture())
		_covered = job.covered
		_dest_cells = job.destination_positions
		_dest_colors = job.destination_colors
		_destination_bounds = job.destination_bounds
		if not job.changed_chunks.is_empty():
			_source_document._bounds_dirty = true
			State.chunks_changed.emit(_source_document.frames.find(_source_frame), job.changed_chunks)
		if _track_selection:
			State.selection.restore(job.destination_selection)
			State.selection_changed.emit()
	_preview_running = false
	if _commit_requested:
		_commit_now()
	State.finish_operation(operation_id)
	if _operation_id == operation_id:
		_operation_id = 0
	_disconnect_context_if_idle()


func _report_job(operation_id: int, job: VoxelFrame.EditJob) -> void:
	var progress := job.progress()
	State.update_operation(operation_id, progress[1], progress[2], progress[0])


func _make_job() -> TransformJob:
	return TransformJob.new()


func _context_valid() -> bool:
	return _source_document == State.document and _source_frame != null and _source_frame == State.get_current_voxel_frame()


func _finish_context_edit() -> void:
	_input_revision += 1
	_preview_revision += 1
	_preview_requested = false
	for job in _jobs:
		job.cancel()
	_commit_now()
	State.finish_operation(_operation_id)
	_operation_id = 0


func _commit() -> void:
	if not (_dragging or _pending):
		return
	if _preview_running or _grab_waiting:
		_commit_requested = true
		_dragging = false
		_pending = true
		return
	_commit_now()


func _commit_now() -> void:
	_commit_requested = false
	if not (_dragging or _pending):
		return
	_dragging = false
	_pending = false
	_clear_grab()
	_settings.transforming = false
	_end()


func _cancel() -> void:
	if not (_dragging or _pending):
		return
	_input_revision += 1
	_preview_revision += 1
	_preview_requested = false
	_commit_requested = false
	for job in _jobs:
		job.cancel()
	cancel_stroke()
	_dragging = false
	_pending = false
	_clear_grab()
	_settings.transforming = false
	_end()
	State.finish_operation(_operation_id)
	_operation_id = 0


func _clear_grab() -> void:
	_cells = []
	_colors = {}
	_dest_cells = []
	_dest_colors = {}
	_covered = {}
	_source_document = null
	_source_frame = null


func _plane_point(origin: Vector3, dir: Vector3) -> Vector3:
	if _plane == null:
		return Vector3.ZERO
	var denom: float = dir.dot(_plane.normal)
	if absf(denom) < 1e-8:
		return Vector3.ZERO
	var t: float = (_plane.point - origin).dot(_plane.normal) / denom
	if t <= 0.0:
		return Vector3.ZERO
	return origin + dir * t


func _view_axis() -> int:
	var toward := -_grab_forward
	var fx: float = absf(toward.x)
	var fy: float = absf(toward.y)
	var fz: float = absf(toward.z)
	if fy >= fx and fy >= fz:
		return 1
	elif fz >= fx:
		return 2
	return 0


func _view_axis_sign() -> float:
	var toward := -_grab_forward
	var a := _view_axis()
	return 1.0 if toward[a] >= 0.0 else -1.0


func _view_plane_through(point: Vector3) -> StrokePlane:
	var p := StrokePlane.new()
	p.axis = _view_axis()
	p.idx = 0
	p.point = point
	var n := Vector3.ZERO
	n[p.axis] = 1.0
	p.normal = n
	return p


func _source_bbox() -> AABB:
	return _source_bounds


func _begin_grab(_origin: Vector3, _dir: Vector3) -> void:
	pass


func _update_params(_origin: Vector3, _dir: Vector3) -> bool:
	return false


func is_settled() -> bool:
	return not _preview_running and not _grab_waiting
