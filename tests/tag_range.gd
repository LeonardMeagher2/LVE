extends "res://tests/test.gd"


func _ready() -> void:
	timeout = 20.0
	test("can drag a tag's start and end frame on the timeline", _run)


func _grid() -> Node:
	return main.find_child("FrameGrid", true, false)


func _range_cells() -> Array:
	var out: Array = []
	for child in _grid().get_children():
		if not child is AnimationFrame:
			out.append(child)
	return out


func _frame_cells() -> Array:
	var out: Array = []
	for child in _grid().get_children():
		if child is AnimationFrame:
			out.append(child)
	return out


func _drag_to(cell: Node, target: Node, release: bool = true) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = _local(cell, cell.get_global_rect().get_center())
	cell._gui_input(press)
	var motion := InputEventMouseMotion.new()
	motion.position = _local(cell, target.get_global_rect().get_center())
	cell._gui_input(motion)
	if release:
		_release_at(cell, target)


func _release_at(cell: Node, target: Node) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = _local(cell, target.get_global_rect().get_center())
	cell._gui_input(event)


# _gui_input receives pointer positions local to the cell.
func _local(cell: Node, point: Vector2) -> Vector2:
	return cell.get_global_transform().affine_inverse() * point


func _run() -> void:
	step("Given four frames and the default tag over all of them", func():
		State.add_frame()
		State.add_frame()
		State.add_frame()
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the range row sits above the frames", func():
		var grid := _grid()
		expect(grid.get_child_count() == 8, "the grid holds the range row and the frames")
		expect(_range_cells().size() == 4, "four range cells are shown")
		expect(_frame_cells().size() == 4, "four frame cells are shown")
	)

	step("When the user drags the end grip to frame three", func():
		var cells := _range_cells()
		_drag_to(cells[3], cells[2])
	)

	step("Then the tag ends on frame three", func():
		expect(State.document.tags[0].to == 2, "the tag ends on the third frame")
		expect(_range_cells()[2].get_node("%EndGrip").tooltip_text == "End frame 3", "the end grip identifies frame three")
	)

	step("When the user drags the start grip to frame two", func():
		var cells := _range_cells()
		_drag_to(cells[0], cells[1])
	)

	step("Then the tag starts on frame two", func():
		expect(State.document.tags[0].from == 1, "the tag starts on the second frame")
		expect(_range_cells()[1].get_node("%StartGrip").tooltip_text == "Start frame 2", "the start grip identifies frame two")
	)

	step("When the user undoes the range drags", func():
		State.undo_redo.undo()
		expect(State.document.tags[0].from == 0, "undo restores the first frame")
		expect(State.document.tags[0].to == 2, "undo preserves the previous end-grip drag")
		State.undo_redo.undo()
	)

	step("Then the tag range returns to all frames", func():
		expect(State.document.tags[0].from == 0, "the tag starts on the first frame")
		expect(State.document.tags[0].to == 3, "the tag ends on the last frame")
	)

	step("When the user redoes the range drags", func():
		State.undo_redo.redo()
		expect(State.document.tags[0].from == 0, "redo preserves the original start frame")
		expect(State.document.tags[0].to == 2, "redo restores the end-grip drag")
		State.undo_redo.redo()
	)

	step("Then the tag range is trimmed again", func():
		expect(State.document.tags[0].from == 1, "the tag starts on the second frame")
		expect(State.document.tags[0].to == 2, "the tag ends on the third frame")
	)

	step("When the user plays the tag and drags the end grip to frame four", func():
		State.current_frame = 1
		State.is_playing = true
		var cells := _range_cells()
		_drag_to(cells[2], cells[3])
	)

	step("Then playback wraps at the new end", func():
		expect(State.is_playing, "playback keeps running")
		State.playback.advance()
		expect(State.current_frame == 2, "playback advances within the new range")
		State.playback.advance()
		expect(State.current_frame == 3, "playback reaches the new end")
		State.playback.advance()
		expect(State.current_frame == 1, "playback wraps to the new start")
		State.stop()
	)

	step("When the user drags the end grip and pauses", func():
		var cells := _range_cells()
		_drag_to(cells[3], cells[2], false)
	)
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 900:
		await get_tree().process_frame
	step("When the user continues the drag onto the start frame", func():
		var cells := _range_cells()
		var motion := InputEventMouseMotion.new()
		motion.position = _local(cells[3], cells[1].get_global_rect().get_center())
		cells[3]._gui_input(motion)
		_release_at(cells[3], cells[1])
	)

	step("Then the single frame shows both grips", func():
		expect(State.document.tags[0].from == 1, "the tag starts on frame two")
		expect(State.document.tags[0].to == 1, "the tag ends on frame two")
		var cell = _range_cells()[1]
		expect(cell.get_node("%StartGrip").is_visible_in_tree(), "the start grip is shown")
		expect(cell.get_node("%EndGrip").is_visible_in_tree(), "the end grip is shown")
		expect(cell.get_node("%StartGrip").tooltip_text == "Start frame 2", "the start grip identifies frame two")
		expect(cell.get_node("%EndGrip").tooltip_text == "End frame 2", "the end grip identifies frame two")
	)

	step("When the user undoes and redoes the paused drag", func():
		State.undo_redo.undo()
		expect(State.document.tags[0].to == 3, "one undo restores the range before the paused drag")
		State.undo_redo.redo()
		expect(State.document.tags[0].to == 1, "one redo restores the complete paused drag")
	)

	step("Given two tags with separate range edits", func():
		State.document.add_tag("Second", 0, 3)
		State.undo_redo.clear_history()
		State.active_tag = 0
		State.set_tag_range(0, 2)
		State.active_tag = 1
		State.set_tag_range(1, 3)
	)

	step("Then each tag range has a separate undo action", func():
		State.undo_redo.undo()
		expect(State.document.tags[1].from == 0, "undo restores the second tag range")
		expect(State.document.tags[0].to == 2, "undo preserves the first tag range edit")
		State.undo_redo.undo()
		expect(State.document.tags[0].from == 1 and State.document.tags[0].to == 1, "the next undo restores the first tag range")
		State.undo_redo.redo()
		State.undo_redo.redo()
		expect(State.document.tags[0].to == 2 and State.document.tags[1].from == 1, "redo restores both tag range edits")
	)

	step("When the user deselects the tag", func():
		State.deselect_tag()
	)

	step("Then the range row disappears without a tag", func():
		expect(_grid().get_child_count() == 4, "the grid holds only the frames")
		expect(_range_cells().is_empty(), "no range cells remain")
	)
