extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var seed := VoxelPicking.NONE


func _ready() -> void:
	test("a drag selects every cell inside the dragged box", _run)


func _run() -> void:
	step("Given the select tool and two voxels near the center", func():
		viewport = editor_viewport()
		activate_tool("selection")
		select_toolbar_item("selection", "Box")
		var vsize: Vector2i = viewport.size
		if vsize.x <= 0 or vsize.y <= 0:
			viewport.size = Vector2i(800, 500)
			vsize = viewport.size
		center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
		seed = aim(center).target
		var gray := Color.from_rgba8(150, 150, 150)
		var f: VoxelFrame = State.document.frames[State.current_frame]
		f.set_cell(seed, gray)
		f.set_cell(seed + Vector3i(12, 0, 0), gray)
	)

	step("When the user drags a box across the grid", func():
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = center
		viewport.push_input(press)
		var drag_pos := center + Vector2(60, 40)
		var motion := InputEventMouseMotion.new()
		motion.position = drag_pos
		motion.relative = Vector2(60, 40)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		viewport.push_input(motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = drag_pos
		viewport.push_input(release)
	)

	step("Then every cell inside the box is selected", func():
		expect(not State.selection.is_empty(), "selection is not empty")
		expect(State.selection.contains(seed), "the pressed cell is selected")
		expect(not State.selection.contains(seed + Vector3i(12, 0, 0)), "the far voxel is not selected")
		var has_air := false
		for c in State.selection.to_array():
			if not State.document.frames[State.current_frame].has(c):
				has_air = true
				break
		expect(has_air, "the selection includes empty cells")
	)

	step("When the user undoes the selection", func():
		State.undo_redo.undo()
	)

	step("Then the selection is cleared", func():
		expect(State.selection.is_empty(), "selection is empty after undo")
	)
