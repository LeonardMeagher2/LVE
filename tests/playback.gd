extends "res://tests/test.gd"


func _ready() -> void:
	test("can play the voxel animation", _run)


func _run() -> void:
	step("Given a document with two distinct frames", func():
		State.document.add_frame()
		State.document.frames[1].cells[Vector3i(9, 0, 9)] = State.current_color
		State.document.frames[0].delay_ms = 250
		State.document.frames[1].delay_ms = 250
	)

	step("When the user plays the animation", func():
		State.play()
	)

	step("Then the displayed frame advances over time", func():
		var seen := {}
		for i in 30:
			await get_tree().process_frame
			seen[State.current_frame] = true
		expect(seen.size() > 1, "the displayed frame changes while playing")
		State.stop()
	)
