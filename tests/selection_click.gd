extends "res://tests/test.gd"

# A click is a small shape. It selects the cells under the pointer.

var viewport: SubViewport
var center := Vector2.ZERO
var cell := VoxelPicking.NONE
var far_cell := VoxelPicking.NONE
var empty_cell := VoxelPicking.NONE


func _ready() -> void:
	test("a click selects the voxels under the pointer and the optional empty cells", _run)


func _run() -> void:
	step("Given the box tool and two voxels with a gap", func():
		viewport = editor_viewport()
		viewport.get_parent().stretch = false
		viewport.size = Vector2i(800, 500)
		State.document = VoxelDocument.new()
		activate_tool("selection")
		select_toolbar_item("selection", "Box")
		center = Vector2(viewport.size.x * 0.5, viewport.size.y * 0.5)
		cell = aim(center).target
		far_cell = cell + Vector3i(3, 0, 0)
		empty_cell = cell + Vector3i(1, 0, 0)
		var material := VoxelFrame.material(Color.from_rgba8(150, 150, 150))
		_frame().set_cell(cell, material)
		_frame().set_cell(far_cell, material)
	)

	step("Then the empty cell option is on by default", func():
		expect(_empty_button().button_pressed, "the empty cell option shows as pressed")
	)

	step("When the user clicks the first voxel", func():
		_click(_screen_of(cell))
	)

	step("Then that voxel is selected without the far voxel", func():
		expect(State.selection.contains(cell), "the clicked voxel is selected")
		expect(not State.selection.contains(far_cell), "the far voxel stays out of the selection")
	)

	step("Given the empty cell option off", func():
		_empty_button().button_pressed = false
	)

	step("When the user clicks an empty cell", func():
		_click(_screen_of(empty_cell))
	)

	step("Then the empty click clears the selection", func():
		expect(State.selection.is_empty(), "an empty click selects nothing without the empty cell option")
	)

	step("Given the empty cell option on", func():
		_empty_button().button_pressed = true
		expect(_empty_button().button_pressed, "the empty cell option shows as pressed")
	)

	step("When the user clicks the empty cell again", func():
		_click(_screen_of(empty_cell))
	)

	step("Then the empty cells behind the pointer are selected", func():
		expect(not State.selection.is_empty(), "the empty click selects cells")
		expect(not State.selection.contains(cell), "the empty click leaves the first voxel out")
		expect(not State.selection.contains(far_cell), "the empty click leaves the far voxel out")
		for selected in State.selection.to_array():
			expect(not _frame().has(selected), "the selected cell %s is empty" % selected)
	)


func _frame() -> VoxelFrame:
	return State.document.frames[State.current_frame]


func _screen_of(cell_position: Vector3i) -> Vector2:
	return camera_rig().unproject_position(Vector3(cell_position))


func _click(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	viewport.push_input(event)
	event = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = pos
	viewport.push_input(event)


func _empty_button() -> Button:
	var option_bar := main.get_node("%OptionBar")
	for container in option_bar.get_children():
		if container.name == "Options":
			return container.get_node("empty") as Button
	return null
