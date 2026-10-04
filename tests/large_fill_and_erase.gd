extends "res://tests/test.gd"

var tool: Node
var source_frame: VoxelFrame
var notifications := 0
const DISTANT := Vector3i(64, 0, 0)


func _ready() -> void:
	timeout = 30.0
	test("large fill and erase preserve the selection, history, and edit context", _run)


func _run() -> void:
	step("Given a selected red block and a distant red voxel", func():
		State.document = VoxiDocument.new()
		source_frame = State.get_current_voxel_frame()
		for z in 20:
			for y in 20:
				for x in 20:
					var cell_position := Vector3i(x, y, z)
					source_frame.set_cell(cell_position, Color.RED)
					State.selection.add(cell_position)
		source_frame.set_cell(DISTANT, Color.RED)
		activate_tool("fill")
		tool = plugin("FillPlugin")._tool
		State.current_color = Color.BLUE
		State.chunks_changed.connect(func(_frame, _affected): notifications += 1)
	)
	step("When the user fills all matching voxels inside the selection", func():
		tool._settings.connected = false
		_fill()
	)
	await _settle_fill()
	step("Then the selected block changes in one undo action", func():
		expect(_selected_color(Color.BLUE), "all selected voxels take the fill color")
		expect(source_frame.get_color(DISTANT) == Color.RED, "the unselected matching voxel keeps its color")
		expect(notifications == 1, "the fill sends one edit notification")
		expect(State.selection.count() == 8000, "the fill preserves the selection")
		State.undo_redo.undo()
		expect(_selected_color(Color.RED), "undo restores all source colors")
		State.undo_redo.clear_history()
	)
	step("When the user cancels a fill and starts another fill", func():
		tool._settings.connected = true
		_fill()
		tool._interrupt_fill()
		State.current_color = Color.GREEN
		_fill()
	)
	await _settle_fill()
	step("Then the old fill cannot change the new result", func():
		expect(_selected_color(Color.GREEN), "the new fill color covers the connected block")
		expect(not State.edit_busy(), "the completed fill releases editing")
		State.undo_redo.undo()
		expect(_selected_color(Color.RED), "undo restores the block after the replacement fill")
		State.undo_redo.clear_history()
	)
	step("When the user switches tools during a fill", func():
		State.current_color = Color.BLUE
		_fill()
		activate_tool("Toolbar")
	)
	await _settle_fill()
	step("Then the fill completes and editing is available", func():
		expect(_selected_color(Color.BLUE), "tool switching completes the fill")
		expect(not State.edit_busy(), "tool switching releases the fill state")
	)
	step("When the user erases the large selection", func():
		State.erase_selection()
	)
	while State.edit_busy():
		await get_tree().process_frame
	step("Then only the unselected voxel remains", func():
		expect(source_frame.count() == 1, "erase preserves the unselected voxel")
		expect(source_frame.get_color(DISTANT) == Color.RED, "erase preserves the unselected color")
		State.undo_redo.undo()
		expect(source_frame.count() == 8001, "undo restores all erased voxels")
		expect(_selected_color(Color.BLUE), "undo restores the fill colors")
	)
	step("When the frame changes during a large erase", func():
		State.document.add_frame()
		State.erase_selection()
		State.current_frame = 1
	)
	while not State._erase_jobs.is_empty():
		await get_tree().process_frame
	step("Then both frames preserve their last completed state", func():
		expect(source_frame.count() == 8001, "the interrupted erase preserves the source frame")
		expect(State.get_current_voxel_frame().count() == 0, "the interrupted erase leaves the new frame empty")
		expect(not State.edit_busy(), "the interrupted erase releases editing")
	)
	step("When the document changes during a connected fill", func():
		State.current_frame = 0
		activate_tool("fill")
		State.current_color = Color.GREEN
		_fill()
		State.document = VoxiDocument.new()
	)
	await _settle_fill()
	step("Then the replacement document receives no old fill", func():
		expect(State.get_current_voxel_frame().count() == 0, "the replacement document stays empty")
		expect(not State.edit_busy(), "document replacement releases the fill state")
	)


func _fill() -> void:
	tool._release_pending = true
	tool._queue_seed(Vector3i.ZERO)


func _settle_fill() -> void:
	while not tool.is_settled() or not tool._search_jobs.is_empty():
		await get_tree().process_frame


func _selected_color(color: Color) -> bool:
	for cell_position in State.selection.all_cells():
		if source_frame.get_color(cell_position) != color:
			return false
	return true
