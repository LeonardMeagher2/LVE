extends "res://tests/test.gd"

# Selection tools include enabled symmetry reflections without extra controls.

var viewport: SubViewport
var selection_plugin: Node
var frame: VoxelFrame
var near_cell := Vector3i(0, 0, 0)
var far_cell := Vector3i(3, 0, 0)
var middle_cell := Vector3i(1, 0, 0)


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
		camera_rig().center_on(AABB(Vector3(-6, -1, -6), Vector3(12, 2, 12)))
		frame = State.get_current_voxel_frame()
		var material := VoxelFrame.material(Color.RED)
		frame.set_cell(near_cell, material)
		frame.set_cell(far_cell, material)
	)
	step("Then the depth test is on by default and the empty cells are off", func():
		expect(_depth_button().button_pressed, "the depth test is on by default")
		expect(not _empty_button().button_pressed, "the empty cells are off by default")
	)
	step("Given the depth test off and the empty cell option on", func():
		_depth_button().button_pressed = false
		_empty_button().button_pressed = true
	)
	step("When the user drags a box across both voxels", func():
		_drag_box(near_cell, far_cell)
	)
	step("Then both voxels, the empty cell, and both reflections are selected", func():
		expect(State.selection.contains(middle_cell), "the empty cell between the voxels is selected")
		expect(State.selection.contains(_mirror(middle_cell)), "the reflected empty cell is selected")
		expect(State.selection.count() == 8, "the default selects both sides of the mirror plane with the empty cells")
		expect(frame.count() == 2, "selection adds no voxels")
	)
	step("When the user undoes and redoes the symmetric selection", func():
		State.undo_redo.undo()
	)
	step("Then one undo clears both sides", func():
		expect(State.selection.is_empty(), "one undo clears the symmetric selection")
		State.undo_redo.redo()
		expect(State.selection.count() == 8, "redo restores the symmetric selection")
	)
	step("When the user paints inside the symmetric selection", func():
		State.begin_stroke()
		State.paint(middle_cell, VoxelFrame.material(Color.BLUE))
		State.end_stroke()
	)
	step("Then drawing respects both selected regions", func():
		frame = State.get_current_voxel_frame()
		expect(frame.count() == 4 and frame.get_color(_mirror(middle_cell)) == Color.BLUE, "the selection permits the reflected brush edit")
	)
	step("Given the empty cell option off", func():
		_empty_button().button_pressed = false
		expect(not _empty_button().button_pressed, "the empty cell option shows as released")
	)
	step("When the user drags the same box again", func():
		_drag_box(near_cell, far_cell)
	)
	step("Then the occupied voxels and their reflections are selected", func():
		_expect_cells([
			near_cell, middle_cell, far_cell,
			_mirror(near_cell), _mirror(middle_cell), _mirror(far_cell),
		], "the released option selects the three voxels and their reflections")
	)
	step("When the user selects a voxel with Lasso", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(near_cell, VoxelFrame.material(Color.RED))
		select_toolbar_item("selection", "Lasso")
		_empty_button().button_pressed = false
		selection_plugin._settings.mode = selection_plugin._settings.SelectMode.REPLACE
		_lasso_around(near_cell)
	)
	step("Then Lasso includes the reflected voxel", func():
		_expect_cells([near_cell, _mirror(near_cell)], "Lasso selects both sides of the mirror plane")
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


func _mirror(cell: Vector3i) -> Vector3i:
	return Vector3i(-1 - cell.x, cell.y, cell.z)


func _expect_cells(cells: Array, message: String) -> void:
	expect(State.selection.count() == cells.size(), message)
	for cell in cells:
		expect(State.selection.contains(cell), message)


func _screen_of(cell: Vector3i) -> Vector2:
	return camera_rig().unproject_position(Vector3(cell))


func _screen_bounds(first: Vector3i, second: Vector3i) -> Array:
	var a := _screen_of(first)
	var b := _screen_of(second)
	var low := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2(8, 8)
	var high := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2(8, 8)
	return [low, high]


func _drag_box(first: Vector3i, second: Vector3i) -> void:
	var bounds := _screen_bounds(first, second)
	_press(bounds[0])
	_move_to(bounds[1])
	_release(bounds[1])


func _lasso_around(cell: Vector3i) -> void:
	var point := _screen_of(cell)
	var low := point - Vector2(9, 9)
	var high := point + Vector2(9, 9)
	_press(low)
	for corner in [Vector2(high.x, low.y), high, Vector2(low.x, high.y)]:
		_move_to(corner)
	_release(low)


func _press(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	viewport.push_input(event)


func _move_to(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(event)


func _release(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
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


func _depth_button() -> Button:
	var option_bar := main.get_node("%OptionBar")
	for container in option_bar.get_children():
		if container.name == "Options":
			return container.get_node("Depth") as Button
	return null


func _click(world: Vector3) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = camera_rig().unproject_position(world)
	viewport.push_input(event)
	event = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = camera_rig().unproject_position(world)
	viewport.push_input(event)


func _settle() -> void:
	while selection_plugin._wand._job != null:
		await get_tree().process_frame
