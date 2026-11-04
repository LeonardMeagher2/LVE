extends "res://tests/test.gd"

# Focused lifecycle tests for the line preview runner.
#
# The preview worker now awaits `State.run_edit_job`. These tests prove that a
# newer endpoint supersedes a running job, that a cancel, a detach, or a context
# change discards it, that one operation reports the progress, and that a later
# press still commits. The tests never measure time.
#
#   godot --path . res://tests/line_lifecycle.tscn
#
# A large selection pattern keeps the first preview on the worker. No frame runs
# between two pointer moves, so the running job is still the current job when the
# newer request arrives.

## The edge of the large selection pattern. A line of two or more centers then
## needs more than [constant StrokeTool.INLINE_EDIT_LIMIT] cells.
const PATTERN_EDGE := 17

var viewport: SubViewport
var tool
var settings
var _job
var _operation_id := 0


func _ready() -> void:
	timeout = 20.0
	test("a newer line endpoint supersedes the running preview worker", _supersede, "line_preview_supersede")
	test("a cancelled line preview leaves no status and a new press commits", _cancel_repress, "line_preview_cancel_repress")
	test("a tool switch discards the running line preview", _detach, "line_preview_detach")
	test("a context change discards the running line preview", _context_change, "line_preview_context")


func _setup_test() -> void:
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	State.clear_selection()
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.current_color = Color.RED
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true
	settings = plugin("BrushPlugin")._settings
	settings.shape = settings.BrushShape.CUBE
	settings.diameter = 1
	# Select the pencil first, so the line tool mounts again after a detach test.
	select_toolbar_item("Toolbar", "Pencil")
	select_toolbar_item("Toolbar", "Line")
	tool = plugin("BrushPlugin")._line_tool
	_job = null
	_operation_id = 0


func _supersede() -> void:
	step("Given a large selection brush and a pending line", func():
		_use_large_pattern()
		_click(Vector3.ZERO)
		_motion(Vector3(1, 0, 0))
		expect(tool._job != null, "the first endpoint starts a preview worker")
		expect(tool._operation_id != 0, "the preview reports one operation")
		_expect_one_foreground(tool._operation_id, tool)
	)
	step("When the user moves to a newer endpoint", func():
		_job = tool._job
		_operation_id = tool._operation_id
		_motion(Vector3(4, 0, 0))
		expect(tool._job == _job, "the newer request keeps the running job until it stops")
		expect(_job._cancel_requested, "the newer request cancels the running job")
		expect(tool._preview_requested, "the newest endpoint waits for the worker")
		expect(tool._preview_result == null, "the older preview is discarded at once")
		expect(State.has_operation(_operation_id), "the preview operation stays visible")
	)
	await _await_preview()
	step("Then only the newest preview is adopted under one operation", func():
		expect(tool._preview_result != null, "the newest preview is ready")
		expect(tool._preview_result.revision == tool._revision, "the adopted preview is the newest request")
		expect(tool._preview_result.centers.back() == Vector3i(4, 0, 0), "the adopted preview ends at the newest endpoint")
		expect(tool._operation_id == 0, "the finished preview clears its operation id")
		expect(not State.has_operation(_operation_id), "the preview finishes its operation")
		expect(not State.edit_busy(), "the finished preview releases the foreground status")
		expect(State.get_current_voxel_frame().count() == 0, "the preview writes no cell")
	)
	step("When the user commits the newest line", func():
		_key(KEY_ENTER)
	)
	step("Then the commit writes the newest endpoint as one action", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 6069, "the line writes the newest pattern once")
		expect(frame.has(Vector3i(12, 0, 0)), "the line reaches the newest brush cap")
		expect(frame.has(Vector3i(-8, 0, 0)), "the line starts at the first brush cap")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes the complete line")
		expect(not State.undo_redo.has_undo(), "the line creates one history action")
	)


func _cancel_repress() -> void:
	step("Given a running preview worker", func():
		_use_large_pattern()
		_click(Vector3.ZERO)
		_motion(Vector3(4, 0, 0))
		_job = tool._job
		_operation_id = tool._operation_id
		expect(_job != null, "the large line starts a preview worker")
		expect(State.has_operation(_operation_id), "the preview reports one operation")
	)
	step("When the user cancels with Escape", func():
		_key(KEY_ESCAPE)
		expect(_job._cancel_requested, "the cancel stops the preview worker")
		expect(not tool.visible, "the cancelled preview is hidden")
		expect(not State.has_operation(_operation_id), "the cancel finishes the preview operation")
		expect(tool._operation_id == 0, "the cancel clears the operation id")
	)
	await _await_job_clear()
	step("Then the cancelled worker publishes nothing", func():
		expect(tool._job == null, "the runner retires the cancelled job")
		expect(tool._preview_result == null, "the cancelled job adopts no preview")
		expect(State.get_current_voxel_frame().count() == 0, "the cancelled line leaves the document empty")
		expect(not State.edit_busy(), "the cancelled line releases the foreground status")
		expect(not State.undo_redo.has_undo(), "the cancelled line adds no history action")
	)
	step("When the user presses again with a small brush", func():
		settings.shape = settings.BrushShape.CUBE
		settings.diameter = 1
		_click(Vector3.ZERO)
		_motion(Vector3(4, 0, 0))
		_click(Vector3(4, 0, 0))
	)
	step("Then the new line commits once", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 5, "the new line contains five voxels")
		expect(frame.has(Vector3i.ZERO) and frame.has(Vector3i(4, 0, 0)), "the new line connects both endpoints")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes the new line")
		expect(not State.undo_redo.has_undo(), "the new line creates one history action")
	)


func _detach() -> void:
	step("Given a running preview worker", func():
		_use_large_pattern()
		_click(Vector3.ZERO)
		_motion(Vector3(4, 0, 0))
		_job = tool._job
		_operation_id = tool._operation_id
		expect(_job != null, "the large line starts a preview worker")
		expect(State.has_operation(_operation_id), "the preview reports one operation")
	)
	step("When the user switches to the pencil", func():
		select_toolbar_item("Toolbar", "Pencil")
		expect(_job._cancel_requested, "the detach cancels the preview worker")
		expect(not State.has_operation(_operation_id), "the detach finishes the preview operation")
		expect(tool._operation_id == 0, "the detach clears the operation id")
		expect(not State.edit_busy(), "the detach releases the foreground status")
		expect(State.get_current_voxel_frame().count() == 0, "the detach writes no cell")
		expect(not State.undo_redo.has_undo(), "the detach adds no history action")
	)
	await get_tree().process_frame
	step("Then the detached runner publishes nothing", func():
		expect(tool._job == null, "the detached runner retires its job")
		expect(tool._preview_result == null, "the detached runner adopts no preview")
	)


func _context_change() -> void:
	step("Given a running preview worker", func():
		_use_large_pattern()
		_click(Vector3.ZERO)
		_motion(Vector3(4, 0, 0))
		_job = tool._job
		_operation_id = tool._operation_id
		expect(_job != null, "the large line starts a preview worker")
		expect(State.has_operation(_operation_id), "the preview reports one operation")
	)
	step("When the selection changes", func():
		State.selection.add(Vector3i(2, 0, 0))
		State.selection_changed.emit()
		expect(_job._cancel_requested, "the context change cancels the preview worker")
		expect(not State.has_operation(_operation_id), "the context change finishes the preview operation")
		expect(tool._operation_id == 0, "the context change clears the operation id")
		expect(not tool.visible, "the context change hides the preview")
		expect(State.get_current_voxel_frame().count() == 0, "the context change writes no cell")
	)
	await _await_job_clear()
	step("Then the discarded worker publishes nothing", func():
		expect(tool._job == null, "the runner retires the discarded job")
		expect(tool._preview_result == null, "the discarded job adopts no preview")
		expect(not State.edit_busy(), "the context change releases the foreground status")
		expect(not State.undo_redo.has_undo(), "the context change adds no history action")
	)


# Builds a selection pattern above the inline limit. The line tool copies it at
# the start of a stroke.
func _use_large_pattern() -> void:
	var pattern := {}
	var materials := {}
	var half := PATTERN_EDGE / 2
	for x in range(-half, half + 1):
		for y in range(-half, half + 1):
			for z in range(-half, half + 1):
				var offset := Vector3i(x, y, z)
				pattern[offset] = Color.RED
				materials[offset] = VoxelFrame.material(Color.RED)
	settings.use_selection(pattern, materials)


func _await_preview() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while (tool._job != null or tool._preview_result == null or tool._preview_result.revision != tool._revision) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _await_job_clear() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while tool._job != null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


# Counts the foreground operations and checks that only the expected one runs.
func _expect_one_foreground(operation_id: int, owner: Node) -> void:
	var count := 0
	var matches := false
	for operation in State._operations.values():
		if not operation.foreground:
			continue
		count += 1
		matches = operation.id == operation_id and operation.owner_ref.get_ref() == owner
	expect(count == 1, "one foreground operation reports the preview")
	expect(matches, "the preview operation belongs to the line tool")


func _button(world: Vector3, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = camera_rig().unproject_position(world)
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(event)


func _click(world: Vector3) -> void:
	_button(world, true)
	_button(world, false)


func _motion(world: Vector3, pressed := false) -> void:
	var event := InputEventMouseMotion.new()
	event.position = camera_rig().unproject_position(world)
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(event)


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	viewport.push_input(event)
