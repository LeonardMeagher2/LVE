extends "res://tests/test.gd"

# The transform tool prepares its source and its preview on the worker pool when
# the work passes INLINE_EDIT_LIMIT. The shared helper `State.run_edit_job`
# launches, pumps, and joins that worker. The 1000-voxel fixture in
# transform_large_selection stays inline, so these tests use a larger block and
# drive the worker branch.

const INLINE_LIMIT := 4096
const BLOCK_X := 32
const BLOCK_Y := 16
const BLOCK_Z := 16
const BLOCK_COUNT := BLOCK_X * BLOCK_Y * BLOCK_Z
const MOVE_TOOL_SCENE := preload("res://plugins/Transform/tools/MoveTool.tscn")

var viewport: SubViewport
var _originals_captured := false
var _original_size := Vector2i.ZERO
var _original_stretch := true
var _mouse_held := false
var _last_mouse_pos := Vector2.ZERO
var _defaults_ready := false
var _default_tool := 0
var _default_snap := true
var _default_uniform := true
var _material := PackedFloat32Array()
var _baseline := {}


# A short job that finishes after the helper pumps at least one frame.
class ProbeJob extends VoxelFrame.EditJob:
	var steps := 0

	func run() -> void:
		stage("Probe", 4)
		for i in 4:
			steps = i + 1
			checkpoint(steps)
			OS.delay_msec(2)


# A job that keeps running until its cancel flag is set, so the test can join it
# from the main thread while the helper still awaits it.
class BlockingJob extends VoxelFrame.EditJob:
	func run() -> void:
		stage("Blocking", 100)
		for i in 100:
			if not checkpoint(i):
				return
			OS.delay_msec(1)


func _ready() -> void:
	timeout = 30.0
	test("the edit-job helper clears the worker id after a normal join", _helper_clears_id, "edit_job_helper_join")
	test("an external join before the helper resumes does not join the task twice", _helper_external_join, "edit_job_helper_external_join")
	test("wait_for_worker retires a finished worker without cancelling it", _wait_for_worker_normal, "wait_for_worker_normal")
	test("wait_for_worker is a no-op on a retired or never-launched job", _wait_for_worker_noop, "wait_for_worker_noop")
	test("wait_for_worker keeps a cancelled job cancelled", _wait_for_worker_cancel, "wait_for_worker_cancel")
	test("a large transform prepares and previews on the worker and commits", _worker_commit, "transform_worker_commit")
	test("cancelling a large transform during the worker restores the source", _worker_cancel, "transform_worker_cancel")
	test("a frame change during a large transform prepare aborts it cleanly", _worker_context_change, "transform_worker_context_change")
	test("switching tools during a large transform prepare commits with no leftover worker", _worker_detach_commit, "transform_worker_detach_commit")
	test("a release queued before the prepare completes opens the move dialog", _worker_queued_release, "transform_worker_queued_release")
	test("rapid preview replacement joins its workers and keeps the last offset", _worker_preview_replacement, "transform_worker_preview_replacement")
	test("deleting an isolated tool joins its running worker and skips a disposed one", _worker_deletion, "transform_worker_deletion")


func before_test() -> void:
	_capture_originals_once()
	_release_held_press()
	_stop_pending_transform()
	State.stop()
	State.current_frame = 0
	State.active_tag = 0
	State.selection.clear()
	State.undo_redo.clear_history()
	State.document = VoxelDocument.new()
	_reset_transform_settings()
	camera_rig().set_view("front")
	camera_rig().is_orthogonal = false
	while State.get_activity() != null:
		State.finish_operation(State.get_activity().id)
	await get_tree().process_frame


# Leave no worker or open stroke behind, so a test can run alone or in any order.
func after_test() -> void:
	_release_held_press()
	_stop_pending_transform()
	var tool := _tool()
	for i in 600:
		if tool == null or (not tool._grab_waiting and not tool._preview_running and tool._jobs.is_empty()):
			break
		await get_tree().process_frame
	while State.get_activity() != null:
		State.finish_operation(State.get_activity().id)
	await get_tree().process_frame
	_restore_view_state()


func _helper_clears_id() -> void:
	var job := ProbeJob.new()
	var operation_id := State.begin_operation("Probe", -1, true, self)
	step("Given a probe job with a foreground operation", func():
		expect(job.worker_task_id == -1, "the probe job starts without a worker")
		expect(State.has_operation(operation_id), "the probe operation is registered")
	)
	await State.run_edit_job(job, operation_id, "Probe")
	step("Then the helper cleared the worker id after the join", func():
		expect(job.worker_task_id == -1, "the helper clears the worker id after the join")
		expect(job.steps == 4, "the probe job ran to completion")
	)
	step("When the caller finishes the operation", func():
		State.finish_operation(operation_id)
	)
	step("Then no activity remains", func():
		expect(State.get_activity() == null, "the probe leaves no activity")
	)


func _helper_external_join() -> void:
	var job := BlockingJob.new()
	var operation_id := State.begin_operation("Blocking", -1, true, self)
	State.run_edit_job(job, operation_id, "Blocking")
	step("Given a blocking job on the worker", func():
		expect(job.worker_task_id >= 0, "the helper launched the worker")
		expect(not WorkerThreadPool.is_task_completed(job.worker_task_id), "the blocking worker is still running")
	)
	step("When an external owner cancels and retires it before the helper resumes", func():
		job.cancel()
		job.wait_for_worker()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the helper stopped without joining the disposed task again", func():
		expect(job.worker_task_id == -1, "the helper leaves the cleared worker id")
	)
	step("When the owner waits once more", func():
		job.wait_for_worker()
	)
	step("Then the retired worker id stays clear", func():
		expect(job.worker_task_id == -1, "a wait after retirement is a no-op")
	)
	step("When the caller finishes the operation", func():
		State.finish_operation(operation_id)
	)


# `wait_for_worker` owns the wait and the id retirement only. It never cancels,
# so a completed job stays uncancelled for its caller's publication checkpoint.
func _wait_for_worker_normal() -> void:
	var job := ProbeJob.new()
	step("Given a probe job launched on the worker", func():
		job.worker_task_id = WorkerThreadPool.add_task(job.run, true, "Wait probe")
		expect(job.worker_task_id >= 0, "the probe worker is registered")
	)
	step("When the owner waits for the worker", func():
		job.wait_for_worker()
	)
	step("Then the worker is retired and the job was not cancelled", func():
		expect(job.worker_task_id == -1, "wait_for_worker clears the worker id")
		expect(job.steps == 4, "the probe job ran to completion")
		expect(job.checkpoint(0), "wait_for_worker does not cancel the job")
	)


func _wait_for_worker_noop() -> void:
	var fresh := ProbeJob.new()
	step("Given a job that was never launched", func():
		expect(fresh.worker_task_id == -1, "the fresh job holds no worker")
	)
	step("When the owner waits on it", func():
		fresh.wait_for_worker()
	)
	step("Then the wait is a no-op", func():
		expect(fresh.worker_task_id == -1, "a never-launched job keeps no worker id")
	)
	var job := ProbeJob.new()
	step("Given a finished worker that was already retired", func():
		job.worker_task_id = WorkerThreadPool.add_task(job.run, true, "Wait noop")
		job.wait_for_worker()
		expect(job.worker_task_id == -1, "the first wait retires the worker")
	)
	step("When the owner waits again", func():
		job.wait_for_worker()
	)
	step("Then the repeated wait is a no-op", func():
		expect(job.worker_task_id == -1, "the repeated wait leaves the retired id")
	)


func _wait_for_worker_cancel() -> void:
	var job := BlockingJob.new()
	step("Given a blocking job on the worker", func():
		job.worker_task_id = WorkerThreadPool.add_task(job.run, true, "Wait cancel")
		expect(not WorkerThreadPool.is_task_completed(job.worker_task_id), "the blocking worker is still running")
	)
	step("When the owner cancels and then waits", func():
		job.cancel()
		job.wait_for_worker()
	)
	step("Then the wait retires the worker but keeps the cancel request", func():
		expect(job.worker_task_id == -1, "the wait retires the worker id")
		expect(not job.checkpoint(0), "the cancelled job stays cancelled")
	)


func _worker_commit() -> void:
	step("Given a selected block larger than the inline limit with the move tool active", func():
		_view_setup()
		_paint_block()
		_select_block()
		_baseline = _frame_cells(_frame())
		activate_tool("transform")
		expect(_frame().count() > INLINE_LIMIT, "the fixture exceeds the inline edit limit")
	)
	step("When the user drags the block two voxels and releases", func():
		_drag_voxels(Vector3i(2, 0, 0))
	)
	await _settle()
	step("Then the worker preview leaves the move pending", func():
		expect(_tool()._pending, "the worker preview leaves the move pending")
		expect(_frame_cells(_frame()) == _expected_block(Vector3i(2, 0, 0)), "the preview translates every cell with its material")
	)
	step("When the user commits the move", func():
		_press_option("Commit")
	)
	step("Then the committed move is one exact translation with no leftover worker", func():
		expect(_frame_cells(_frame()) == _expected_block(Vector3i(2, 0, 0)), "the committed move translates every cell with its material")
		expect(State.selection.all_cells() == _block_selection(Vector3i(2, 0, 0)), "the committed move tracks the selection")
		expect(State.undo_redo.has_undo(), "the committed move is undoable")
		expect(_tool()._jobs.is_empty(), "the transform joins every worker")
		expect(not State.edit_busy(), "the transform releases editing")
		expect(_transform_operation_count() == 0, "the transform leaves no operation of its own")
	)
	step("When the user undoes the move", func():
		State.undo_redo.undo()
	)
	step("Then the source frame and selection return exactly", func():
		expect(_frame_cells(_frame()) == _baseline, "undo restores the frozen source frame")
		expect(_frame_cells(_frame()) == _expected_block(Vector3i.ZERO), "undo restores every source cell with its material")
		expect(State.selection.all_cells() == _block_selection(Vector3i.ZERO), "undo restores the source selection")
		expect(not State.undo_redo.has_undo(), "the move was the only undo step")
	)
	step("When the user redoes the move", func():
		State.undo_redo.redo()
	)
	step("Then the translated frame and selection return exactly", func():
		expect(_frame_cells(_frame()) == _expected_block(Vector3i(2, 0, 0)), "redo restores every translated cell with its material")
		expect(State.selection.all_cells() == _block_selection(Vector3i(2, 0, 0)), "redo restores the translated selection")
	)


func _worker_cancel() -> void:
	step("Given a selected block larger than the inline limit with the move tool active", func():
		_view_setup()
		_paint_block()
		_select_block()
		activate_tool("transform")
	)
	step("When the user presses the block and cancels while the source prepares", func():
		_press_block()
		expect(_tool()._grab_waiting, "the source preparation holds the grab")
		_tool()._cancel()
	)
	await _settle()
	step("Then the block and selection return to the origin with no history", func():
		expect(_frame_cells(_frame()) == _expected_block(Vector3i.ZERO), "cancelling keeps every source cell with its material")
		expect(State.selection.all_cells() == _block_selection(Vector3i.ZERO), "cancelling restores the source selection")
		expect(not State.undo_redo.has_undo(), "cancelling adds no undo step")
		expect(_tool()._jobs.is_empty(), "cancelling joins the worker")
		expect(not State.edit_busy(), "cancelling releases editing")
		expect(_transform_operation_count() == 0, "cancelling leaves no operation of its own")
	)


func _worker_context_change() -> void:
	step("Given a selected block larger than the inline limit with the move tool active", func():
		_view_setup()
		_paint_block()
		_select_block()
		activate_tool("transform")
	)
	step("When the user presses the block and adds a frame while the source prepares", func():
		_press_block()
		expect(_tool()._grab_waiting, "the source preparation holds the grab")
		State.add_frame()
	)
	await _settle()
	step("Then the preparation aborts with the source frame intact", func():
		expect(State.document.frames.size() == 2, "the frame change added a frame")
		expect(_frame().count() == BLOCK_COUNT, "the source frame keeps every voxel")
		expect(_tool()._jobs.is_empty(), "the aborted preparation joins the worker")
		expect(not State.edit_busy(), "the aborted preparation releases editing")
		expect(_transform_operation_count() == 0, "the aborted preparation leaves no operation of its own")
	)


func _worker_detach_commit() -> void:
	step("Given a selected block larger than the inline limit with the move tool active", func():
		_view_setup()
		_paint_block()
		_select_block()
		activate_tool("transform")
	)
	step("When the user presses the block and switches to the brush while the source prepares", func():
		_press_block()
		expect(_tool()._grab_waiting, "the source preparation holds the grab")
		activate_tool("Toolbar")
	)
	await _settle()
	step("Then the detached tool commits without a leftover worker", func():
		expect(_frame().count() == BLOCK_COUNT, "the detached commit keeps every voxel")
		expect(_tool()._jobs.is_empty(), "the detached tool joins the worker")
		expect(not State.edit_busy(), "the detached commit releases editing")
		expect(_transform_operation_count() == 0, "the detached commit leaves no operation of its own")
	)


func _worker_queued_release() -> void:
	step("Given a selected block larger than the inline limit with the move tool active", func():
		_view_setup()
		_paint_block()
		_select_block()
		activate_tool("transform")
	)
	step("When the user presses and releases the block before the source prepares", func():
		var center := camera_rig().unproject_position(_current_center())
		_mouse_button(center, true)
		_mouse_button(center, false)
	)
	await _settle()
	step("Then the queued release opens the move dialog with no leftover worker", func():
		expect(_tool()._pending, "the queued release opens the move dialog")
		expect(_frame().count() == BLOCK_COUNT, "the queued release keeps every voxel")
		expect(_tool()._jobs.is_empty(), "the queued release joins the worker")
		expect(not State.edit_busy(), "the queued release releases editing")
	)
	step("When the user cancels the dialog", func():
		_tool()._cancel()
	)
	step("Then the block keeps its source cells", func():
		expect(_frame().count() == BLOCK_COUNT, "cancelling the dialog keeps every voxel")
		expect(State.selection.count() == BLOCK_COUNT, "cancelling the dialog keeps the selection")
	)


func _worker_preview_replacement() -> void:
	step("Given a selected block larger than the inline limit with the move tool active", func():
		_view_setup()
		_paint_block()
		_select_block()
		activate_tool("transform")
	)
	step("When the user presses the block", func():
		_press_block()
	)
	await _await_dragging()
	step("When the user drags the block twice before the first preview finishes", func():
		var first := camera_rig().unproject_position(_current_center() + Vector3(2, 0, 0))
		_mouse_motion(first)
		expect(_tool()._preview_running, "the first preview runs on the worker")
		expect(_tool()._jobs.size() == 1, "the first preview registers one worker")
		var second := camera_rig().unproject_position(_current_center() + Vector3(5, 0, 0))
		_mouse_motion(second)
		expect(_tool()._jobs.size() == 1, "the replaced preview registers no second worker")
		_mouse_button(second, false)
	)
	await _settle()
	step("Then the last offset wins and no history exists yet", func():
		expect(_tool()._jobs.is_empty(), "the replaced previews join their workers")
		expect(_tool()._pending, "the replaced previews leave the move pending")
		expect(_frame_cells(_frame()) == _expected_block(Vector3i(5, 0, 0)), "the stale first preview is not published")
		expect(not State.undo_redo.has_undo(), "the pending preview adds no history")
	)
	step("When the user commits", func():
		_press_option("Commit")
	)
	step("Then one undo step holds the last offset", func():
		expect(_frame_cells(_frame()) == _expected_block(Vector3i(5, 0, 0)), "the committed move keeps the last offset")
		expect(State.undo_redo.has_undo(), "the committed move is undoable")
	)
	step("When the user undoes and redoes the move", func():
		State.undo_redo.undo()
		expect(_frame_cells(_frame()) == _expected_block(Vector3i.ZERO), "undo restores the source cells")
		State.undo_redo.redo()
	)
	step("Then the translated frame returns", func():
		expect(_frame_cells(_frame()) == _expected_block(Vector3i(5, 0, 0)), "redo restores the translated cells")
	)


# The tool deletion joins its own worker. An isolated tool instance keeps the
# editor's shared transform tool out of the deletion.
func _worker_deletion() -> void:
	var tool: Node = MOVE_TOOL_SCENE.instantiate()
	var running := BlockingJob.new()
	var disposed := ProbeJob.new()
	step("Given an isolated tool that holds a running worker and a disposed worker", func():
		running.worker_task_id = WorkerThreadPool.add_task(running.run, true, "Transform delete probe")
		tool._jobs.append(running)
		disposed.worker_task_id = WorkerThreadPool.add_task(disposed.run, true, "Transform delete probe done")
		disposed.wait_for_worker()
		tool._jobs.append(disposed)
		expect(running.worker_task_id >= 0, "the running worker is registered")
		expect(disposed.worker_task_id == -1, "the disposed worker holds no task id")
	)
	step("When the tool is deleted while its worker runs", func():
		tool.free()
	)
	step("Then the deletion joined the running worker and skipped the disposed one", func():
		expect(running.worker_task_id == -1, "the deletion cleared the joined worker id")
	)


# Wait until the tool holds no grab, no preview, and no worker, and the operation
# is finished. A bounded loop keeps a stalled worker from hanging the test.
func _settle() -> void:
	var tool := _tool()
	for i in 900:
		if tool != null and not tool._grab_waiting and not tool._preview_running and tool._jobs.is_empty() and not State.edit_busy():
			break
		await get_tree().process_frame


func _await_dragging() -> void:
	var tool := _tool()
	for i in 900:
		if tool != null and tool._dragging and not tool._grab_waiting:
			break
		await get_tree().process_frame


func _view_setup() -> void:
	viewport = editor_viewport()
	var container := viewport.get_parent()
	container.stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().set_view("front")


func _paint_block() -> void:
	_material = VoxelFrame.material(Color.from_rgba8(200, 60, 60))
	var cells := {}
	for x in BLOCK_X:
		for y in BLOCK_Y:
			for z in BLOCK_Z:
				cells[Vector3i(x, y, z)] = _material
	_frame().set_cells(cells)
	State.document._bounds_dirty = true
	camera_rig().configure()


func _select_block() -> void:
	State.selection.clear()
	State.selection.from_box(Vector3i.ZERO, Vector3i(BLOCK_X - 1, BLOCK_Y - 1, BLOCK_Z - 1))
	State.selection_changed.emit()


# Every occupied cell with its full nine-float material, so two frames compare by
# content instead of by chunk id or table order.
func _frame_cells(frame: VoxelFrame) -> Dictionary:
	var cells := {}
	for position in frame.positions():
		cells[position] = frame.get_material(position)
	return cells


func _expected_block(offset: Vector3i) -> Dictionary:
	var cells := {}
	for x in BLOCK_X:
		for y in BLOCK_Y:
			for z in BLOCK_Z:
				cells[Vector3i(x, y, z) + offset] = _material
	return cells


func _block_selection(offset: Vector3i) -> Dictionary:
	var cells := {}
	for x in BLOCK_X:
		for y in BLOCK_Y:
			for z in BLOCK_Z:
				cells[Vector3i(x, y, z) + offset] = true
	return cells


func _frame() -> VoxelFrame:
	return State.document.frames[0]


func _current_center() -> Vector3:
	return _frame().get_bounds().get_center()


func _press_block() -> void:
	_mouse_button(camera_rig().unproject_position(_current_center()), true)


func _drag_voxels(off: Vector3i) -> void:
	var center := _current_center()
	_mouse_button(camera_rig().unproject_position(center), true)
	_mouse_motion(camera_rig().unproject_position(center + Vector3(off)))
	_mouse_button(camera_rig().unproject_position(center + Vector3(off)), false)


func _mouse_button(pos: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = pos
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(event)
	_mouse_held = pressed
	_last_mouse_pos = pos


func _mouse_motion(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(event)
	_last_mouse_pos = pos


func _tool() -> Node:
	var p: Node = plugin("TransformPlugin")
	if p == null:
		return null
	var tool: Node = p._current_tool
	return tool


# The transform tool owns its preparation and preview operations. Background
# renderer operations ("Rendering") are separate work, so this counts
# only the operations whose owner is the transform tool.
func _transform_operation_count() -> int:
	var tool := _tool()
	if tool == null:
		return 0
	var count := 0
	for operation in State._operations.values():
		if operation.owner_ref and operation.owner_ref.get_ref() == tool:
			count += 1
	return count


func _press_option(tooltip: String) -> void:
	var b := _find_option_button(tooltip)
	if b != null:
		b.pressed.emit()


func _capture_originals_once() -> void:
	if _originals_captured:
		return
	var vp := editor_viewport()
	_original_size = vp.size
	_original_stretch = vp.get_parent().stretch
	_originals_captured = true


# The transform settings live in a shared Resource. Reset the tool and the
# toggles so a test never inherits the previous test's choice.
func _reset_transform_settings() -> void:
	var p := plugin("TransformPlugin")
	if p == null:
		return
	if not _defaults_ready:
		_default_tool = p._settings.tool
		_default_snap = p._settings.snap
		_default_uniform = p._settings.uniform
		_defaults_ready = true
	p._settings.tool = _default_tool
	p._settings.snap = _default_snap
	p._settings.uniform = _default_uniform
	p._settings.transforming = false


func _release_held_press() -> void:
	if not _mouse_held:
		return
	_mouse_button(_last_mouse_pos, false)


# Cancel a transform that a test left mid-drag or pending. The tool clears its
# grab and restores the source shape, so the next test starts clean.
func _stop_pending_transform() -> void:
	var tool := _tool()
	if tool != null and (tool._dragging or tool._pending):
		tool._cancel()


func _restore_view_state() -> void:
	var vp := editor_viewport()
	if _originals_captured:
		# Restore the size while stretch is off, then put the original stretch back.
		var container := vp.get_parent()
		container.stretch = false
		vp.size = _original_size
		container.stretch = _original_stretch
	camera_rig().set_view("default")
	camera_rig().is_orthogonal = false
