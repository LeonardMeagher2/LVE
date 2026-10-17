extends VoxelTool

# The select tools drag a shape over the view and select the full volume behind it.
const IMMEDIATE_LIMIT := 4096
# A press and release in one place still selects a small area.
const CLICK_SIZE := 7.0

var _settings := preload("../settings.tres")

var _screen_press := Vector2.ZERO
var _screen_job: ScreenSelection.Job
var _screen_operation_id := 0
var _screen_document: VoxelDocument
var _screen_frame: VoxelFrame


func _enter_tree() -> void:
	# A tool switch can interrupt a drag. Start the entry clean.
	_stroke_active = false
	$ScreenBand.hide_band()
	State.edit_context_changing.connect(_cancel_screen_job)


func _exit_tree() -> void:
	_cancel_screen_job()
	if _screen_job and _screen_job.worker_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_screen_job.worker_task_id)
	_screen_job = null
	State.edit_context_changing.disconnect(_cancel_screen_job)


func _process(_delta: float) -> void:
	if _screen_job == null:
		return
	if not WorkerThreadPool.is_task_completed(_screen_job.worker_task_id):
		var progress := _screen_job.progress()
		State.update_operation(_screen_operation_id, progress[1], progress[2], progress[0])
		return
	WorkerThreadPool.wait_for_task_completion(_screen_job.worker_task_id)
	_finish_screen_selection()


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if _screen_job != null:
		return _screen_pending_input(event)
	if event is InputEventKey:
		return _cancel_key(event as InputEventKey)
	if event is InputEventMouseButton:
		return _screen_button(event as InputEventMouseButton, pos)
	if event is InputEventMouseMotion:
		return _screen_motion(event as InputEventMouseMotion, pos)
	return false


func _screen_button(event: InputEventMouseButton, pos: Vector2) -> bool:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false
	if event.pressed:
		begin_stroke()
		_screen_press = pos
		_stroke_active = true
		_begin_shape(pos)
		return true
	if _stroke_active:
		_stroke_active = false
		$ScreenBand.hide_band()
		_end()
		_commit_shape(pos)
	return true


func _screen_motion(event: InputEventMouseMotion, pos: Vector2) -> bool:
	if _stroke_active and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		_update_shape(pos)
		return true
	return false


func _cancel_key(event: InputEventKey) -> bool:
	if not event.is_action_pressed("ui_cancel"):
		return false
	if _stroke_active:
		_stroke_active = false
		$ScreenBand.hide_band()
		_end()
	elif _settings.mode == _settings.SelectMode.REPLACE and not State.selection.is_empty():
		begin_stroke()
		State.selection.clear()
		State.selection_changed.emit()
		_end()
	return true


# Consume the events that belong to a pending screen job. Let view navigation through.
func _screen_pending_input(event: InputEvent) -> bool:
	if event is InputEventKey:
		if (event as InputEventKey).is_action_pressed("ui_cancel"):
			_cancel_screen_job()
			return true
		return false
	return event is InputEventMouseButton


# The subclass builds its shape from the pointer path.
func _begin_shape(_pos: Vector2) -> void:
	pass


func _update_shape(_pos: Vector2) -> void:
	pass


func _commit_shape(_pos: Vector2) -> void:
	pass


# A press and release in one place select the voxels under the pointer.
func _screen_rectangle(release_pos: Vector2) -> Rect2:
	var travel := (release_pos - _screen_press).abs()
	if travel.x < CLICK_SIZE and travel.y < CLICK_SIZE:
		var half := Vector2(CLICK_SIZE, CLICK_SIZE) * 0.5
		return Rect2(_screen_press - half, Vector2(CLICK_SIZE, CLICK_SIZE))
	var near_corner := Vector2(minf(_screen_press.x, release_pos.x), minf(_screen_press.y, release_pos.y))
	return Rect2(near_corner, travel)


func _show_band_rectangle(rectangle: Rect2) -> void:
	$ScreenBand.show_rectangle(rectangle)


func _show_band_polygon(points: PackedVector2Array) -> void:
	$ScreenBand.show_polygon(points)


func _commit_screen(rectangle: Rect2, polygon: PackedVector2Array) -> void:
	if _screen_job or State.edit_busy():
		return
	var view := ScreenSelection.view_of(get_viewport().get_camera_3d(), Vector2(get_viewport().get_visible_rect().size))
	if view.is_empty():
		return
	var frame := State.get_current_voxel_frame()
	if frame == null:
		return
	_screen_document = State.document
	_screen_frame = frame
	_screen_job = ScreenSelection.Job.new()
	_screen_job.source_frame = frame.copy_frame()
	_screen_job.edit_context = State.selection_context()
	_screen_job.view_matrix = view[0]
	_screen_job.projection = view[1]
	_screen_job.viewport_size = view[2]
	_screen_job.rectangle = rectangle
	_screen_job.polygon = polygon
	_screen_job.mode = _settings.mode
	_screen_job.previous_selection = State.selection.capture()
	var bounds := frame.get_bounds()
	# Empty cells need a finite volume. The frame bounds supply it.
	_screen_job.include_empty = _settings.include_empty and bounds.has_volume()
	_screen_job.empty_min = _cell_of(bounds.position + Vector3.ONE * 0.5)
	_screen_job.empty_max = _cell_of(bounds.end - Vector3.ONE * 0.5)
	var work := _screen_job.estimate_work(frame.count() + _screen_job.empty_cell_count() + State.selection.count())
	if work <= IMMEDIATE_LIMIT:
		_screen_job.run()
		_finish_screen_selection()
		return
	_screen_operation_id = State.begin_operation("Selecting projected voxels", work, true, self)
	_screen_job.worker_task_id = WorkerThreadPool.add_task(_screen_job.run, true, "Screen selection")


func _cell_of(point: Vector3) -> Vector3i:
	return Vector3i(floori(point.x + 0.5), floori(point.y + 0.5), floori(point.z + 0.5))


func _finish_screen_selection() -> void:
	var job := _screen_job
	_screen_job = null
	if job.checkpoint(0) and State.document == _screen_document and State.get_current_voxel_frame() == _screen_frame:
		State.begin_stroke()
		State.selection.restore(job.result)
		State.end_stroke("Screen selection")
		State.selection_changed.emit()
	State.finish_operation(_screen_operation_id)
	_screen_operation_id = 0
	_screen_document = null
	_screen_frame = null


func _cancel_screen_job() -> void:
	if _screen_job:
		_screen_job.cancel()
	_screen_document = null
	_screen_frame = null
	State.finish_operation(_screen_operation_id)
	_screen_operation_id = 0
