extends "res://tests/test.gd"

const MATERIAL_A := {"emission": Color(1, 0, 0), "metallic": 0.25, "roughness": 1.0}
const MATERIAL_B := {"emission": Color(0, 1, 0), "metallic": 0.5, "roughness": 0.75}
const MATERIAL_C := {"emission": Color(0, 0, 1), "metallic": 1.0, "roughness": 0.25}

var viewport: SubViewport


func _ready() -> void:
	test("the move and rotate tools carry the voxel materials with the cells", _run)


func _run() -> void:
	step("Given a bar of three voxels with one material each, selected, and the move tool", func():
		_view_setup()
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_paint_bar()
		_select_bar()
		activate_tool("transform")
	)

	step("When the user drags the bar one voxel right and commits", func():
		_press_at(_screen(Vector3(0, 0, 0)))
		_move_to(_screen(Vector3(1, 0, 0)))
		_release_at(_screen(Vector3(1, 0, 0)))
		_press_option("Commit")
	)

	step("Then each voxel keeps its material", func():
		_expect_cells([Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(3, 0, 0)])
		_expect_material(Vector3i(1, 0, 0), MATERIAL_A)
		_expect_material(Vector3i(2, 0, 0), MATERIAL_B)
		_expect_material(Vector3i(3, 0, 0), MATERIAL_C)
		expect(not _frame().has(Vector3i(0, 0, 0)), "the vacated cell is empty")
	)

	step("When the user undoes the move", func():
		State.undo_redo.undo()
	)

	step("Then the materials return to the origin", func():
		_expect_cells([Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)])
		_expect_material(Vector3i(0, 0, 0), MATERIAL_A)
		_expect_material(Vector3i(1, 0, 0), MATERIAL_B)
		_expect_material(Vector3i(2, 0, 0), MATERIAL_C)
		expect(not _frame().has(Vector3i(3, 0, 0)), "the destination cell is empty")
	)

	step("Given a selected voxel with a stationary voxel in its path", func():
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_frame().set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.from_rgba8(200, 60, 60), MATERIAL_A.emission, MATERIAL_A.metallic, MATERIAL_A.roughness))
		_frame().set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.from_rgba8(40, 120, 40), MATERIAL_B.emission, MATERIAL_B.metallic, MATERIAL_B.roughness))
		State.selection.add(Vector3i(0, 0, 0))
		State.selection_changed.emit()
		activate_tool("transform")
	)

	step("When the user drags the voxel across the stationary voxel and past it", func():
		_press_at(_screen(Vector3(0, 0, 0)))
		_move_to(_screen(Vector3(1, 0, 0)))
	)

	step("Then the moved material shows at the covered cell", func():
		_expect_material(Vector3i(1, 0, 0), MATERIAL_A)
	)

	step("When the user keeps dragging past the stationary voxel and commits", func():
		_move_to(_screen(Vector3(2, 0, 0)))
		_release_at(_screen(Vector3(2, 0, 0)))
		_press_option("Commit")
	)

	step("Then the stationary voxel returns with its own material", func():
		_expect_material(Vector3i(1, 0, 0), MATERIAL_B)
		_expect_material(Vector3i(2, 0, 0), MATERIAL_A)
	)

	step("Given the bar selected with the rotate tool in the front view", func():
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_paint_bar()
		_select_bar()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
	)

	step("When the user drags the bar straight up and commits", func():
		_press_at(_screen(Vector3(0, 0, 0)))
		_move_to(_screen(Vector3(0, 0, 0)) + Vector2(0, -100))
		_release_at(_screen(Vector3(0, 0, 0)) + Vector2(0, -100))
		_press_option("Commit")
	)

	step("Then each voxel keeps its material through the quarter turn", func():
		_expect_cells([Vector3i(0, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 2, 0)])
		for cell in [Vector3i(0, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 2, 0)]:
			expect(_material_at(cell) == _material_for_color(_color_at(cell)), "cell %s keeps the material of its own voxel" % cell)
	)

	step("Given a solid block with one material and snap off", func():
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		for x in 6:
			for y in 6:
				_frame().set_cell(Vector3i(x, y, 0), VoxelFrame.material(Color.from_rgba8(200, 60, 60), MATERIAL_A.emission, MATERIAL_A.metallic, MATERIAL_A.roughness))
				State.selection.add(Vector3i(x, y, 0))
		State.selection_changed.emit()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
		press_option("Snap to 90 degrees")
	)

	step("When the user drags a small angle short of a quarter turn and commits", func():
		_drag_screen(Vector2(-30, -12))
		_press_option("Commit")
	)

	step("Then every rotated voxel keeps the block material", func():
		expect(_frame().count() > 0, "the unsnapped rotation leaves voxels")
		for cell in _frame().positions():
			expect(_material_at(cell) == MATERIAL_A, "cell %s keeps the block material" % cell)
	)


func _view_setup() -> void:
	viewport = editor_viewport()
	var container := viewport.get_parent()
	container.stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().set_view("front")


func _paint_bar() -> void:
	_frame().set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.from_rgba8(200, 60, 60), MATERIAL_A.emission, MATERIAL_A.metallic, MATERIAL_A.roughness))
	_frame().set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.from_rgba8(60, 200, 60), MATERIAL_B.emission, MATERIAL_B.metallic, MATERIAL_B.roughness))
	_frame().set_cell(Vector3i(2, 0, 0), VoxelFrame.material(Color.from_rgba8(60, 60, 200), MATERIAL_C.emission, MATERIAL_C.metallic, MATERIAL_C.roughness))


func _select_bar() -> void:
	State.selection.clear()
	for i in 3:
		State.selection.add(Vector3i(i, 0, 0))
	State.selection_changed.emit()


func _frame() -> VoxelFrame:
	return State.document.frames[0]


func _material_at(cell: Vector3i) -> Dictionary:
	return {"emission": _frame().get_emission(cell), "metallic": _frame().get_metallic(cell), "roughness": _frame().get_roughness(cell)}


func _color_at(cell: Vector3i) -> Color:
	return _frame().get_color(cell)


# The material of each bar voxel, keyed by its color.
func _material_for_color(color: Color) -> Dictionary:
	if color.is_equal_approx(Color.from_rgba8(200, 60, 60)):
		return MATERIAL_A
	if color.is_equal_approx(Color.from_rgba8(60, 200, 60)):
		return MATERIAL_B
	return MATERIAL_C


func _screen(world: Vector3) -> Vector2:
	return camera_rig().unproject_position(world)


func _drag_screen(rel: Vector2) -> void:
	var from := _screen(_current_center())
	var to := from + rel
	_mouse_button(from, true)
	_mouse_motion(to)
	_mouse_button(to, false)


func _current_center() -> Vector3:
	var b := AABB()
	var first := true
	for c in _frame().positions():
		var cb := AABB(Vector3(c) - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
		b = cb if first else b.merge(cb)
		first = false
	return b.get_center()


func _press_at(pos: Vector2) -> void:
	_mouse_button(pos, true)


func _move_to(pos: Vector2) -> void:
	_mouse_motion(pos)


func _release_at(pos: Vector2) -> void:
	_mouse_button(pos, false)


func _mouse_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(ev)


func _mouse_motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(ev)


func _press_option(tooltip: String) -> void:
	var b := _find_option_button(tooltip)
	if b != null:
		b.pressed.emit()


func _expect_cells(list: Array) -> void:
	expect(_frame().count() == list.size(), "the frame holds %d voxels" % list.size())
	for c in list:
		expect(_frame().has(c), "cell %s is present" % c)


func _expect_material(cell: Vector3i, material: Dictionary) -> void:
	expect(_material_at(cell) == material, "cell %s holds its own material" % cell)
