extends VoxelTool

## Base class for the box and lasso selection tools.
##
## A drag selects the full volume behind its screen shape. The tool builds the
## selection on the worker pool for a large region. The shape applies as a
## release when a tool switch interrupts the drag.

# The select tools drag a shape over the view and select the full volume behind it.
## The estimated work above which the selection runs on the worker pool.
const IMMEDIATE_LIMIT := 4096
# A press and release in one place still selects a small area.
## The click rectangle edge length in pixels.
const CLICK_SIZE := 7.0

var _settings := preload("../settings.tres")

var _screen_press := Vector2.ZERO
# The last pointer position a press or drag reported. A tool switch uses it to
# apply the current outline as a release would.
var _last_pos := Vector2.ZERO
var _screen_job: ScreenSelection.Job
var _screen_operation_id := 0
var _screen_document: VoxelDocument
var _screen_frame: VoxelFrame


func _enter_tree() -> void:
	# A tool switch can interrupt a drag. Start the entry clean. The guarded
	# connects keep a re-entry free of a duplicate subscription. `tree_exited` runs
	# after the node leaves the tree, where `_exit_tree` still reports it inside.
	_stroke_active = false
	$ScreenBand.hide_band()
	if not tree_exited.is_connected(_release_context_subscriptions):
		tree_exited.connect(_release_context_subscriptions)
	if not State.edit_context_changing.is_connected(_cancel_screen_job):
		State.edit_context_changing.connect(_cancel_screen_job)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# A freed node cannot await, so it cancels and joins its own screen job here.
	# `wait_for_worker` is idempotent, so the runner's own join never double-waits.
	var job := _screen_job
	_screen_job = null
	if job != null:
		job.cancel()
		job.wait_for_worker()
	State.finish_operation(_screen_operation_id)
	_screen_operation_id = 0
	_screen_document = null
	_screen_frame = null
	var tx := _edit
	_edit = null
	if tx != null:
		State.cancel_edit(tx)
	_release_context_subscriptions()


func _exit_tree() -> void:
	# A pending calculation keeps its own continuation and its context subscription,
	# so the detach does not cancel it. The plugin finalizes a held drag before it
	# removes this node. The streamed wand keeps its own policy. `tree_exited`
	# releases the context subscription once no calculation is pending.
	if _screen_job != null:
		return
	_cancel_screen_job()


# Release the context subscription only when no calculation is pending and the node
# is outside the tree. A pending job keeps it, so a frame or document change can
# still cancel its result.
func _release_context_subscriptions() -> void:
	if is_inside_tree() or _screen_job != null:
		return
	if State.edit_context_changing.is_connected(_cancel_screen_job):
		State.edit_context_changing.disconnect(_cancel_screen_job)


## Handles one input event. A left press starts a drag and a release commits it.
## Escape cancels the drag or clears the selection in Replace mode.
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


# A screen tool does not stream a selection. The wand overrides this.
## Returns [code]false[/code]. The wand overrides this.
func is_streaming() -> bool:
	return false


# Drop the shape a stopped drag was building. The box tool holds no shape state.
func _reset_shape() -> void:
	pass


# Stop a drag that still holds the pointer. The context changed under the drag, so
# the tool releases its own edit and drops the shape. The eventual release must
# not commit the stale drag.
func _stop_drag() -> void:
	_stroke_active = false
	_screen_press = Vector2.ZERO
	_reset_shape()
	$ScreenBand.hide_band()
	abort_stroke()


func _screen_button(event: InputEventMouseButton, pos: Vector2) -> bool:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false
	if event.pressed:
		if open_stroke() == null:
			return false
		_screen_press = pos
		_last_pos = pos
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
		_last_pos = pos
		_update_shape(pos)
		return true
	return false


# End a drag that a tool switch interrupted. The current outline applies as a
# release would, while the viewport and camera are still attached, and the pending
# calculation finishes after the detach. The streamed wand keeps its own policy.
## Ends a drag that a tool switch interrupted. The current outline applies as a
## release would.
func finish_on_switch() -> void:
	if is_streaming():
		return
	if _screen_job != null or not _stroke_active:
		return
	_stroke_active = false
	$ScreenBand.hide_band()
	_end()
	_commit_shape(_last_pos)


func _cancel_key(event: InputEventKey) -> bool:
	if not event.is_action_pressed("ui_cancel"):
		return false
	if _stroke_active:
		_stroke_active = false
		$ScreenBand.hide_band()
		_end()
	elif _settings.mode == _settings.SelectMode.REPLACE and not State.selection.is_empty():
		if open_stroke() == null:
			return true
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
	_screen_job.depth_test = _settings.depth_test
	_screen_job.previous_selection = State.selection.capture()
	var bounds := frame.get_bounds()
	# Empty cells need a finite volume. The frame bounds supply it.
	_screen_job.include_empty = _settings.include_empty and bounds.has_volume()
	_screen_job.empty_min = _cell_of(bounds.position + Vector3.ONE * 0.5)
	_screen_job.empty_max = _cell_of(bounds.end - Vector3.ONE * 0.5)
	var job := _screen_job
	var work := job.estimate_work(frame.count() + job.empty_cell_count() + State.selection.count())
	if work <= IMMEDIATE_LIMIT:
		job.run()
		_finish_screen_selection(job, _screen_operation_id)
		return
	# A large projection runs on the worker pool. The operation carries the cancel
	# callback, so Escape still cancels a job whose tool a switch detached. The
	# frozen view and source let the result finish after the detach.
	var operation_id := State.begin_operation("Selecting", work, true, self, _cancel_screen_job)
	_screen_operation_id = operation_id
	await State.run_edit_job(job, operation_id, "Screen selection")
	_finish_screen_selection(job, operation_id)


func _cell_of(point: Vector3) -> Vector3i:
	return Vector3i(floori(point.x + 0.5), floori(point.y + 0.5), floori(point.z + 0.5))


func _finish_screen_selection(job: ScreenSelection.Job, operation_id: int) -> void:
	# A cancel or a replacement owns the job now, so this result is dropped.
	if _screen_job != job:
		return
	_screen_job = null
	var document := _screen_document
	var frame := _screen_frame
	_screen_document = null
	_screen_frame = null
	if _screen_operation_id == operation_id:
		_screen_operation_id = 0
	if job.checkpoint(0) and State.document == document and State.get_current_voxel_frame() == frame:
		var tx := State.begin_edit()
		if tx != null:
			State.selection.restore(job.result)
			State.finish_edit(tx, "Screen selection")
			State.selection_changed.emit()
	State.finish_operation(operation_id)
	_release_context_subscriptions()


func _cancel_screen_job() -> void:
	if _screen_job:
		_screen_job.cancel()
	_screen_document = null
	_screen_frame = null
	# A context change also stops a Box or Lasso drag that still holds the pointer.
	# The wand keeps its streamed selection and finishes after the change.
	if not is_streaming():
		_stop_drag()
	State.finish_operation(_screen_operation_id)
	_screen_operation_id = 0
