extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var painted := VoxelPicking.NONE


func _ready() -> void:
	test("can undo and redo a stroke", _run)


func _run() -> void:
	step("Given an editor with a fresh document", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		center = Vector2(400.0, 250.0)
	)

	step("When the user paints a voxel at the cursor", func():
		var req := pick_request(center)
		painted = VoxelPicking.start_pick(req.origin, req.dir, req.frame, req.forward).target
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = center
		viewport.push_input(click)
		click.pressed = false
		viewport.push_input(click)
	)

	step("Then the stroke voxel is in the frame", func():
		expect(State.document.frames[0].has(painted), "stroke voxel present")
	)

	step("When the user undoes the stroke", func():
		State.undo_redo.undo()
	)

	step("Then the stroke voxel is removed", func():
		expect(not State.document.frames[0].has(painted), "stroke voxel removed after undo")
	)

	step("When the user redoes the stroke", func():
		State.undo_redo.redo()
	)

	step("Then the stroke voxel returns", func():
		expect(State.document.frames[0].has(painted), "stroke voxel present after redo")
	)
