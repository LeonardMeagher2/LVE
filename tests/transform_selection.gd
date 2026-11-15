extends "res://tests/test.gd"

var viewport: SubViewport
var frame: VoxelFrame
var source_selection := {}


func _ready() -> void:
	test("transforms preserve selected empty cells through repeated drags, undo, and cancellation", _run)


func _run() -> void:
	step("Given an irregular selection and a voxel beside its destination", func():
		viewport = editor_viewport()
		viewport.get_parent().stretch = false
		viewport.size = Vector2i(800, 500)
		_setup(Vector3i(1, 1, 0))
		State.selection.cells.erase(Vector3i(1, 1, 0))
		source_selection = State.selection.capture()
		frame.set_cell(Vector3i(4, 0, 0), VoxelFrame.material(Color.GREEN))
		select_toolbar_item("transform", "Move")
	)
	step("When the user moves the selection three cells right", func():
		_drag(Vector3(0.5, 0.5, 0), Vector3(3.5, 0.5, 0))
	)
	step("Then the complete selection moves without removing the other voxel", func():
		_expect_translation(Vector3i(3, 0, 0))
		expect(frame.get_color(Vector3i(4, 0, 0)) == Color.GREEN, "the selected empty destination preserves the other voxel")
	)
	step("When the user moves three cells right again and commits", func():
		_drag(Vector3(3.5, 0.5, 0), Vector3(6.5, 0.5, 0))
		_press_option("Commit")
	)
	step("Then the repeated move preserves the selection shape and the other voxel", func():
		_expect_translation(Vector3i(6, 0, 0))
		expect(frame.count() == 2 and frame.get_color(Vector3i(4, 0, 0)) == Color.GREEN, "the repeated move leaves the other voxel intact")
		State.undo_redo.undo()
		expect(State.selection.capture() == source_selection, "undo restores the irregular source selection")
		State.undo_redo.redo()
		_expect_translation(Vector3i(6, 0, 0))
	)
	step("Given a rectangular selection with one voxel", func():
		_setup(Vector3i(2, 1, 0))
		select_toolbar_item("transform", "Rotate")
		plugin("TransformPlugin")._rotate._settings.snap = true
	)
	step("When the user rotates the rectangle by a quarter turn", func():
		_drag(Vector3(5, 0.5, 0), Vector3(1, 4.5, 0))
		_press_option("Commit")
	)
	step("Then the full rectangle rotates with its empty cells", func():
		var expected := VoxelSelection.new()
		expected.from_box(Vector3i.ZERO, Vector3i(1, 2, 0))
		expect(State.selection.capture() == expected.capture(), "the rotated selection contains the full two-by-three rectangle")
		expect(frame.count() == 1 and frame.has(Vector3i(1, 0, 0)), "the source voxel rotates inside the full selection")
		State.undo_redo.undo()
		expect(State.selection.capture() == source_selection, "undo restores the full source rectangle")
	)
	step("When the user rotates the rectangle by forty-five degrees", func():
		plugin("TransformPlugin")._rotate._settings.snap = false
		_drag(Vector3(5, 0.5, 0), Vector3(4, 3.5, 0))
	)
	step("Then the smooth rotation retains selected empty cells", func():
		expect(State.selection.count() > frame.count(), "the smooth rotation retains selection cells beyond the voxels")
		var contains_voxels := true
		for cell_position in frame.positions():
			contains_voxels = contains_voxels and State.selection.contains(cell_position)
		expect(contains_voxels, "the smooth selection contains the rotated voxels")
		_press_option("Cancel")
		expect(State.selection.capture() == source_selection, "Cancel restores the full source rectangle")
	)
	step("Given a square selection with one voxel", func():
		_setup(Vector3i(2, 2, 0))
		select_toolbar_item("transform", "Scale")
		plugin("TransformPlugin")._scale._settings.uniform = false
	)
	step("When the user doubles the width and height", func():
		_drag(Vector3(5, 5, 0), Vector3(9, 9, 0))
	)
	step("Then the full selection expands with its empty cells", func():
		var expected := VoxelSelection.new()
		expected.from_box(Vector3i(-2, -2, 0), Vector3i(3, 3, 0))
		expect(State.selection.capture() == expected.capture(), "the scaled selection contains the full six-by-six square")
		expect(frame.count() == 4, "only the source voxel expands into four voxels")
	)
	step("When the user doubles the selection again", func():
		# The scaled selection is centred on 0.5, so the second drag doubles the
		# distance from that centre.
		_drag(Vector3(5.5, 5.5, 0), Vector3(10.5, 10.5, 0))
		_press_option("Commit")
	)
	step("Then repeated scaling uses the full selection bounds", func():
		expect(State.selection.count() == 144, "the repeated scale contains twelve-by-twelve selected cells (has %d)" % State.selection.count())
		expect(frame.count() == 16, "the repeated scale contains sixteen occupied voxels (has %d)" % frame.count())
		State.undo_redo.undo()
		expect(State.selection.capture() == source_selection, "undo restores the full source square")
	)
	await get_tree().process_frame
	step("Given a selection with one voxel inside the slab and one below it", func():
		_setup(Vector3i(2, 1, 0))
		State.floor_axis = Vector3.Axis.AXIS_Y
		State.floor_index = 1
		State.slice_layers = 1
		frame.set_cell(Vector3i(0, -1, 0), VoxelFrame.material(Color.BLUE))
		State.selection.add(Vector3i(0, -1, 0))
		State.selection_changed.emit()
		select_toolbar_item("transform", "Move")
	)
	step("When the user moves the selection one cell up", func():
		_drag(Vector3(0.5, 0.5, 0), Vector3(0.5, 1.5, 0))
	)
	step("Then the off-slice source stays and does not copy into the slab", func():
		expect(frame.get_color(Vector3i(0, -1, 0)) == Color.BLUE, "the off-slice source is not cleared")
		expect(frame.get_color(Vector3i(0, 1, 0)) == Color.RED, "the inside voxel moves up one layer")
		expect(not frame.has(Vector3i(0, 0, 0)), "the off-slice source does not copy into the vacated cell")
		_press_option("Cancel")
		State.slice_enabled = false
	)


func _setup(last_corner: Vector3i) -> void:
	State.slice_enabled = false
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
	State.selection.from_box(Vector3i.ZERO, last_corner)
	State.selection_changed.emit()
	source_selection = State.selection.capture()
	camera_rig().set_view("front")
	camera_rig().is_orthogonal = true
	activate_tool("transform")


func _expect_translation(offset: Vector3i) -> void:
	var expected := {}
	for cell_position: Vector3i in source_selection:
		expected[cell_position + offset] = true
	expect(State.selection.capture() == expected, "the move retains every selected cell and the irregular shape")
	expect(frame.get_color(offset) == Color.RED, "the source voxel follows the moved selection")


func _drag(first: Vector3, last: Vector3) -> void:
	_button(first, true)
	var event := InputEventMouseMotion.new()
	event.position = camera_rig().unproject_position(last)
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(event)
	_button(last, false)


func _button(world: Vector3, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = camera_rig().unproject_position(world)
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(event)


func _press_option(tooltip: String) -> void:
	_find_option_button(tooltip).pressed.emit()
