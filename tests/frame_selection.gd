extends "res://tests/test.gd"

var _buttons: Array = []


func _ready() -> void:
	test("frame buttons follow the current frame", _run)


func _refresh_buttons() -> void:
	_buttons = []
	var grid := main.find_child("FrameGrid", true, false)
	for child in grid.get_children():
		if child is AnimationFrame:
			_buttons.append(child.get_node("%Button"))


func _run() -> void:
	step("Given an editor with two frames", func():
		State.add_frame()
	)

	step("When the user steps to the first frame", func():
		State.current_frame = 0
	)

	step("Then the first frame button is selected", func():
		_refresh_buttons()
		expect(_buttons.size() == 2, "two frame buttons exist")
		expect(_buttons[0].button_pressed, "the first frame button is selected")
		expect(not _buttons[1].button_pressed, "the second frame button is not selected")
	)

	step("When the user steps to the second frame", func():
		State.current_frame = 1
	)

	step("Then the second frame button is selected", func():
		_refresh_buttons()
		expect(_buttons[1].button_pressed, "the second frame button is selected")
		expect(not _buttons[0].button_pressed, "the first frame button is not selected")
	)

	expect(State.current_frame == 1, "the editor shows the second frame")