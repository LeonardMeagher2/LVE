extends "res://tests/test.gd"


func _ready() -> void:
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


func _drag_to(cell: Node, target: Node) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = cell.get_global_rect().get_center()
	cell._gui_input(press)
	var motion := InputEventMouseMotion.new()
	motion.position = target.get_global_rect().get_center()
	cell._input(motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = target.get_global_rect().get_center()
	cell._input(release)


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
		expect(_range_cells()[2].get_node("%EndGrip").text == "3", "the end grip shows frame three")
	)

	step("When the user drags the start grip to frame two", func():
		var cells := _range_cells()
		_drag_to(cells[0], cells[1])
	)

	step("Then the tag starts on frame two", func():
		expect(State.document.tags[0].from == 1, "the tag starts on the second frame")
		expect(_range_cells()[1].get_node("%StartGrip").text == "2", "the start grip shows frame two")
	)

	step("When the user undoes the range drags", func():
		State.undo_redo.undo()
	)

	step("Then the tag range returns to all frames", func():
		expect(State.document.tags[0].from == 0, "the tag starts on the first frame")
		expect(State.document.tags[0].to == 3, "the tag ends on the last frame")
	)

	step("When the user redoes the range drags", func():
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
		State._advance_playback()
		expect(State.current_frame == 2, "playback advances within the new range")
		State._advance_playback()
		expect(State.current_frame == 3, "playback reaches the new end")
		State._advance_playback()
		expect(State.current_frame == 1, "playback wraps to the new start")
		State.stop()
	)

	step("When the user drags the end grip onto the start frame", func():
		var cells := _range_cells()
		_drag_to(cells[3], cells[1])
	)

	step("Then the single frame shows both grips", func():
		expect(State.document.tags[0].from == 1, "the tag starts on frame two")
		expect(State.document.tags[0].to == 1, "the tag ends on frame two")
		var cell = _range_cells()[1]
		expect(cell.get_node("%StartGrip").is_visible_in_tree(), "the start grip is shown")
		expect(cell.get_node("%EndGrip").is_visible_in_tree(), "the end grip is shown")
		expect(cell.get_node("%StartGrip").text == "2", "the start grip shows frame two")
		expect(cell.get_node("%EndGrip").text == "2", "the end grip shows frame two")
	)

	step("When the user deselects the tag", func():
		State.deselect_tag()
	)

	step("Then the range row disappears without a tag", func():
		expect(_grid().get_child_count() == 4, "the grid holds only the frames")
		expect(_range_cells().is_empty(), "no range cells remain")
	)
