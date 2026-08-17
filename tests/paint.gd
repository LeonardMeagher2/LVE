extends "res://tests/test.gd"

var _inst: Node = null
var _st: EditorState


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	_inst = scene.instantiate()
	root.add_child(_inst)
	test("can paint voxels with a brush", _run)


func _run() -> void:
	for i in 2:
		await process_frame

	step("Given an editor with a fresh document and a red brush", func():
		_st = _inst.state
		expect(_st != null, "editor state exists")
		_st.current_color = Color8(200, 60, 60)
	)

	step("When the user paints a brush voxel at (8, 0, 8)", func():
		_st.apply_tool(Vector3i(8, 0, 8), EditorViewport.NONE)
	)

	step("Then the brush voxel is in the frame", func():
		expect(_st.doc.frames[0].cells.has(Vector3i(8, 0, 8)), "brush voxel present")
	)

	step("When the user paints a stroke voxel at (9, 0, 8)", func():
		_st.begin_stroke()
		_st.apply_tool(Vector3i(9, 0, 8), EditorViewport.NONE)
		_st.end_stroke()
	)

	step("Then the stroke voxel is in the frame", func():
		expect(_st.doc.frames[0].cells.has(Vector3i(9, 0, 8)), "stroke voxel present")
	)

	step("Then the painted voxels use the brush color", func():
		expect(_st.doc.color_of(_st.doc.frames[0].cells[Vector3i(8, 0, 8)]) == Color8(200, 60, 60), "brush voxel has the brush color")
		expect(_st.doc.color_of(_st.doc.frames[0].cells[Vector3i(9, 0, 8)]) == Color8(200, 60, 60), "stroke voxel has the brush color")
	)
