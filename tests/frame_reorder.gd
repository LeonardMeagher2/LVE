extends "res://tests/test.gd"

var _buttons: Array = []


func _ready() -> void:
	test("can drag frames to reorder them", _run)


func _refresh_buttons() -> void:
	_buttons = []
	var grid := main.find_child("FrameGrid", true, false)
	for child in grid.get_children():
		if child is AnimationFrame:
			_buttons.append(child.get_node("%Button"))


func _run() -> void:
	step("Given three frames with distinct content", func():
		State.add_frame()
		State.add_frame()
		State.document.set_cell(0, Vector3i(0, 0, 0), VoxelFrame.material(Color.RED))
		State.document.set_cell(1, Vector3i(1, 0, 0), VoxelFrame.material(Color.GREEN))
		State.document.set_cell(2, Vector3i(2, 0, 0), VoxelFrame.material(Color.BLUE))
		_refresh_buttons()
	)

	step("When the user drags frame three onto frame one", func():
		var data: Variant = _buttons[2]._get_drag_data(Vector2.ZERO)
		expect(data != null, "the drag carries frame data")
		expect(_buttons[0]._can_drop_data(Vector2.ZERO, data), "frame one accepts the drop")
		_buttons[0]._drop_data(Vector2.ZERO, data)
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
		_refresh_buttons()
		var data: Variant = _buttons[1]._get_drag_data(Vector2.ZERO)
		_buttons[1]._drop_data(Vector2.ZERO, data)
	)

	step("Then the order does not change", func():
		expect(State.document.frames[0].has(Vector3i(2, 0, 0)), "the first frame stays first")
		expect(State.document.frames[1].has(Vector3i(0, 0, 0)), "the second frame stays second")
		expect(State.document.frames[2].has(Vector3i(1, 0, 0)), "the third frame stays third")
	)

	step("When the user drags the current frame to the end", func():
		State.current_frame = 0
		_refresh_buttons()
		var data: Variant = _buttons[0]._get_drag_data(Vector2.ZERO)
		_buttons[2]._drop_data(Vector2.ZERO, data)
	)

	step("Then the current frame follows the dragged frame", func():
		expect(State.current_frame == 2, "the current frame follows the dragged frame")
		expect(State.document.frames[0].has(Vector3i(0, 0, 0)), "frame one is now first")
		expect(State.document.frames[1].has(Vector3i(1, 0, 0)), "frame two is now second")
		expect(State.document.frames[2].has(Vector3i(2, 0, 0)), "frame three is now third")
	)
