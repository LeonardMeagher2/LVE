extends "res://tests/test.gd"

var line_tool: Node
var brush_tool: Node
var options: Control
var frame: VoxelFrame
var tick_count := 0


func _ready() -> void:
	timeout = 30.0
	test("large strokes retain the latest endpoint and release editing after cancellation and context changes", _run)


func _run() -> void:
	step("Given a cube line brush with a diameter of seventeen", func():
		select_toolbar_item("Toolbar", "Line")
		line_tool = plugin("BrushPlugin")._line_tool
		brush_tool = plugin("BrushPlugin")._brush_tool
		options = plugin("BrushPlugin")._options
		_empty()
		options.get_node("Diameter").value = 17
	)
	step("When the user changes a large hover brush twice", func():
		_hover(Vector3.ZERO)
		options.get_node("Diameter").value = 19
		options.get_node("Diameter").value = 17
		expect(not State.edit_busy(), "the hover preview permits editing")
	)
	while line_tool._hover_job or not line_tool.get_node("Cursor").is_settled():
		await get_tree().process_frame
	step("Then the preview uses the latest diameter without painting", func():
		expect(line_tool.get_node("Cursor").mesh.get_aabb().size == Vector3.ONE * 17, "the hover preview has the latest cube dimensions")
		expect(frame.count() == 0, "the hover preview leaves the document empty")
	)
	step("When the user replaces a long endpoint and releases the mouse", func():
		_button(line_tool, Vector3.ZERO, true)
		_motion(line_tool, Vector3(128, 0, 0))
		_motion(line_tool, Vector3(64, 0, 0))
		_button(line_tool, Vector3(64, 0, 0), false)
		expect(State.edit_busy(), "the large line reports foreground work")
		expect(frame.count() == 0, "the running line leaves the document unchanged")
	)
	await _settle(line_tool)
	step("Then the latest line commits once while the editor continues processing", func():
		expect(tick_count > 0, "the editor processes frames during line preparation")
		expect(frame.count() == 23409, "the final line contains the latest endpoint and cube volume")
		expect(frame.has(Vector3i(72, 8, 8)), "the line reaches the latest cube brush cap")
		expect(not frame.has(Vector3i(73, 0, 0)), "the superseded endpoint leaves no voxels")
		expect(not State.edit_busy(), "the completed line releases editing")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes the complete large line")
		expect(not State.undo_redo.has_undo(), "the large line creates one history action")
		State.undo_redo.redo()
		expect(frame.count() == 23409, "one redo restores the complete large line")
	)
	step("When the user cancels another running line", func():
		_empty()
		_button(line_tool, Vector3.ZERO, true)
		_motion(line_tool, Vector3(128, 0, 0))
		_key(line_tool, KEY_ESCAPE)
	)
	await _settle(line_tool)
	step("Then no cancelled result changes the document", func():
		expect(frame.count() == 0, "the cancelled line leaves the frame empty")
		expect(not State.edit_busy(), "line cancellation releases editing")
		expect(not State.undo_redo.has_undo(), "line cancellation adds no history action")
	)
	step("When the user changes frames while preparing a line", func():
		State.document.add_frame()
		_button(line_tool, Vector3.ZERO, true)
		_motion(line_tool, Vector3(128, 0, 0))
		_button(line_tool, Vector3(128, 0, 0), false)
		State.current_frame = 1
	)
	await _settle(line_tool)
	step("Then both frames remain unchanged", func():
		expect(frame.count() == 0, "the source frame stays empty")
		expect(State.get_current_voxel_frame().count() == 0, "the new frame receives no old line")
		expect(not State.edit_busy(), "the frame change releases editing")
	)
	step("When the user switches tools during a running line", func():
		_empty()
		_button(line_tool, Vector3.ZERO, true)
		_motion(line_tool, Vector3(128, 0, 0))
		select_toolbar_item("Toolbar", "Pencil")
	)
	step("Then switching tools discards the running preview", func():
		expect(frame.count() == 0, "the discarded line leaves the frame empty")
		expect(not State.edit_busy(), "tool switching releases editing")
		expect(not State.undo_redo.has_undo(), "the discarded line adds no history action")
	)
	step("Given a selected volume with two colors", func():
		_empty()
		options = plugin("BrushPlugin")._options
		for z in 18:
			for y in 18:
				for x in 18:
					frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.RED if x < 9 else Color.BLUE))
		State.selection.from_box(Vector3i.ZERO, Vector3i(17, 17, 17))
		State.selection_changed.emit()
	)
	step("When the user copies the large selection as a brush", func():
		options.get_node("Shape/Selection").pressed.emit()
		expect(State.edit_busy(), "copying a large brush reports foreground work")
	)
	while options._source_job:
		await get_tree().process_frame
	step("Then the brush is available and its source is unchanged", func():
		expect(options.get_node("Shape/Selection").button_pressed, "the copied volume becomes the brush shape")
		expect(frame.count() == 5832, "copying preserves all source voxels")
		expect(State.selection.count() == 5832, "copying preserves the source selection")
		expect(not State.edit_busy(), "copying releases editing")
		State.clear_selection()
		frame.clear()
	)
	step("When the user drags the copied brush before its first stamp completes", func():
		_button(brush_tool, Vector3.ZERO, true)
		_motion(brush_tool, Vector3(2, 0, 0))
		_motion(brush_tool, Vector3(4, 0, 0))
		_button(brush_tool, Vector3(4, 0, 0), false)
		expect(State.edit_busy(), "the large copied stroke reports foreground work")
	)
	await _settle(brush_tool)
	step("Then the queued drag stays connected and supports one undo", func():
		expect(frame.count() == 7128, "the complete copied stroke contains a connected volume")
		expect(frame.get_color(Vector3i(-8, 0, 0)) == Color.RED, "the first brush cap keeps its red color")
		expect(frame.get_color(Vector3i(13, 0, 0)) == Color.BLUE, "the last brush cap keeps its blue color")
		expect(not State.edit_busy(), "the copied stroke releases editing")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes the complete copied stroke")
		expect(not State.undo_redo.has_undo(), "the copied stroke creates one history action")
	)
	step("When the user cancels a copied stroke during preparation", func():
		State.undo_redo.clear_history()
		_button(brush_tool, Vector3.ZERO, true)
		_motion(brush_tool, Vector3(8, 0, 0))
		_key(brush_tool, KEY_ESCAPE)
	)
	await _settle(brush_tool)
	step("Then the copied stroke leaves no edit or busy state", func():
		expect(frame.count() == 0, "the cancelled copied stroke leaves the frame empty")
		expect(not State.edit_busy(), "copied stroke cancellation releases editing")
		expect(not State.undo_redo.has_undo(), "the cancelled copied stroke adds no history action")
	)


func _empty() -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	State.floor_axis = Vector3.Axis.AXIS_Y
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true
	State.current_color = Color.RED


func _button(tool: Node, world: Vector3, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	tool.handle_input(event, camera_rig().unproject_position(world))


func _motion(tool: Node, world: Vector3) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	tool.handle_input(event, camera_rig().unproject_position(world))


func _hover(world: Vector3) -> void:
	var event := InputEventMouseMotion.new()
	line_tool.handle_input(event, camera_rig().unproject_position(world))


func _key(tool: Node, code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	tool.handle_input(event, Vector2.ZERO)


func _settle(tool: Node) -> void:
	tick_count = 0
	while tool._job or tool._stroke_open or (tool == line_tool and (line_tool._preview_requested or line_tool._commit_requested)):
		tick_count += 1
		await get_tree().process_frame
