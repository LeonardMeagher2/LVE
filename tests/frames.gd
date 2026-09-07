extends "res://tests/test.gd"


func _ready() -> void:
	test("can add a frame to the document", _run)


func _run() -> void:
	step("Given an editor with a fresh document", func():
		expect(State != null, "editor state exists")
	)

	step("When the user adds a frame", func():
		State.add_frame()
	)

	step("Then the document has 2 frames and the new frame is current", func():
		expect(State.document.frames.size() == 2, "document has 2 frames")
		expect(State.current_frame == 1, "new frame is current")
	)
