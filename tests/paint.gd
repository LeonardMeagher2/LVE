extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var pressed := VoxelPicking.NONE


func _ready() -> void:
	test("can paint a stroke of voxels with a drag", _run)


func _run() -> void:
	step("Given a red brush on an empty grid", func():
		State.current_color = Color.from_rgba8(200, 60, 60)
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		center = Vector2(400.0, 250.0)
	)

	step("When the user presses and drags the viewport", func():
		var req := pick_request(center)
		pressed = VoxelPicking.start_pick(req.origin, req.dir, req.cells, req.forward).target
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = center
		viewport.push_input(press)
		var drag_pos := center + Vector2(0.0, 150.0)
		var motion := InputEventMouseMotion.new()
		motion.position = drag_pos
		motion.relative = Vector2(0.0, 150.0)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		viewport.push_input(motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = drag_pos
		viewport.push_input(release)
	)

	step("Then a stroke of voxels is painted", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.cells.size() > 1, "the drag painted a stroke")
		expect(frame.cells.has(pressed), "the pressed cell is painted")
	)

	step("When the user undoes the stroke", func():
		State.undo_redo.undo()
	)

	step("Then the stroke is removed", func():
		expect(State.document.frames[0].cells.is_empty(), "the stroke is removed")
	)
