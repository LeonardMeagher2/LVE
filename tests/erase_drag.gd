extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var c0 := VoxelPicking.NONE
var c1 := VoxelPicking.NONE


func _ready() -> void:
	test("can erase a stroke of voxels with a drag", _run)


func _run() -> void:
	step("Given a row of voxels under the drag path", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		center = Vector2(400.0, 250.0)
		activate_tool("eraser")
		var start := aim(center)
		c0 = start.target
		c1 = drag(center + Vector2(0.0, 20.0), start.plane).target
		State.document.frames[0].cells[c0] = State.current_color
		State.document.frames[0].cells[c1] = State.current_color
		sync_viewport()
	)

	step("When the user presses on the wall face and drags down", func():
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = center
		viewport.push_input(press)
		var drag_pos := center + Vector2(0.0, 20.0)
		var motion := InputEventMouseMotion.new()
		motion.position = drag_pos
		motion.relative = Vector2(0.0, 20.0)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		viewport.push_input(motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = drag_pos
		viewport.push_input(release)
	)

	step("Then the voxels under the drag are erased", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(not frame.cells.has(c0), "pressed voxel is erased")
		expect(not frame.cells.has(c1), "dragged voxel is erased")
	)

	step("Then the whole stroke can be undone", func():
		State.undo_redo.undo()
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.cells.has(c0), "pressed voxel returns after undo")
		expect(frame.cells.has(c1), "dragged voxel returns after undo")
	)
