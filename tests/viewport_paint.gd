extends "res://tests/test.gd"

var _inst: Node = null
var _st: EditorState
var _vp: EditorViewport
var _center := Vector2.ZERO
var _pick_target := EditorViewport.NONE


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	_inst = scene.instantiate()
	root.add_child(_inst)
	test("can paint with the mouse at the cursor using the brush color", _run)


func _run() -> void:
	for i in 2:
		await process_frame

	step("Given an editor with a red brush and a voxel viewport", func():
		_st = _inst.state
		expect(_st != null, "editor state exists")
		_st.current_color = Color8(200, 60, 60)
		_vp = _inst.get_node("Root/ViewportContainer/Viewport/Editor")
		var svp := _vp.get_viewport()
		var vsize: Vector2i = svp.size
		if vsize.x <= 0 or vsize.y <= 0:
			svp.size = Vector2i(800, 500)
			vsize = svp.size
		_center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
	)

	step("When the user clicks the center of the viewport", func():
		_pick_target = _vp._pick(_center).target
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = _center
		_vp.handle_input(click, _center)
		click.pressed = false
		_vp.handle_input(click, _center)
	)

	step("Then the clicked cell is painted with the brush color", func():
		expect(_st.doc.frames[0].cells.has(_pick_target), "clicked cell is painted")
		expect(_st.doc.color_of(_st.doc.frames[0].cells[_pick_target]) == Color8(200, 60, 60), "painted cell has the brush color")
	)
