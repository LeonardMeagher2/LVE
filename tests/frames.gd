extends "res://tests/test.gd"

var _inst: Node = null
var _st: EditorState


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	_inst = scene.instantiate()
	root.add_child(_inst)
	test("can add a frame to the document", _run)


func _run() -> void:
	for i in 2:
		await process_frame

	step("Given an editor with a fresh document", func():
		_st = _inst.state
		expect(_st != null, "editor state exists")
	)

	step("When the user adds a frame", func():
		_st.add_frame()
	)

	step("Then the document has 2 frames and the new frame is current", func():
		expect(_st.doc.frames.size() == 2, "document has 2 frames")
		expect(_st.current_frame == 1, "new frame is current")
	)
