extends "res://tests/test.gd"

# A screen drag selects the volume behind the shape.
# The empty cell option adds the empty grid cells inside the frame bounds.
# The depth test keeps the voxels that the camera sees.

const RAY_DEPTHS := [4.0, 7.0, 10.0]

var viewport: SubViewport
var center := Vector2.ZERO
var ray_cells: Array[Vector3i] = []


func _ready() -> void:
	test("a drag selects the volume behind the shape, the empty cells, and the depth test front layer", _run)


func _run() -> void:
	step("Given the box tool and voxels along the view ray", func():
		viewport = editor_viewport()
		viewport.get_parent().stretch = false
		viewport.size = Vector2i(800, 500)
		State.document = VoxelDocument.new()
		activate_tool("selection")
		select_toolbar_item("selection", "Box")
		center = Vector2(viewport.size.x * 0.5, viewport.size.y * 0.5)
		ray_cells = _place_ray_voxels()
	)

	step("Then the depth test is on by default and the empty cells are off", func():
		expect(_depth_button().button_pressed, "the depth test is on by default")
		expect(not _empty_button().button_pressed, "the empty cells are off by default")
	)

	step("Given the depth test off and the empty cell option on", func():
		_depth_button().button_pressed = false
		_empty_button().button_pressed = true
	)

	step("When the user drags a rectangle around the projected voxels", func():
		_drag_rectangle(_drag_rectangle_of(ray_cells))
	)

	step("Then every voxel along the ray is selected with the empty cells", func():
		for cell in ray_cells:
			expect(State.selection.contains(cell), "the voxel %s behind the front voxel is selected" % cell)
		var has_empty := false
		for cell in State.selection.to_array():
			if not _frame().has(cell):
				has_empty = true
				break
		expect(has_empty, "the selection includes empty cells by default")
		expect(State.selection.count() > ray_cells.size(), "the empty cells extend the selection")
		expect(_inside_bounds(State.selection.to_array()), "every selected cell sits inside the frame bounds")
	)

	step("Given the empty cell option off", func():
		_empty_button().button_pressed = false
		expect(not _empty_button().button_pressed, "the empty cell option shows as released")
	)

	step("When the user drags the same rectangle again", func():
		_drag_rectangle(_drag_rectangle_of(ray_cells))
	)

	step("Then the selection holds the occupied voxels only", func():
		expect(State.selection.count() == ray_cells.size(), "the released option leaves the empty cells out")
	)

	step("Given the empty cell option on and the subtract mode", func():
		_empty_button().button_pressed = true
		_drag_rectangle(_drag_rectangle_of(ray_cells))
		expect(State.selection.count() > ray_cells.size(), "the empty cell drag selects empty cells")
		_empty_button().button_pressed = false
		_mode_button("subtract").button_pressed = true
	)

	step("When the user subtracts the same rectangle without the option", func():
		_drag_rectangle(_drag_rectangle_of(ray_cells))
	)

	step("Then the subtract removes the selected empty cells", func():
		expect(State.selection.is_empty(), "subtract removes the selected empty cells without the option")
	)

	step("When the user undoes the subtract", func():
		State.undo_redo.undo()
	)

	step("Then the empty cell selection returns", func():
		expect(State.selection.count() > ray_cells.size(), "undo restores the empty cell selection")
	)

	step("When the user undoes the empty cell drag", func():
		State.undo_redo.undo()
	)

	step("Then the selection returns to the occupied voxels", func():
		expect(State.selection.count() == ray_cells.size(), "undo restores the occupied voxels only")
	)

	step("Given the depth test on, the replace mode, and the empty option off", func():
		_mode_button("replace").button_pressed = true
		expect(not _empty_button().button_pressed, "the empty cell option stays off")
		press_option("Depth test")
		expect(_depth_button().button_pressed, "the depth test turns on")
	)

	step("When the user drags the same rectangle with the depth test", func():
		_drag_rectangle(_drag_rectangle_of(ray_cells))
	)

	step("Then only the front voxel along the ray stays", func():
		expect(State.selection.contains(ray_cells[0]), "the front voxel stays")
		expect(not State.selection.contains(ray_cells[1]), "the voxel behind the front one drops out")
		expect(not State.selection.contains(ray_cells[2]), "the far voxel drops out")
		expect(State.selection.count() == 1, "the depth test keeps one voxel")
	)

	step("Given the depth test off again", func():
		press_option("Depth test")
		expect(not _depth_button().button_pressed, "the depth test turns off")
	)

	step("When the user drags the same rectangle once more", func():
		_drag_rectangle(_drag_rectangle_of(ray_cells))
	)

	step("Then every voxel along the ray returns", func():
		expect(State.selection.count() == ray_cells.size(), "the released depth test selects the volume again")
	)

	step("Then the depth test shows for the screen shapes only", func():
		select_toolbar_item("selection", "Lasso")
		expect(_depth_button().visible, "the lasso offers the depth test")
		select_toolbar_item("selection", "Wand")
		expect(not _depth_button().visible, "the wand has no depth test")
	)


func _frame() -> VoxelFrame:
	return State.document.frames[State.current_frame]


func _inside_bounds(cells: Array) -> bool:
	var bounds := _frame().get_bounds()
	if not bounds.has_volume():
		return cells.is_empty()
	for cell in cells:
		var center := Vector3(cell)
		if not bounds.has_point(center):
			return false
	return true


# Place one voxel on the view ray at each depth. Every one projects onto the center.
func _place_ray_voxels() -> Array[Vector3i]:
	var frame := _frame()
	frame.clear()
	var camera := camera_rig()
	var origin := camera.project_ray_origin(center)
	var direction := camera.project_ray_normal(center)
	var material := VoxelFrame.material(Color.from_rgba8(150, 150, 150))
	var cells: Array[Vector3i] = []
	for depth in RAY_DEPTHS:
		var point: Vector3 = origin + direction * depth
		var cell := Vector3i(floori(point.x + 0.5), floori(point.y + 0.5), floori(point.z + 0.5))
		if cells.has(cell):
			continue
		frame.set_cell(cell, material)
		cells.append(cell)
	return cells


func _drag_rectangle_of(cells: Array) -> Rect2:
	var camera := camera_rig()
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for cell in cells:
		var point := camera.unproject_position(Vector3(cell))
		low.x = minf(low.x, point.x)
		low.y = minf(low.y, point.y)
		high.x = maxf(high.x, point.x)
		high.y = maxf(high.y, point.y)
	var margin := Vector2(12.0, 12.0)
	return Rect2(low - margin, (high - low) + margin * 2.0)


func _drag_rectangle(rectangle: Rect2) -> void:
	_press(rectangle.position)
	for step_index in range(1, 7):
		_move_to(rectangle.position.lerp(rectangle.end, step_index / 6.0))
	_release(rectangle.end)


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
	return _options_box().get_node("empty") as Button


func _mode_button(node_name: String) -> Button:
	return _options_box().get_node(node_name) as Button


func _depth_button() -> Button:
	return _options_box().get_node("Depth") as Button


func _options_box() -> HBoxContainer:
	var option_bar := main.get_node("%OptionBar")
	for container in option_bar.get_children():
		if container.name == "Options":
			return container
	return null
