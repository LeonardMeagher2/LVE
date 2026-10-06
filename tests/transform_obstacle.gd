extends "res://tests/test.gd"

var viewport: SubViewport


func _ready() -> void:
	test("moving a selection over a stationary voxel hides it, restores it if passed, and overwrites it if landed on", _run)


func _run() -> void:
	step("Given a selected voxel, a stationary voxel in its path, and the move tool active", func():
		_view_setup()
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_frame().set_cell(Vector3i(0, 0, 0), Color.from_rgba8(200, 60, 60))
		_frame().set_cell(Vector3i(1, 0, 0), Color.from_rgba8(40, 120, 40))
		State.selection.add(Vector3i(0, 0, 0))
		State.selection_changed.emit()
		activate_tool("transform")
	)

	step("When the user drags the voxel across the stationary voxel and past it", func():
		_press_at(_screen(Vector3(0, 0, 0)))
		_move_to(_screen(Vector3(1, 0, 0)))
	)

	step("Then the stationary voxel is hidden under the moved voxel", func():
		expect(_color_at(Vector3i(1, 0, 0)).is_equal_approx(Color.from_rgba8(200, 60, 60)), "the moved voxel now shows at the covered cell")
	)

	step("When the user keeps dragging past the stationary voxel and releases", func():
		_move_to(_screen(Vector3(2, 0, 0)))
		_release_at(_screen(Vector3(2, 0, 0)))
		_press_option("Commit")
	)

	step("Then the stationary voxel is restored and the moved voxel sits at the far cell", func():
		expect(_color_at(Vector3i(1, 0, 0)).is_equal_approx(Color.from_rgba8(40, 120, 40)), "the stationary voxel survives the pass-over")
		expect(_color_at(Vector3i(2, 0, 0)).is_equal_approx(Color.from_rgba8(200, 60, 60)), "the moved voxel reached the far cell")
		expect(not _frame().has(Vector3i(0, 0, 0)), "the origin cell is empty")
		_expect_selection([Vector3i(2, 0, 0)])
	)

	step("Given the same setup again with the move tool active", func():
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_frame().set_cell(Vector3i(0, 0, 0), Color.from_rgba8(200, 60, 60))
		_frame().set_cell(Vector3i(1, 0, 0), Color.from_rgba8(40, 120, 40))
		State.selection.add(Vector3i(0, 0, 0))
		State.selection_changed.emit()
	)

	step("When the user drags the voxel onto the stationary voxel and commits", func():
		_press_at(_screen(Vector3(0, 0, 0)))
		_move_to(_screen(Vector3(1, 0, 0)))
		_release_at(_screen(Vector3(1, 0, 0)))
		_press_option("Commit")
	)

	step("Then the moved voxel wins at the shared cell", func():
		expect(_color_at(Vector3i(1, 0, 0)).is_equal_approx(Color.from_rgba8(200, 60, 60)), "landing on the stationary voxel overwrites it")
		expect(_frame().count() == 1, "only one voxel remains at the destination")
	)


func _view_setup() -> void:
	viewport = editor_viewport()
	var container := viewport.get_parent()
	container.stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().set_view("front")


func _frame() -> VoxelFrame:
	return State.document.frames[0]


func _color_at(c: Vector3i) -> Color:
	return State.document.get_color_at(0, c)


func _screen(world: Vector3) -> Vector2:
	return camera_rig().unproject_position(world)


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


func _expect_selection(list: Array) -> void:
	expect(State.selection.cells.size() == list.size(), "the selection holds %d cells" % list.size())
	for c in list:
		expect(State.selection.cells.has(c), "the selection contains %s" % c)
