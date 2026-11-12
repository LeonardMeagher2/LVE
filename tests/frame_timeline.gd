extends "res://tests/test.gd"

# One process runs the frame-timeline tests. Each test keeps the steps and checks
# of its original scene. The user arguments after `--` name the tests to run, so
# an old scene name still selects its own test.


func _ready() -> void:
	test("can set a frame delay on the timeline", _frame_delay, "frame_delay")
	test("frame buttons follow the current frame", _frame_selection, "frame_selection")
	test("can drag frames to reorder them", _frame_reorder, "frame_reorder")
	test("the timeline scroll follows the focused frame", _follow_focus, "follow_focus")


# Each test starts from a fresh one-frame document.
func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.current_frame = 0
	State.active_tag = 0


# Shared fixture: add frames beside the first one.
func _add_frames(extra: int) -> void:
	for i in extra:
		State.add_frame()


# Shared fixture: the timeline frame cells in order.
func _frame_cells() -> Array:
	var out: Array = []
	var grid := main.find_child("FrameGrid", true, false)
	for child in grid.get_children():
		if child is AnimationFrame:
			out.append(child)
	return out


# Shared fixture: the frame buttons in order.
func _frame_buttons() -> Array:
	var out: Array = []
	for cell in _frame_cells():
		out.append(cell.get_node("%Button"))
	return out


func _follow_focus() -> void:
	step("Then the timeline scroll container follows focus", func():
		var grid := main.find_child("FrameGrid", true, false)
		expect(grid != null, "the frame grid exists")
		if grid != null:
			var scroll := grid.get_parent() as ScrollContainer
			expect(scroll != null, "the grid sits in a scroll container")
			if scroll != null:
				expect(scroll.follow_focus, "the scroll container follows focus")
	)


func _frame_delay() -> void:
	step("Given an editor with two frames", func():
		_add_frames(1)
	)

	step("Then the delay fields are shown", func():
		var cells := _frame_cells()
		expect(cells[0].get_node("%Delay").is_visible_in_tree(), "the first delay field is shown")
		expect(cells[1].get_node("%Delay").is_visible_in_tree(), "the second delay field is shown")
	)

	step("When the user sets the current frame delay to 250 ms", func():
		_frame_cells()[1].get_node("%Delay").value = 250
	)

	step("Then the current frame delay is 250 ms", func():
		expect(State.document.frames[1].delay_ms == 250, "the current frame delay is 250 ms")
		expect(State.document.frames[0].delay_ms == 100, "the other frame delay stays 100 ms")
	)

	step("When the user undoes the delay change", func():
		State.undo_redo.undo()
	)

	step("Then the delay returns to 100 ms", func():
		expect(State.document.frames[1].delay_ms == 100, "the delay returns to 100 ms")
	)

	step("When the user redoes the delay change", func():
		State.undo_redo.redo()
	)

	step("Then the delay is 250 ms again", func():
		expect(State.document.frames[1].delay_ms == 250, "the delay is 250 ms again")
	)


func _frame_selection() -> void:
	step("Given an editor with two frames", func():
		_add_frames(1)
	)

	step("When the user steps to the first frame", func():
		State.current_frame = 0
	)

	step("Then the first frame button is selected", func():
		var buttons := _frame_buttons()
		expect(buttons.size() == 2, "two frame buttons exist")
		expect(buttons[0].button_pressed, "the first frame button is selected")
		expect(not buttons[1].button_pressed, "the second frame button is not selected")
	)

	step("When the user steps to the second frame", func():
		State.current_frame = 1
	)

	step("Then the second frame button is selected", func():
		var buttons := _frame_buttons()
		expect(buttons[1].button_pressed, "the second frame button is selected")
		expect(not buttons[0].button_pressed, "the first frame button is not selected")
	)

	expect(State.current_frame == 1, "the editor shows the second frame")


func _frame_reorder() -> void:
	step("Given three frames with distinct content", func():
		_add_frames(2)
		State.document.set_cell(0, Vector3i(0, 0, 0), VoxelFrame.material(Color.RED))
		State.document.set_cell(1, Vector3i(1, 0, 0), VoxelFrame.material(Color.GREEN))
		State.document.set_cell(2, Vector3i(2, 0, 0), VoxelFrame.material(Color.BLUE))
	)

	step("When the user drags frame three onto frame one", func():
		var buttons := _frame_buttons()
		var data: Variant = buttons[2]._get_drag_data(Vector2.ZERO)
		expect(data != null, "the drag carries frame data")
		expect(buttons[0]._can_drop_data(Vector2.ZERO, data), "frame one accepts the drop")
		buttons[0]._drop_data(Vector2.ZERO, data)
	)

	step("Then the frames are reordered", func():
		expect(State.document.frames[0].has(Vector3i(2, 0, 0)), "frame three is now first")
		expect(State.document.frames[1].has(Vector3i(0, 0, 0)), "frame one is now second")
		expect(State.document.frames[2].has(Vector3i(1, 0, 0)), "frame two is now third")
	)

	step("When the user undoes the reorder", func():
		State.undo_redo.undo()
	)

	step("Then the frames return to their original order", func():
		expect(State.document.frames[0].has(Vector3i(0, 0, 0)), "frame one is first again")
		expect(State.document.frames[1].has(Vector3i(1, 0, 0)), "frame two is second again")
		expect(State.document.frames[2].has(Vector3i(2, 0, 0)), "frame three is third again")
	)

	step("When the user redoes the reorder", func():
		State.undo_redo.redo()
	)

	step("Then the frames are reordered again", func():
		expect(State.document.frames[0].has(Vector3i(2, 0, 0)), "frame three is first again")
		expect(State.document.frames[1].has(Vector3i(0, 0, 0)), "frame one is second again")
		expect(State.document.frames[2].has(Vector3i(1, 0, 0)), "frame two is third again")
	)

	step("When the user drops a frame onto itself", func():
		var buttons := _frame_buttons()
		var data: Variant = buttons[1]._get_drag_data(Vector2.ZERO)
		buttons[1]._drop_data(Vector2.ZERO, data)
	)

	step("Then the order does not change", func():
		expect(State.document.frames[0].has(Vector3i(2, 0, 0)), "the first frame stays first")
		expect(State.document.frames[1].has(Vector3i(0, 0, 0)), "the second frame stays second")
		expect(State.document.frames[2].has(Vector3i(1, 0, 0)), "the third frame stays third")
	)

	step("When the user drags the current frame to the end", func():
		State.current_frame = 0
		var buttons := _frame_buttons()
		var data: Variant = buttons[0]._get_drag_data(Vector2.ZERO)
		buttons[2]._drop_data(Vector2.ZERO, data)
	)

	step("Then the current frame follows the dragged frame", func():
		expect(State.current_frame == 2, "the current frame follows the dragged frame")
		expect(State.document.frames[0].has(Vector3i(0, 0, 0)), "frame one is now first")
		expect(State.document.frames[1].has(Vector3i(1, 0, 0)), "frame two is now second")
		expect(State.document.frames[2].has(Vector3i(2, 0, 0)), "frame three is now third")
	)
