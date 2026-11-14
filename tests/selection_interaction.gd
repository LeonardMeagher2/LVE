extends "res://tests/test.gd"

# One process runs the screen-selection tests. Each test keeps the steps and
# checks of its original scene. The user arguments after `--` name the tests to
# run, so an old scene name still selects its own test.

# A screen drag selects the volume behind the shape.
# The empty cell option adds the empty grid cells inside the frame bounds.
# The depth test keeps the voxels that the camera sees.

const RAY_DEPTHS := [4.0, 7.0, 10.0]
const PLATE_SIZE := 5
const MARKER := Vector3i(20, 0, 20)

var _selection_settings := preload("res://plugins/selection/settings.tres")

var viewport: SubViewport
var center := Vector2.ZERO
var ray_cells: Array[Vector3i] = []
var click_cell := VoxelPicking.NONE
var far_cell := VoxelPicking.NONE
var empty_cell := VoxelPicking.NONE
var plate_frame: VoxelFrame
var spacing := 0.0
var _defaults_ready := false
var _default_mode := 0
var _default_empty := false
var _default_depth := true
var _default_connected := true


func _ready() -> void:
	test("a drag selects the volume behind the shape, the empty cells, and the depth test front layer", _selection, "selection")
	test("a click selects the voxels under the pointer and the optional empty cells", _selection_click, "selection_click")
	test("the lasso selects the volume inside a dragged outline", _lasso, "lasso")
	test("a click away from the voxel center selects that voxel", _click_off_center, "click_off_center")
	test("a double click with the box or lasso tool selects every voxel", _double_click_select_all, "double_click_select_all")


# Each test starts from a fresh document, the default selection options, and the
# default camera. The selection options and the camera view live outside the
# document, so they are restored here.
func before_test() -> void:
	if not _defaults_ready:
		_default_mode = _selection_settings.mode
		_default_empty = _selection_settings.include_empty
		_default_depth = _selection_settings.depth_test
		_default_connected = _selection_settings.connected
		_defaults_ready = true
	State.stop()
	State.document = VoxelDocument.new()
	_selection_settings.mode = _default_mode
	_selection_settings.include_empty = _default_empty
	_selection_settings.depth_test = _default_depth
	_selection_settings.connected = _default_connected
	camera_rig().is_orthogonal = false
	camera_rig().set_view("default")


# Shared viewport setup. Every test uses the same view, center, and tool.
func _view_setup() -> void:
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	center = Vector2(400.0, 250.0)
	activate_tool("selection")


# Shared input helpers. Every test drives the real viewport input path.
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


func _click(pos: Vector2) -> void:
	_press(pos)
	_release(pos)


func _double_click(pos: Vector2) -> void:
	_click(pos)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.double_click = true
	press.position = pos
	viewport.push_input(press)
	_release(pos)


# Shared option and screen helpers.
func _options_box() -> HBoxContainer:
	var option_bar := main.get_node("%OptionBar")
	for container in option_bar.get_children():
		if container.name == "Options":
			return container
	return null


func _mode_button(node_name: String) -> Button:
	var box := _options_box()
	if box == null:
		return null
	return box.get_node(node_name) as Button


func _empty_button() -> Button:
	var box := _options_box()
	if box == null:
		return null
	return box.get_node("empty") as Button


func _depth_button() -> Button:
	var box := _options_box()
	if box == null:
		return null
	return box.get_node("Depth") as Button


func _frame() -> VoxelFrame:
	return State.document.frames[State.current_frame]


func _screen_of(cell_position: Vector3i) -> Vector2:
	return camera_rig().unproject_position(Vector3(cell_position))


func _selection() -> void:
	step("Given the box tool and voxels along the view ray", func():
		_view_setup()
		select_toolbar_item("selection", "Box")
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


func _selection_click() -> void:
	step("Given the box tool and two voxels with a gap", func():
		_view_setup()
		select_toolbar_item("selection", "Box")
		click_cell = aim(center).target
		far_cell = click_cell + Vector3i(3, 0, 0)
		empty_cell = click_cell + Vector3i(1, 0, 0)
		var material := VoxelFrame.material(Color.from_rgba8(150, 150, 150))
		_frame().set_cell(click_cell, material)
		_frame().set_cell(far_cell, material)
	)

	step("Then the depth test is on by default and the empty cells are off", func():
		expect(_depth_button().button_pressed, "the depth test is on by default")
		expect(not _empty_button().button_pressed, "the empty cells are off by default")
	)

	step("Given the depth test off and the empty cell option on", func():
		_depth_button().button_pressed = false
		_empty_button().button_pressed = true
	)

	step("When the user clicks the first voxel", func():
		_click(_screen_of(click_cell))
	)

	step("Then that voxel is selected without the far voxel", func():
		expect(State.selection.contains(click_cell), "the clicked voxel is selected")
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
		expect(not State.selection.contains(click_cell), "the empty click leaves the first voxel out")
		expect(not State.selection.contains(far_cell), "the empty click leaves the far voxel out")
		for selected in State.selection.to_array():
			expect(not _frame().has(selected), "the selected cell %s is empty" % selected)
	)


func _lasso() -> void:
	step("Given the lasso tool and a plate of voxels", func():
		_view_setup()
		select_toolbar_item("selection", "Lasso")
		_empty_button().button_pressed = true
		camera_rig().is_orthogonal = true
		camera_rig().set_view("top")
		plate_frame = State.document.frames[State.current_frame]
		_place_plate()
		camera_rig().center_on(_plate_bounds())
		spacing = _screen_of(Vector3i.ZERO).distance_to(_screen_of(Vector3i(1, 0, 0)))
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
			points.append(_screen_of(Vector3i(index, 0, 0)))
		_drag_path(points)
	)
	step("Then a drag with no enclosed area selects nothing", func():
		expect(State.selection.is_empty(), "the straight drag leaves the selection empty")
	)

	step("When the user clicks a voxel without dragging", func():
		_click(_screen_of(Vector3i.ZERO))
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
		var corner := _screen_of(Vector3i(1, 0, 1))
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


func _click_off_center() -> void:
	step("Given the box tool, a plate, and the top view", func():
		_view_setup()
		select_toolbar_item("selection", "Box")
		camera_rig().is_orthogonal = true
		camera_rig().set_view("top")
		plate_frame = State.document.frames[State.current_frame]
		_place_plate()
		camera_rig().center_on(_plate_bounds())
		spacing = _screen_of(Vector3i.ZERO).distance_to(_screen_of(Vector3i(1, 0, 0)))
		expect(spacing > 20.0, "the voxel spacing is wide enough for an off-center click")
	)

	step("When the user clicks away from the center of a voxel", func():
		var point := _screen_of(Vector3i(1, 0, 1)) + Vector2(spacing, spacing) * 0.25
		expect(aim(point).target == Vector3i(1, 0, 1), "the box click point stays over the voxel")
		_click(point)
	)

	step("Then only the voxel under the pointer is selected", func():
		expect(State.selection.count() == 1, "the off-center click selects one cell")
		expect(State.selection.contains(Vector3i(1, 0, 1)), "the clicked voxel is selected")
	)

	step("Given the lasso tool and an empty selection", func():
		select_toolbar_item("selection", "Lasso")
		State.clear_selection()
	)

	step("When the user clicks away from the center of another voxel", func():
		var point := _screen_of(Vector3i(3, 0, 3)) + Vector2(spacing, spacing) * 0.25
		expect(aim(point).target == Vector3i(3, 0, 3), "the lasso click point stays over the voxel")
		_click(point)
	)

	step("Then only the lasso-clicked voxel is selected", func():
		expect(State.selection.count() == 1, "the lasso off-center click selects one cell")
		expect(State.selection.contains(Vector3i(3, 0, 3)), "the lasso clicked voxel is selected")
	)


func _double_click_select_all() -> void:
	step("Given the box tool and a plate of voxels", func():
		_view_setup()
		select_toolbar_item("selection", "Box")
		plate_frame = State.document.frames[State.current_frame]
		_place_plate()
	)

	step("When the user double-clicks a voxel", func():
		var point := _screen_of(Vector3i(2, 0, 2))
		expect(aim(point).target == Vector3i(2, 0, 2), "the double click point hits the voxel")
		_double_click(point)
	)

	step("Then every voxel in the current frame is selected", func():
		var cells := _frame().positions()
		expect(State.selection.count() == cells.size(), "the double click selects every voxel")
		for cell in cells:
			expect(State.selection.contains(cell), "the selected cells include %s" % cell)
		expect(not State.selection.contains(Vector3i(-1, 0, -1)), "the double click leaves empty cells out")
	)

	step("Given the lasso tool and an empty selection", func():
		select_toolbar_item("selection", "Lasso")
		State.clear_selection()
	)

	step("When the user double-clicks a voxel with the lasso", func():
		var point := _screen_of(Vector3i(2, 0, 2))
		expect(aim(point).target == Vector3i(2, 0, 2), "the lasso double click point hits the voxel")
		_double_click(point)
	)

	step("Then the lasso double click also selects every voxel", func():
		var cells := _frame().positions()
		expect(State.selection.count() == cells.size(), "the lasso double click selects every voxel")
		for cell in cells:
			expect(State.selection.contains(cell), "the lasso selected cells include %s" % cell)
		expect(not State.selection.contains(Vector3i(-1, 0, -1)), "the lasso double click leaves empty cells out")
	)


func _place_plate() -> void:
	var material := VoxelFrame.material(Color.from_rgba8(150, 150, 150))
	for x in PLATE_SIZE:
		for z in PLATE_SIZE:
			plate_frame.set_cell(Vector3i(x, 0, z), material)
	plate_frame.set_cell(MARKER, material)


func _plate_bounds() -> AABB:
	return AABB(Vector3(-0.5, -0.5, -0.5), Vector3(PLATE_SIZE, 1, PLATE_SIZE))


# The four cells of a two-by-two block on the plate layer.
func _block(low: Vector3i) -> Array:
	return [low, low + Vector3i(1, 0, 0), low + Vector3i(0, 0, 1), low + Vector3i(1, 0, 1)]


# Draw a rectangular outline around the block with a margin below half a cell.
func _lasso_around(cells: Array) -> void:
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for cell in cells:
		var point := _screen_of(cell)
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


func _drag_path(points: Array) -> void:
	_press(points[0])
	for index in range(1, points.size()):
		_move_to(points[index])
	_release(points[points.size() - 1])


func _press_mode(node_name: String) -> void:
	var button := _mode_button(node_name)
	if button != null:
		button.button_pressed = true


func _band() -> Line2D:
	var selection_plugin := plugin("SelectionPlugin")
	if selection_plugin == null or selection_plugin._current_tool == null:
		return null
	return selection_plugin._current_tool.get_node("ScreenBand")
