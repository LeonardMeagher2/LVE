extends "res://tests/test.gd"

var _cells: Array = []


func _ready() -> void:
	test("can set a frame delay on the timeline", _run)


func _refresh_cells() -> void:
	_cells = []
	var grid := main.find_child("FrameGrid", true, false)
	for child in grid.get_children():
		if child is AnimationFrame:
			_cells.append(child)


func _run() -> void:
	step("Given an editor with two frames", func():
		State.add_frame()
		_refresh_cells()
	)

	step("Then the delay fields are shown", func():
		expect(_cells[0].get_node("%Delay").is_visible_in_tree(), "the first delay field is shown")
		expect(_cells[1].get_node("%Delay").is_visible_in_tree(), "the second delay field is shown")
	)

	step("When the user sets the current frame delay to 250 ms", func():
		_cells[1].get_node("%Delay").value = 250
	)

	step("Then the current frame delay is 250 ms", func():
		expect(State.document.frames[1].delay_ms == 250, "the current frame delay is 250 ms")
		expect(State.document.frames[0].delay_ms == 100, "the other frame delay stays 100 ms")
	)
