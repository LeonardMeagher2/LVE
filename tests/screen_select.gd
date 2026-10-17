extends "res://tests/test.gd"

# Screen selection projects every voxel center through the camera.
# The drag selects the full volume, including the voxels hidden behind the front one.

const RAY_DEPTHS := [4.0, 7.0, 10.0]
# The sparse frame spans 31 cells on each axis.
const SPARSE_FIRST := Vector3i(0, 0, 0)
const SPARSE_SECOND := Vector3i(30, 30, 30)
const SPARSE_CELLS := 31 * 31 * 31

var viewport: SubViewport
var center := Vector2.ZERO
var ray_cells: Array[Vector3i] = []
var band_before: Image = null
var band_during: Image = null
var block_cells: Array[Vector3i] = []
var block_rectangle := Rect2()
var sparse_first := SPARSE_FIRST
var sparse_second := SPARSE_SECOND
var sparse_rectangle := Rect2()


func _ready() -> void:
	timeout = 30.0
	test("a screen drag selects the voxels behind the pointer", _run)


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

	step("Then the option row shows the empty cell button", func():
		expect(_empty_button() != null, "the option row holds an empty cell button")
		expect(_empty_button().icon != null, "the empty cell button shows its icon")
		expect(_empty_button().button_pressed, "the empty cell option is on by default")
		expect(ray_cells.size() == 3, "the view ray holds three voxels at different depths")
	)

	step("Given the empty cell option off", func():
		_empty_button().button_pressed = false
	)

	step("When the user drags a screen rectangle around the projected voxels", func():
		_drag_rectangle(_drag_rectangle_of(ray_cells))
	)

	step("Then every voxel along the ray is selected", func():
		for cell in ray_cells:
			expect(State.selection.contains(cell), "the voxel %s behind the front voxel is selected" % cell)
	)

	step("Given the subtract mode", func():
		_press_mode("subtract")
	)

	step("When the user drags the same rectangle again", func():
		_drag_rectangle(_drag_rectangle_of(ray_cells))
	)

	step("Then the ray voxels leave the selection", func():
		for cell in ray_cells:
			expect(not State.selection.contains(cell), "subtract removes the voxel %s" % cell)
	)

	step("When the user undoes the subtract", func():
		State.undo_redo.undo()
	)

	step("Then the selection returns", func():
		expect(State.selection.count() == ray_cells.size(), "undo restores the projected selection")
	)

	step("Given the X symmetry plane and the replace mode", func():
		State.symmetry_axes = 1
		State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
		_press_mode("replace")
	)

	step("When the user drags the rectangle with symmetry", func():
		_drag_rectangle(_drag_rectangle_of(ray_cells))
	)

	step("Then the reflected voxel joins the selection", func():
		var front := ray_cells[0]
		var reflected := Vector3i(-1 - front.x, front.y, front.z)
		expect(State.selection.contains(reflected), "the reflected cell %s joins the selection" % reflected)
		State.symmetry_axes = 0
	)

	step("Given the lasso tool", func():
		select_toolbar_item("selection", "Lasso")
		State.selection.clear()
		State.selection_changed.emit()
	)

	step("When the user draws a screen lasso around the projected voxels", func():
		_drag_lasso(_drag_rectangle_of(ray_cells))
	)

	step("Then every voxel along the ray is selected", func():
		for cell in ray_cells:
			expect(State.selection.contains(cell), "the lasso selects the voxel %s" % cell)
	)

	step("Given the box tool and an orthogonal camera", func():
		select_toolbar_item("selection", "Box")
		State.selection.clear()
		State.selection_changed.emit()
		camera_rig().is_orthogonal = true
		ray_cells = _place_ray_voxels()
	)

	step("When the user drags a screen rectangle in the orthogonal view", func():
		_drag_rectangle(_drag_rectangle_of(ray_cells))
	)

	step("Then every voxel along the ray is selected", func():
		for cell in ray_cells:
			expect(State.selection.contains(cell), "the orthogonal view selects the voxel %s" % cell)
	)

	step("Given the front view", func():
		State.selection.clear()
		State.selection_changed.emit()
		camera_rig().is_orthogonal = false
		camera_rig().set_view("front")
		ray_cells = _place_ray_voxels()
	)

	step("When the user drags a screen rectangle in the front view", func():
		_drag_rectangle(_drag_rectangle_of(ray_cells))
	)

	step("Then every voxel along the ray is selected", func():
		for cell in ray_cells:
			expect(State.selection.contains(cell), "the front view selects the voxel %s" % cell)
	)

	step("Given an empty selection before the band check", func():
		State.selection.clear()
		State.selection_changed.emit()
	)

	if DisplayServer.get_name() != "headless":
		await get_tree().process_frame
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		band_before = viewport.get_texture().get_image()

	step("Given a large screen drag in progress", func():
		_press(Vector2(20, 20))
		_move_to(Vector2(780, 480))
	)

	await _capture_band()

	step("Then the band draws over the viewport", func():
		if band_before == null:
			return
		expect(_changed_pixels(band_before, band_during, 18, 23) > 50, "the band draws over the viewport")
	)

	step("When the user releases the drag", func():
		_release(Vector2(780, 480))
	)

	step("Then the band hides and the selection is applied", func():
		expect(not _band().visible, "the band hides after the release")
		expect(State.selection.contains(ray_cells[0]), "the released drag applies its selection")
	)

	step("Given a solid block larger than the immediate limit", func():
		select_toolbar_item("selection", "Box")
		camera_rig().is_orthogonal = false
		camera_rig().set_view("default")
		State.selection.clear()
		State.selection_changed.emit()
		block_cells = _place_block(18)
		camera_rig().center_on(_frame().get_bounds())
		block_rectangle = _drag_rectangle_of(block_cells)
		expect(block_cells.size() > 4096, "the block holds more voxels than the immediate limit")
		expect(block_rectangle.position.x >= 0.0 and block_rectangle.end.x < viewport.size.x, "the drag rectangle fits the viewport width")
		expect(block_rectangle.position.y >= 0.0 and block_rectangle.end.y < viewport.size.y, "the drag rectangle fits the viewport height")
	)

	step("When the user drags a screen rectangle around the block", func():
		_drag_rectangle(block_rectangle)
	)

	step("Then the projection continues in the background", func():
		expect(State.selection.count() < block_cells.size(), "the large projection is not finished at the release")
	)

	await _await_selection(block_cells.size())

	step("Then the projection selects the whole block", func():
		expect(State.selection.count() == block_cells.size(), "every voxel of the block is selected")
		expect(State.selection.contains(block_cells[0]), "the near corner of the block is selected")
		expect(State.selection.contains(block_cells[block_cells.size() - 1]), "the far corner of the block is selected")
	)

	step("Given two voxels at opposite corners of a sparse frame", func():
		select_toolbar_item("selection", "Box")
		_empty_button().button_pressed = true
		State.selection.clear()
		State.selection_changed.emit()
		camera_rig().is_orthogonal = true
		camera_rig().set_view("top")
		var frame := _frame()
		frame.clear()
		var material := VoxelFrame.material(Color.from_rgba8(150, 150, 150))
		frame.set_cell(sparse_first, material)
		frame.set_cell(sparse_second, material)
		camera_rig().center_on(frame.get_bounds())
		sparse_rectangle = _drag_rectangle_of([sparse_first, sparse_second])
		expect(sparse_rectangle.position.x >= 0.0 and sparse_rectangle.end.x < viewport.size.x, "the sparse rectangle fits the viewport width")
		expect(sparse_rectangle.position.y >= 0.0 and sparse_rectangle.end.y < viewport.size.y, "the sparse rectangle fits the viewport height")
	)

	step("When the user drags a rectangle over the sparse frame", func():
		_drag_rectangle(sparse_rectangle)
	)

	await _await_selection(SPARSE_CELLS)

	step("Then the empty cells fill the frame bounds", func():
		expect(State.selection.count() == SPARSE_CELLS, "the selection holds every cell inside the frame bounds")
		expect(State.selection.contains(sparse_first), "the first sparse voxel is selected")
		expect(State.selection.contains(sparse_second), "the far sparse voxel is selected")
		expect(State.selection.contains(Vector3i(15, 15, 15)), "an empty cell inside the bounds is selected")
	)

	step("When the user drags again and cancels the job", func():
		_drag_rectangle(sparse_rectangle)
		expect(State.edit_busy(), "the sparse projection runs on a worker")
		var event := InputEventKey.new()
		event.keycode = KEY_ESCAPE
		event.pressed = true
		viewport.push_input(event)
	)

	await _await_idle()

	step("Then the cancelled projection keeps the earlier selection", func():
		expect(State.selection.count() == SPARSE_CELLS, "the cancelled projection leaves the selection unchanged")
	)


func _capture_band() -> void:
	if DisplayServer.get_name() == "headless":
		return
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	band_during = viewport.get_texture().get_image()


func _changed_pixels(first: Image, second: Image, first_row: int, last_row: int) -> int:
	var changed := 0
	for y in range(first_row, last_row):
		for x in first.get_width():
			var a := first.get_pixel(x, y)
			var b := second.get_pixel(x, y)
			if absf(a.r - b.r) > 0.1 or absf(a.g - b.g) > 0.1 or absf(a.b - b.b) > 0.1:
				changed += 1
	return changed


func _frame() -> VoxelFrame:
	return State.document.frames[State.current_frame]


# Wait for the worker job of a large screen selection.
func _await_selection(count: int) -> void:
	for _frame_index in 600:
		if State.selection.count() == count:
			return
		await get_tree().process_frame


func _await_idle() -> void:
	for _frame_index in 600:
		if not State.edit_busy():
			return
		await get_tree().process_frame


# Fill one solid block around the origin.
func _place_block(size: int) -> Array[Vector3i]:
	var frame := _frame()
	frame.clear()
	var material := VoxelFrame.material(Color.from_rgba8(150, 150, 150))
	var cells: Array[Vector3i] = []
	var half := size / 2
	for x in range(-half, half):
		for y in range(-half, half):
			for z in range(-half, half):
				var cell := Vector3i(x, y, z)
				frame.set_cell(cell, material)
				cells.append(cell)
	return cells


# Place one voxel on the view ray at each depth. Every one projects onto the center.
func _place_ray_voxels() -> Array[Vector3i]:
	var frame := _frame()
	frame.clear()
	var camera := camera_rig()
	var origin := camera.project_ray_origin(center)
	var direction := camera.project_ray_normal(center)
	var gray := Color.from_rgba8(150, 150, 150)
	var cells: Array[Vector3i] = []
	for depth in RAY_DEPTHS:
		var point: Vector3 = origin + direction * depth
		var cell := Vector3i(floori(point.x + 0.5), floori(point.y + 0.5), floori(point.z + 0.5))
		if cells.has(cell):
			continue
		frame.set_cell(cell, VoxelFrame.material(gray))
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


func _drag_lasso(rectangle: Rect2) -> void:
	var corners := [
		rectangle.position,
		Vector2(rectangle.end.x, rectangle.position.y),
		rectangle.end,
		Vector2(rectangle.position.x, rectangle.end.y),
	]
	_press(corners[0])
	for corner in corners:
		_move_to(corner)
	_release(corners[0])


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
