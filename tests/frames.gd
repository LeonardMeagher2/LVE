extends "res://tests/test.gd"

var _inst: Node = null


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("can add a frame to the document", _run)


func _run() -> void:
	step("Given an editor with a fresh document", func():
		expect(State != null, "editor state exists")
	)

	step("When the user adds a frame", func():
		State.playback.add_frame()
	)

	step("Then the document has 2 frames and the new frame is current", func():
		expect(State.document.frames.size() == 2, "document has 2 frames")
		expect(State.current_frame == 1, "new frame is current")
	)
