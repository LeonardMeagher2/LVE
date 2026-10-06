extends "res://tests/test.gd"

var viewport: SubViewport


func _ready() -> void:
	test("a pending scale continues correctly after the view changes mid-drag", _run)


func _run() -> void:
	step("Given a solid 4x4 block scaled 2x uniformly from the front view, not yet committed", func():
		_view_setup("front")
		State.undo_redo.clear_history()
		_paint_block(4)
		activate_tool("transform")
		select_toolbar_item("transform", "Scale")
		_drag_from_pivot(_current_center(), Vector3(4, 4, 0), Vector3(8, 8, 0))
	)

	step("When the user switches to a perpendicular view and grabs again without committing", func():
		camera_rig().set_view("right")
		_drag_from_pivot(_current_center(), Vector3(0, 4, 1), Vector3(0, 8, 2))
		_press_option("Commit")
	)

	step("Then both scale steps compound into one 4x scale on every axis, seen from either view", func():
		expect(_frame().count() == 1024, "the block holds exactly 1024 voxels (has %d)" % _frame().count())
		_expect_size(Vector3i(16, 16, 4))
		expect(State.undo_redo.has_undo(), "the compounded scale is still a single undo step")
	)

	step("When the user undoes", func():
		State.undo_redo.undo()
	)

	step("Then the original 4x4 block returns exactly", func():
		expect(_frame().count() == 16, "the original block returns with 16 voxels")
		_expect_size(Vector3i(4, 4, 1))
	)


func _view_setup(view_name: String) -> void:
	viewport = editor_viewport()
	var container := viewport.get_parent()
	container.stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().set_view(view_name)


func _paint_block(size: int) -> void:
	State.selection.clear()
	_frame().clear()
	for x in size:
		for y in size:
			var c := Vector3i(x, y, 0)
			_frame().set_cell(c, Color.from_rgba8(200, 60, 60))
			State.selection.add(c)
	State.selection_changed.emit()


func _frame() -> VoxelFrame:
	return State.document.frames[0]


func _current_center() -> Vector3:
	var b := AABB()
	var first := true
	for c in _frame().positions():
		var cb := AABB(Vector3(c) - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
		b = cb if first else b.merge(cb)
		first = false
	return b.get_center()


func _expect_size(size: Vector3i) -> void:
	var min_c := Vector3i(999999, 999999, 999999)
	var max_c := Vector3i(-999999, -999999, -999999)
	for c in _frame().positions():
		min_c = Vector3i(mini(min_c.x, c.x), mini(min_c.y, c.y), mini(min_c.z, c.z))
		max_c = Vector3i(maxi(max_c.x, c.x), maxi(max_c.y, c.y), maxi(max_c.z, c.z))
	var got := max_c - min_c + Vector3i(1, 1, 1)
	expect(got == size, "the shape measures %s (was %s)" % [size, got])


func _drag_from_pivot(pivot: Vector3, press_offset: Vector3, drag_offset: Vector3) -> void:
	var from := camera_rig().unproject_position(pivot + press_offset)
	var to := camera_rig().unproject_position(pivot + drag_offset)
	_mouse_button(from, true)
	_mouse_motion(to)
	_mouse_button(to, false)


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
