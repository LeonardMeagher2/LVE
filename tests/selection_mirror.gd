extends "res://tests/test.gd"

var viewport: SubViewport
var selection_plugin: Node
var frame: VoxelFrame


func _ready() -> void:
	timeout = 30.0
	test("selection tools include enabled symmetry reflections without extra controls", _run)


func _run() -> void:
	step("Given Box selection and the default X symmetry plane", func():
		viewport = editor_viewport()
		viewport.get_parent().stretch = false
		viewport.size = Vector2i(800, 500)
		State.document = VoxelDocument.new()
		State.symmetry_axes = 1
		State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
		selection_plugin = plugin("SelectionPlugin")
		select_toolbar_item("selection", "Box")
		selection_plugin._settings.mode = selection_plugin._settings.SelectMode.REPLACE
		camera_rig().is_orthogonal = true
		camera_rig().set_view("top")
		camera_rig().center_on(AABB(Vector3(-10, -1, -10), Vector3(20, 2, 20)))
	)
	step("When the user drags a box on one side of the symmetry plane", func():
		_button(Vector3(1, -0.5, 1), true)
		var motion := InputEventMouseMotion.new()
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.position = camera_rig().unproject_position(Vector3(2, -0.5, 2))
		viewport.push_input(motion)
	)
	step("Then the preview includes the original and reflected boxes", func():
		var preview: Node = selection_plugin._box.get_node("SelectionPreview")
		expect(preview._requested_cells.size() == 8, "the selection preview contains both four-cell boxes")
		_button(Vector3(2, -0.5, 2), false)
	)
	step("Then both boxes are selected with one undo action", func():
		expect(State.selection.count() == 8, "Box selects the original and reflected regions")
		expect(State.selection.contains(Vector3i(-3, 0, 2)), "the reflected region uses the half-voxel origin")
		expect(State.get_current_voxel_frame().count() == 0, "selection includes empty cells without creating voxels")
		State.undo_redo.undo()
		expect(State.selection.is_empty(), "one undo clears both selected boxes")
		State.undo_redo.redo()
		expect(State.selection.count() == 8, "redo restores both selected boxes")
	)
	step("When the user adds and subtracts individual cells", func():
		selection_plugin._settings.mode = selection_plugin._settings.SelectMode.ADD
		_click(Vector3(4, -0.5, 1))
		expect(State.selection.count() == 10 and State.selection.contains(Vector3i(-5, 0, 1)), "Add includes the reflected cell")
		selection_plugin._settings.mode = selection_plugin._settings.SelectMode.SUBTRACT
		_click(Vector3(1, -0.5, 1))
	)
	step("Then Subtract removes both sides of the selected cell", func():
		expect(State.selection.count() == 8, "Subtract removes the original and reflected cells")
		expect(not State.selection.contains(Vector3i(-2, 0, 1)), "the subtracted reflection is excluded from the selection")
	)
	step("When the user paints inside the symmetric selection", func():
		State.begin_stroke()
		State.paint(Vector3i(2, 0, 2), VoxelFrame.material(Color.RED))
		State.end_stroke()
	)
	step("Then drawing respects both selected regions", func():
		frame = State.get_current_voxel_frame()
		expect(frame.count() == 2 and frame.get_color(Vector3i(-3, 0, 2)) == Color.RED, "the selection permits the reflected brush edit")
	)
	step("When the user selects a cell with Lasso", func():
		State.document = VoxelDocument.new()
		select_toolbar_item("selection", "Lasso")
		selection_plugin._settings.mode = selection_plugin._settings.SelectMode.REPLACE
		_click(Vector3(3, -0.5, 3))
	)
	step("Then Lasso includes the reflected empty cell", func():
		expect(State.selection.count() == 2 and State.selection.contains(Vector3i(-4, 0, 3)), "Lasso selects both sides of the mirror plane")
	)
	step("Given matching voxels for Wand selection", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cells({Vector3i(2, 0, 2): VoxelFrame.material(Color.RED), Vector3i(2, 0, 3): VoxelFrame.material(Color.RED)})
		select_toolbar_item("selection", "Wand")
		selection_plugin._settings.mode = selection_plugin._settings.SelectMode.REPLACE
		_click(Vector3(2, 0.5, 2))
	)
	await _settle()
	step("Then Wand selects the matching region and its reflection", func():
		expect(State.selection.count() == 4 and State.selection.contains(Vector3i(-3, 0, 3)), "Wand includes the reflected matching region")
		expect(frame.count() == 2, "symmetric selection preserves the source voxels")
		State.undo_redo.undo()
		expect(State.selection.is_empty(), "one undo clears the symmetric Wand selection")
	)
	step("When the user selects a large region and changes symmetry during worker processing", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		var colors := {}
		for x in range(1, 33):
			for y in range(1, 17):
				for z in range(1, 17):
					colors[Vector3i(x, y, z)] = VoxelFrame.material(Color.BLUE)
		frame.set_cells(colors)
		State.symmetry_axes = 7
		selection_plugin._wand._commit(Vector3i.ONE)
		expect(State.edit_busy(), "the large symmetric selection runs on a worker")
		State.symmetry_axes = 0
		State.symmetry_origin = Vector3.ONE * 100
	)
	await _settle()
	step("Then the worker uses its captured symmetry settings", func():
		expect(State.selection.count() == 65536, "the worker selects eight disjoint region copies")
		expect(State.selection.contains(Vector3i(-2, -2, -2)), "the worker uses the original half-voxel origin")
		expect(not State.edit_busy(), "the completed symmetric selection releases editing")
	)
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN


func _button(world: Vector3, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = camera_rig().unproject_position(world)
	viewport.push_input(event)


func _click(world: Vector3) -> void:
	_button(world, true)
	_button(world, false)


func _settle() -> void:
	while selection_plugin._wand._job != null:
		await get_tree().process_frame
