extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var seed := VoxelPicking.NONE
var pair_a: Array[Vector3i] = []
var pair_b: Array[Vector3i] = []


func _ready() -> void:
	test("selection tools replace, add, and subtract through the mode option", _run)


func _run() -> void:
	step("Given the lasso tool with two voxel pairs on the grid", func():
		viewport = editor_viewport()
		activate_tool("selection")
		select_toolbar_item("selection", "Lasso")
		var vsize: Vector2i = viewport.size
		if vsize.x <= 0 or vsize.y <= 0:
			viewport.size = Vector2i(800, 500)
			vsize = viewport.size
		center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
		var start := aim(center)
		seed = start.target
		pair_a = [seed, seed + Vector3i(1, 0, 0)]
		pair_b = [seed + Vector3i(3, 0, 0), seed + Vector3i(4, 0, 0)]
		var gray := Color.from_rgba8(150, 150, 150)
		var f: VoxelFrame = State.document.frames[State.current_frame]
		for c in pair_a + pair_b:
			f.set_cell(c, VoxelFrame.material(gray))
	)

	step("Then the option bar shows the mode buttons", func():
		var box := _options_box()
		expect(box != null, "the option bar holds an options box")
		expect(box.get_child_count() > 0, "the lasso option row is built")
	)

	step("When the user drags across the first pair", func():
		_drag_cells(pair_a[0], pair_a[1], false)
	)

	step("Then only the first pair is selected", func():
		_expect_exact(pair_a, "the first pair is selected")
	)

	step("When the user drags across the second pair in replace mode", func():
		_drag_cells(pair_b[0], pair_b[1], false)
	)

	step("Then the second pair replaces the selection", func():
		_expect_exact(pair_b, "the second pair replaced the selection")
	)

	step("Given the add mode option", func():
		press_option("Add")
		expect(_mode_button_pressed("add"), "the add button shows as pressed after the change")
	)

	step("When the user drags across the first pair again", func():
		_drag_cells(pair_a[0], pair_a[1], false)
	)

	step("Then both pairs are selected", func():
		_expect_exact(pair_a + pair_b, "the drag added to the selection")
	)

	step("Given the subtract mode option", func():
		press_option("Subtract")
	)

	step("When the user drags across the second pair again", func():
		_drag_cells(pair_b[0], pair_b[1], false)
	)

	step("Then the second pair leaves the selection", func():
		_expect_exact(pair_a, "the drag subtracted from the selection")
	)

	step("Given the add mode option again", func():
		press_option("Add")
	)

	step("When the user drags across the second pair", func():
		_drag_cells(pair_b[0], pair_b[1], false)
	)

	step("Then the add drag joins the selection", func():
		_expect_exact(pair_a + pair_b, "the add drag added to the selection")
	)

	step("When the user undoes", func():
		State.undo_redo.undo()
	)

	step("Then the selection returns to the subtracted state", func():
		_expect_exact(pair_a, "undo restored the one-pair selection")
	)

	step("Given the box select tool with an empty selection", func():
		select_toolbar_item("selection", "Box")
		State.clear_selection()
	)

	step("When the user single clicks a voxel", func():
		_click_cell(pair_a[0])
	)

	step("Then that one voxel is selected", func():
		_expect_exact([pair_a[0]], "the box single click selected one voxel")
	)

	step("Given the add mode option for the box tool", func():
		press_option("Add")
	)

	step("When the user single clicks the second voxel", func():
		_click_cell(pair_b[0])
	)

	step("Then the second voxel joins the selection", func():
		_expect_exact([pair_a[0], pair_b[0]], "the second voxel joined the selection")
	)

	step("Given the lasso tool with an empty selection", func():
		select_toolbar_item("selection", "Lasso")
		State.clear_selection()
	)

	step("When the user single clicks a voxel", func():
		_click_cell(pair_b[0])
	)

	step("Then that one voxel is selected", func():
		_expect_exact([pair_b[0]], "the lasso single click selected one voxel")
	)

	step("Given the wand tool in add mode", func():
		select_toolbar_item("selection", "Wand")
		press_option("Add")
	)

	step("When the user clicks empty space", func():
		var pos := _empty_screen_pos()
		expect(pos != Vector2.INF, "an empty screen position exists")
		_click(pos)
	)

	step("Then the selection survives in add mode", func():
		_expect_exact([pair_b[0]], "an empty click keeps the selection in add mode")
	)

	step("Given the wand tool in replace mode", func():
		press_option("Replace")
	)

	step("When the user clicks empty space", func():
		var pos := _empty_screen_pos()
		expect(pos != Vector2.INF, "an empty screen position exists")
		_click(pos)
	)

	step("Then the selection survives in replace mode", func():
		_expect_exact([pair_b[0]], "an empty click keeps the selection in replace mode")
	)

	step("Given a selection for the clear button", func():
		_click_cell(pair_b[1])
		expect(not State.selection.is_empty(), "the wand click selected the voxel")
	)

	step("Given the clear button in the option bar", func():
		expect(_clear_button() != null, "the option bar shows a clear button")
		expect(not _clear_button().disabled, "the clear button is enabled while a selection exists")
	)

	step("When the user presses the clear button", func():
		_click_clear()
	)

	step("Then the selection empties", func():
		expect(State.selection.is_empty(), "the clear button emptied the selection")
	)


func _clear_button() -> Button:
	var box := _options_box()
	if box == null:
		return null
	return box.get_node_or_null("clear") as Button


func _click_clear() -> void:
	var b := _clear_button()
	if b == null or b.disabled:
		expect(false, "the clear button is pressable")
		return
	b.emit_signal("pressed")


func _click_cell(cell: Vector3i) -> void:
	_click(camera_rig().unproject_position(Vector3(cell)))


func _click(pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	viewport.push_input(press)
	press.pressed = false
	viewport.push_input(press)


func _empty_screen_pos() -> Vector2:
	for dy in range(int(viewport.size.y) - 20, 0, -40):
		for dx in range(20, int(viewport.size.x), 40):
			var res := aim(Vector2(dx, dy))
			if res.target != VoxelPicking.NONE and res.hit == VoxelPicking.NONE:
				return Vector2(dx, dy)
	return Vector2.INF


func _expect_exact(cells: Array, msg: String) -> void:
	expect(State.selection.cells.size() == cells.size(), msg)
	for c in cells:
		expect(State.selection.contains(c), msg)


# Draw a lasso around both cells. A straight path would collapse the polygon.
func _drag_cells(a: Vector3i, b: Vector3i, with_shift: bool) -> void:
	var pa := camera_rig().unproject_position(Vector3(a))
	var pb := camera_rig().unproject_position(Vector3(b))
	var low := Vector2(minf(pa.x, pb.x), minf(pa.y, pb.y)) - Vector2(8, 8)
	var high := Vector2(maxf(pa.x, pb.x), maxf(pa.y, pb.y)) + Vector2(8, 8)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = low
	press.shift_pressed = with_shift
	viewport.push_input(press)
	for corner in [Vector2(high.x, low.y), high, Vector2(low.x, high.y)]:
		var motion := InputEventMouseMotion.new()
		motion.position = corner
		motion.shift_pressed = with_shift
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		viewport.push_input(motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = low
	release.shift_pressed = with_shift
	viewport.push_input(release)


func _options_box() -> HBoxContainer:
	return _find_option_container("Options") as HBoxContainer


func _find_option_container(node_name: String) -> Node:
	var option_bar := main.get_node("%OptionBar")
	for container in option_bar.get_children():
		if container.name == node_name:
			return container
	return null


func _mode_button_pressed(value: String) -> bool:
	var box := _options_box()
	if box == null:
		return false
	var b := _find_button(box, value)
	return b != null and b.button_pressed


func _find_button(node: Node, value: String) -> Button:
	for c in node.get_children():
		var b := c as Button
		if b != null and (b.text == value.capitalize()
				or b.tooltip_text == value.capitalize()):
			return b
		var found := _find_button(c, value)
		if found != null:
			return found
	return null
