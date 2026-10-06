extends "res://tests/test.gd"

var tool: Node
var source_frame: VoxelFrame
var pivot := Vector3(9.5, 9.5, 9.5)
const MARKER := Vector3i(-32, -16, 0)


func _ready() -> void:
	timeout = 30.0
	test("large edits keep the latest input and release their state after cancellation and context changes", _run)


func _run() -> void:
	step("Given a selected block and an unselected marker", _setup)
	_press()
	await _prepare()
	step("When the user replaces a large scale request before releasing the mouse", func():
		_motion(80)
		_motion(40)
		_release()
		tool._commit()
	)
	await _settle()
	step("Then the latest scale is exact and the marker stays unchanged", func():
		expect(source_frame.count() == 64001, "the final scale contains 64000 voxels and the marker")
		expect(State.selection.count() == 64000, "the selection follows the final scale")
		expect(source_frame.get_color(MARKER) == Color.GREEN, "the unselected marker keeps its color")
		State.undo_redo.undo()
		expect(source_frame.count() == 8001, "undo restores the source block and marker")
		expect(State.selection.count() == 8000, "undo restores the source selection")
	)
	step("Given another large source grab", func():
		State.undo_redo.clear_history()
		_press()
	)
	step("When the user cancels while the source is being prepared", func():
		tool._cancel()
	)
	await _settle()
	step("Then the source stays unchanged and editing is available", func():
		expect(source_frame.count() == 8001, "source preparation leaves the document unchanged")
		expect(not State.edit_busy(), "source cancellation releases editing")
		expect(not State.undo_redo.has_undo(), "source cancellation adds no history action")
	)
	_press()
	await _prepare()
	step("When the user cancels a running scale preview", func():
		_motion(80)
		tool._cancel()
	)
	await _settle()
	step("Then the cancelled preview cannot change the document", func():
		expect(source_frame.count() == 8001, "preview cancellation preserves the source block")
		expect(not State.edit_busy(), "preview cancellation releases editing")
	)
	_press()
	await _prepare()
	step("When the user changes frames during a running preview", func():
		State.document.add_frame()
		_motion(80)
		State.current_frame = 1
	)
	await _settle()
	step("Then the new frame receives no result from the old preview", func():
		expect(State.get_current_voxel_frame().count() == 0, "the new frame stays empty")
		expect(source_frame.count() == 8001, "the old frame keeps the last completed edit")
		expect(not State.edit_busy(), "the frame change releases editing")
		State.current_frame = 0
	)
	step("When the user switches tools while preparing a scale", func():
		_press()
		_motion(40)
		_release()
		activate_tool("Toolbar")
	)
	await _settle()
	step("Then the requested scale commits and the next tool can edit", func():
		expect(source_frame.count() == 64001, "tool switching completes the requested scale")
		expect(State.undo_redo.has_undo(), "tool switching records the completed scale")
		expect(not State.edit_busy(), "tool switching releases editing")
		State.undo_redo.undo()
	)
	step("When the user replaces the document during source preparation", func():
		activate_tool("transform")
		select_toolbar_item("transform", "Scale")
		_press()
		State.document = VoxiDocument.new()
	)
	await _settle()
	step("Then the replacement document stays empty", func():
		expect(State.get_current_voxel_frame().count() == 0, "the replacement document receives no old edit")
		expect(not State.edit_busy(), "document replacement releases editing")
	)


func _setup() -> void:
	State.document = VoxiDocument.new()
	source_frame = State.get_current_voxel_frame()
	for z in 20:
		for y in 20:
			for x in 20:
				var cell_position := Vector3i(x, y, z)
				source_frame.set_cell(cell_position, Color.RED)
				State.selection.add(cell_position)
	source_frame.set_cell(MARKER, Color.GREEN)
	camera_rig().set_view("front")
	activate_tool("transform")
	select_toolbar_item("transform", "Scale")
	tool = plugin("TransformPlugin")._current_tool


func _press() -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	tool.handle_input(event, camera_rig().unproject_position(pivot + Vector3(20, 20, 0)))


func _motion(offset: float) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	tool.handle_input(event, camera_rig().unproject_position(pivot + Vector3(offset, offset, 0)))


func _release() -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	tool.handle_input(event, Vector2.ZERO)


func _prepare() -> void:
	while tool._grab_waiting:
		await get_tree().process_frame


func _settle() -> void:
	while not tool.is_settled():
		await get_tree().process_frame
