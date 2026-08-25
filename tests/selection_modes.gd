extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _seed := State.NONE
var _pair_a: Array[Vector3i] = []
var _pair_b: Array[Vector3i] = []


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("selection tools replace, add, and subtract through the mode option", _run)


func _run() -> void:
	step("Given the lasso tool with two voxel pairs on the grid", func():
		_vp = editor_viewport(_inst)
		State.set_tool(State.tools.lasso)
		var svp := _vp.get_viewport()
		var vsize: Vector2i = svp.size
		if vsize.x <= 0 or vsize.y <= 0:
			svp.size = Vector2i(800, 500)
			vsize = svp.size
		_center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
		var start := aim(_vp, _center)
		_seed = start.target
		_pair_a = [_seed, _seed + Vector3i(1, 0, 0)]
		_pair_b = [_seed + Vector3i(3, 0, 0), _seed + Vector3i(4, 0, 0)]
		var gray := Color.from_rgba8(150, 150, 150)
		var f: VoxelFrame = State.document.frames[State.current_frame]
		for c in _pair_a + _pair_b:
			f.cells[c] = gray
	)

	step("Then the option bar shows the mode buttons", func():
		var box := _options_box()
		expect(box != null, "the option bar holds an options box")
		expect(box.get_child_count() > 0, "the lasso option row is built")
	)

	step("When the user drags across the first pair", func():
		_drag_cells(_pair_a[0], _pair_a[1], false)
	)

	step("Then only the first pair is selected", func():
		_expect_exact(_pair_a, "the first pair is selected")
	)

	step("When the user drags across the second pair in replace mode", func():
		_drag_cells(_pair_b[0], _pair_b[1], false)
	)

	step("Then the second pair replaces the selection", func():
		_expect_exact(_pair_b, "the second pair replaced the selection")
	)

	step("Given the add mode option", func():
		State.set_tool_option("select", "mode", "add")
		expect(_mode_button_pressed("add"), "the add button shows as pressed after the change")
	)

	step("When the user drags across the first pair again", func():
		_drag_cells(_pair_a[0], _pair_a[1], false)
	)

	step("Then both pairs are selected", func():
		_expect_exact(_pair_a + _pair_b, "the drag added to the selection")
	)

	step("Given the subtract mode option", func():
		State.set_tool_option("select", "mode", "subtract")
	)

	step("When the user drags across the second pair again", func():
		_drag_cells(_pair_b[0], _pair_b[1], false)
	)

	step("Then the second pair leaves the selection", func():
		_expect_exact(_pair_a, "the drag subtracted from the selection")
	)

	step("Given the replace mode option again", func():
		State.set_tool_option("select", "mode", "replace")
	)

	step("When the user shift drags across the second pair", func():
		_drag_cells(_pair_b[0], _pair_b[1], true)
	)

	step("Then shift still adds to the selection", func():
		_expect_exact(_pair_a + _pair_b, "the shift drag added despite replace mode")
	)

	step("When the user undoes", func():
		State.undo_redo.undo()
	)

	step("Then the selection returns to the subtracted state", func():
		_expect_exact(_pair_a, "undo restored the one-pair selection")
	)

	step("Given the box select tool with an empty selection", func():
		State.set_tool(State.tools.select)
		State.clear_selection()
	)

	step("When the user single clicks a voxel", func():
		_click_cell(_pair_a[0])
	)

	step("Then that one voxel is selected", func():
		_expect_exact([_pair_a[0]], "the box single click selected one voxel")
	)

	step("Given the add mode option for the box tool", func():
		State.set_tool_option("select", "mode", "add")
	)

	step("When the user single clicks an empty cell", func():
		_click_cell(_seed + Vector3i(0, 0, 2))
	)

	step("Then the empty cell joins the selection", func():
		_expect_exact([_pair_a[0], _seed + Vector3i(0, 0, 2)], "the empty cell joined the selection")
	)

	step("Given the lasso tool with an empty selection", func():
		State.set_tool(State.tools.lasso)
		State.clear_selection()
	)

	step("When the user single clicks a voxel", func():
		_click_cell(_pair_b[0])
	)

	step("Then that one voxel is selected", func():
		_expect_exact([_pair_b[0]], "the lasso single click selected one voxel")
	)

	step("Given the wand tool in add mode", func():
		State.set_tool(State.tools.wand)
		State.set_tool_option("select", "mode", "add")
	)

	step("When the user clicks empty space", func():
		var pos := _empty_screen_pos()
		expect(pos != Vector2.INF, "an empty screen position exists")
		_click(pos)
	)

	step("Then the selection survives in add mode", func():
		_expect_exact([_pair_b[0]], "an empty click keeps the selection in add mode")
	)

	step("Given the wand tool in replace mode", func():
		State.set_tool_option("select", "mode", "replace")
	)

	step("When the user clicks empty space", func():
		var pos := _empty_screen_pos()
		expect(pos != Vector2.INF, "an empty screen position exists")
		_click(pos)
	)

	step("Then the selection survives in replace mode", func():
		_expect_exact([_pair_b[0]], "an empty click keeps the selection in replace mode")
	)

	step("Given a selection for the clear button", func():
		_click_cell(_pair_b[1])
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
		expect(_clear_button().disabled, "the clear button disables with an empty selection")
	)


func _clear_button() -> Button:
	var box := _options_box()
	if box == null:
		return null
	var picker := box.get_child(0)
	return picker.get_node_or_null("clear") as Button


func _click_clear() -> void:
	var b := _clear_button()
	if b == null or b.disabled:
		expect(false, "the clear button is pressable")
		return
	b.emit_signal("pressed")


func _click_cell(cell: Vector3i) -> void:
	var pos := _screen_pos_of(cell)
	if pos == Vector2.INF:
		expect(false, "the click cell is visible on screen")
		return
	_click(pos)


func _click(pos: Vector2) -> void:
	var vp := _vp.get_viewport()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	vp.push_input(press)
	press.pressed = false
	vp.push_input(press)


func _empty_screen_pos() -> Vector2:
	var svp := _vp.get_viewport()
	for dy in range(int(svp.size.y) - 20, 0, -40):
		for dx in range(20, int(svp.size.x), 40):
			var res := aim(_vp, Vector2(dx, dy))
			if res.target != State.NONE and res.hit == State.NONE:
				return Vector2(dx, dy)
	return Vector2.INF


func _expect_exact(cells: Array, msg: String) -> void:
	expect(State.selection.cells.size() == cells.size(), msg)
	for c in cells:
		expect(State.selection.contains(c), msg)


func _drag_cells(a: Vector3i, b: Vector3i, with_shift: bool) -> void:
	var pa := _screen_pos_of(a)
	var pb := _screen_pos_of(b)
	if pa == Vector2.INF or pb == Vector2.INF:
		expect(false, "both drag cells are visible on screen")
		return
	var vp := _vp.get_viewport()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pa
	press.shift_pressed = with_shift
	vp.push_input(press)
	for i in range(1, 8):
		var mm := InputEventMouseMotion.new()
		mm.position = pa.lerp(pb, float(i) / 8.0)
		mm.shift_pressed = with_shift
		mm.button_mask = MOUSE_BUTTON_MASK_LEFT
		vp.push_input(mm)
	var rel := InputEventMouseButton.new()
	rel.button_index = MOUSE_BUTTON_LEFT
	rel.pressed = false
	rel.position = pb
	rel.shift_pressed = with_shift
	vp.push_input(rel)


func _screen_pos_of(cell: Vector3i) -> Vector2:
	for step in [10, 4]:
		var pos := _scan_for(cell, step)
		if pos != Vector2.INF:
			return pos
	return Vector2.INF


func _scan_for(cell: Vector3i, grid: int) -> Vector2:
	var svp := _vp.get_viewport()
	for dy in range(0, int(svp.size.y), grid):
		for dx in range(0, int(svp.size.x), grid):
			var pos := Vector2(dx, dy)
			if aim(_vp, pos).target == cell:
				return pos
	return Vector2.INF


func _options_box() -> HBoxContainer:
	var bar := _inst.find_child("OptionsBox", true, false)
	return bar as HBoxContainer


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
