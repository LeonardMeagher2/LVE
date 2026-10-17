extends "res://tests/test.gd"

# The lasso selects the volume behind a dragged screen outline.
# The outline bounds a polygon. A drag with no enclosed area selects nothing.

const PLATE_SIZE := 5
const MARKER := Vector3i(20, 0, 20)

var viewport: SubViewport
var frame: VoxelFrame
var spacing := 0.0


func _ready() -> void:
	test("the lasso selects the volume inside a dragged outline", _run)


func _run() -> void:
	step("Given the lasso tool and a plate of voxels", func():
		viewport = editor_viewport()
		viewport.get_parent().stretch = false
		viewport.size = Vector2i(800, 500)
		State.document = VoxelDocument.new()
		frame = State.document.frames[State.current_frame]
		activate_tool("selection")
		select_toolbar_item("selection", "Lasso")
		_empty_button().button_pressed = true
		camera_rig().is_orthogonal = true
		camera_rig().set_view("top")
		_place_plate()
		camera_rig().center_on(_plate_bounds())
		spacing = _screen_pos_of(Vector3i.ZERO).distance_to(_screen_pos_of(Vector3i(1, 0, 0)))
		expect(spacing > 20.0, "the voxel spacing is wide enough for the outline points")
	)

	step("When the user draws a loop around a corner of the plate", func():
		_lasso_around(_block(Vector3i(1, 0, 1)))
	)
	step("Then only the enclosed cells are selected", func():
		expect(State.selection.contains(Vector3i(1, 0, 1)), "the first enclosed voxel is selected")
		expect(State.selection.contains(Vector3i(2, 0, 2)), "the far enclosed voxel is selected")
		expect(State.selection.count() == 4, "the loop selects the four enclosed cells")
		expect(not State.selection.contains(Vector3i(0, 0, 0)), "a voxel outside the loop stays unselected")
		expect(not State.selection.contains(MARKER), "the distant marker stays unselected")
	)

	step("Given the add mode", func():
		_press_mode("add")
	)
	step("When the user draws a second loop at the far corner", func():
		_lasso_around(_block(Vector3i(3, 0, 3)))
	)
	step("Then the add holds both regions", func():
		expect(State.selection.count() == 8, "the add holds both enclosed regions")
		expect(State.selection.contains(Vector3i(1, 0, 1)), "the first region survives the add")
		expect(State.selection.contains(Vector3i(4, 0, 4)), "the second region joins the selection")
	)

	step("Given the subtract mode", func():
		_press_mode("subtract")
	)
	step("When the user draws the second loop again", func():
		_lasso_around(_block(Vector3i(3, 0, 3)))
	)
	step("Then the second region leaves the selection", func():
		expect(State.selection.count() == 4, "the subtract removes the second region")
		expect(State.selection.contains(Vector3i(1, 0, 1)), "the first region survives the subtract")
	)

	step("When the user undoes the subtract", func():
		State.undo_redo.undo()
	)
	step("Then the selection returns", func():
		expect(State.selection.count() == 8, "undo restores the subtracted region")
	)

	step("Given the replace mode and a cleared selection", func():
		_press_mode("replace")
		State.clear_selection()
	)
	step("When the user drags a straight line across the plate", func():
		var points: Array[Vector2] = []
		for index in PLATE_SIZE:
			points.append(_screen_pos_of(Vector3i(index, 0, 0)))
		_drag_path(points)
	)
	step("Then a drag with no enclosed area selects nothing", func():
		expect(State.selection.is_empty(), "the straight drag leaves the selection empty")
	)

	step("When the user clicks a voxel without dragging", func():
		_click(_screen_pos_of(Vector3i.ZERO))
	)
	step("Then the click selects the voxel under the pointer", func():
		expect(State.selection.count() == 1, "the click selects one cell")
		expect(State.selection.contains(Vector3i.ZERO), "the clicked voxel is selected")
		expect(not State.selection.contains(MARKER), "the distant marker stays unselected")
	)

	step("Given the replace mode and a cleared selection", func():
		State.clear_selection()
	)
	step("When the user presses Escape during a loop drag", func():
		var corner := _screen_pos_of(Vector3i(1, 0, 1))
		_press(corner)
		_move_to(corner + Vector2(spacing * 2.0, spacing * 2.0))
		var event := InputEventKey.new()
		event.keycode = KEY_ESCAPE
		event.pressed = true
		viewport.push_input(event)
		_release(corner)
	)
	step("Then the cancelled drag selects nothing and hides the band", func():
		expect(State.selection.is_empty(), "Escape cancels the drag without selecting")
		expect(not _band().visible, "the band hides after the cancel")
	)


func _place_plate() -> void:
	var material := VoxelFrame.material(Color.from_rgba8(150, 150, 150))
	for x in PLATE_SIZE:
		for z in PLATE_SIZE:
			frame.set_cell(Vector3i(x, 0, z), material)
	frame.set_cell(MARKER, material)


func _plate_bounds() -> AABB:
	return AABB(Vector3(-0.5, -0.5, -0.5), Vector3(PLATE_SIZE, 1, PLATE_SIZE))


# The four cells of a two-by-two block on the plate layer.
func _block(low: Vector3i) -> Array:
	return [low, low + Vector3i(1, 0, 0), low + Vector3i(0, 0, 1), low + Vector3i(1, 0, 1)]


func _screen_pos_of(cell: Vector3i) -> Vector2:
	return camera_rig().unproject_position(Vector3(cell))


# Draw a rectangular outline around the block with a margin below half a cell.
func _lasso_around(cells: Array) -> void:
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for cell in cells:
		var point := _screen_pos_of(cell)
		low.x = minf(low.x, point.x)
		low.y = minf(low.y, point.y)
		high.x = maxf(high.x, point.x)
		high.y = maxf(high.y, point.y)
	var margin := Vector2(spacing, spacing) * 0.35
	var corners := [
		low - margin,
		Vector2(high.x + margin.x, low.y - margin.y),
		high + margin,
		Vector2(low.x - margin.x, high.y + margin.y),
	]
	_press(corners[0])
	for corner in corners:
		_move_to(corner)
	_release(corners[0])


func _click(pos: Vector2) -> void:
	_drag_path([pos])


func _drag_path(points: Array) -> void:
	_press(points[0])
	for index in range(1, points.size()):
		_move_to(points[index])
	_release(points[points.size() - 1])


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


func _press_mode(node_name: String) -> void:
	var button := _options_box().get_node(node_name) as Button
	button.button_pressed = true


func _band() -> Control:
	var selection_plugin := plugin("SelectionPlugin")
	if selection_plugin == null or selection_plugin._current_tool == null:
		return null
	return selection_plugin._current_tool.get_node("ScreenBand")


func _empty_button() -> Button:
	var selection_plugin := plugin("SelectionPlugin")
	if selection_plugin == null:
		return null
	return selection_plugin._options.get_node("empty") as Button


func _options_box() -> HBoxContainer:
	var option_bar := main.get_node("%OptionBar")
	for container in option_bar.get_children():
		if container.name == "Options":
			return container
	return null
