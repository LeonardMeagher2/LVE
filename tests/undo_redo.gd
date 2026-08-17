extends "res://tests/test.gd"

var _inst: Node = null
var _st: EditorState


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	_inst = scene.instantiate()
	root.add_child(_inst)
	test("can undo and redo a stroke", _run)


func _run() -> void:
	for i in 2:
		await process_frame

	step("Given an editor with a fresh document", func():
		_st = _inst.state
		expect(_st != null, "editor state exists")
	)

	step("When the user paints a stroke voxel at (9, 0, 8)", func():
		_st.begin_stroke()
		_st.apply_tool(Vector3i(9, 0, 8), EditorViewport.NONE)
		_st.end_stroke()
	)

	step("Then the stroke voxel is in the frame", func():
		expect(_st.doc.frames[0].cells.has(Vector3i(9, 0, 8)), "stroke voxel present")
	)

	step("When the user undoes the stroke", func():
		_st.undo()
	)

	step("Then the stroke voxel is removed", func():
		expect(not _st.doc.frames[0].cells.has(Vector3i(9, 0, 8)), "stroke voxel removed after undo")
	)

	step("When the user redoes the stroke", func():
		_st.redo()
	)

	step("Then the stroke voxel returns", func():
		expect(_st.doc.frames[0].cells.has(Vector3i(9, 0, 8)), "stroke voxel present after redo")
	)
