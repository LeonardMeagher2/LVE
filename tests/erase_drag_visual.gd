extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var c0 := VoxelPicking.NONE
var c_mid := VoxelPicking.NONE


func _ready() -> void:
	test("the eraser highlight follows the voxel being erased", _run)


func _run() -> void:
	step("Given an eraser and a row of voxels under the drag path", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		center = Vector2(400.0, 250.0)
		select_toolbar_item("Toolbar", "Eraser")
		var start := aim(center)
		c0 = start.target
		c_mid = drag(center + Vector2(0.0, 20.0), start.plane).target
		State.document.set_cell(0, c0, VoxelFrame.material(State.current_color))
		State.document.set_cell(0, c_mid, VoxelFrame.material(State.current_color))
		sync_viewport()
	)

	step("When the user presses the wall and drags onto the lower voxel", func():
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = center
		viewport.push_input(press)
		var mid := center + Vector2(0.0, 20.0)
		var motion := InputEventMouseMotion.new()
		motion.position = mid
		motion.relative = Vector2(0.0, 20.0)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		viewport.push_input(motion)
	)

	step("Then the highlight is on the voxel being erased", func():
		var v: Node3D = active_tool_node("BrushPlugin")
		expect(v.visible, "the highlight is visible")
		expect(v.position == Vector3(c_mid), "the highlight is on the voxel being erased")
	)

	step("When the user drags below the wall", func():
		var low := center + Vector2(0.0, 50.0)
		var motion := InputEventMouseMotion.new()
		motion.position = low
		motion.relative = Vector2(0.0, 30.0)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		viewport.push_input(motion)
	)

	step("Then the highlight stays visible", func():
		var v: Node3D = active_tool_node("BrushPlugin")
		expect(v.visible, "the highlight is still visible")
	)

	step("When the user releases the drag", func():
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = center + Vector2(0.0, 50.0)
		viewport.push_input(release)
	)
