extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _pick_target := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("can paint with the mouse at the cursor using the brush color", _run)


func _run() -> void:
	step("Given an editor with a red brush and a voxel viewport", func():
		State.current_color = Color8(200, 60, 60)
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		var vsize: Vector2i = svp.size
		if vsize.x <= 0 or vsize.y <= 0:
			svp.size = Vector2i(800, 500)
			vsize = svp.size
		_center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
	)

	step("When the user clicks the center of the viewport", func():
		var req := _vp.pick_request(_center)
		_pick_target = VoxelPicking.start_pick(req.origin, req.dir, req.cells, req.forward).target
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = _center
		_vp.get_viewport().push_input(click)
		click.pressed = false
		_vp.get_viewport().push_input(click)
	)

	step("Then the clicked cell is painted with the brush color", func():
		expect(State.document.frames[0].cells.has(_pick_target), "clicked cell is painted")
		expect(State.document.color_of(State.document.frames[0].cells[_pick_target]) == Color8(200, 60, 60), "painted cell has the brush color")
	)
