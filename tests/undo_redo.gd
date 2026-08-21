extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _painted := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("can undo and redo a stroke", _run)


func _run() -> void:
	step("Given an editor with a fresh document", func():
		_vp = _inst.get_node("Content/Root/Body/CenterPane/ViewportContainer/Viewport/Editor")
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
	)

	step("When the user paints a voxel at the cursor", func():
		var req := _vp.pick_request(_center)
		_painted = VoxelPicking.start_pick(req.origin, req.dir, req.cells).target
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = _center
		_vp.get_viewport().push_input(click)
		click.pressed = false
		_vp.get_viewport().push_input(click)
	)

	step("Then the stroke voxel is in the frame", func():
		expect(State.document.frames[0].cells.has(_painted), "stroke voxel present")
	)

	step("When the user undoes the stroke", func():
		State.undo_redo.undo()
	)

	step("Then the stroke voxel is removed", func():
		expect(not State.document.frames[0].cells.has(_painted), "stroke voxel removed after undo")
	)

	step("When the user redoes the stroke", func():
		State.undo_redo.redo()
	)

	step("Then the stroke voxel returns", func():
		expect(State.document.frames[0].cells.has(_painted), "stroke voxel present after redo")
	)
