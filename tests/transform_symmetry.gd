extends "res://tests/test.gd"

var viewport: SubViewport


func _ready() -> void:
	test("the transform tools keep both halves of a mirrored model a mirror pair", _run)


func _run() -> void:
	step("Given a symmetric bar, the X mirror plane, and the move tool in the front view", func():
		_view_setup()
		State.document = VoxelDocument.new()
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3(-0.5, -0.5, -0.5)
		_paint_symmetric_bar()
		_select_bar()
		activate_tool("transform")
		select_toolbar_item("transform", "Move")
		State.undo_redo.clear_history()
	)

	step("When the user drags the bar up one voxel and commits", func():
		_drag_voxels(Vector3i(0, 1, 0))
		_press_option("Commit")
	)

	step("Then both halves move up together and stay mirror images", func():
		_expect_cells(_bar_cells(Vector3i(0, 1, 0)))
		_expect_symmetric()
		expect(State.undo_redo.has_undo(), "the mirrored move is one undo step")
	)

	step("When the user undoes the move", func():
		State.undo_redo.undo()
	)

	step("Then the symmetric bar returns to its original row", func():
		_expect_cells(_bar_cells(Vector3i.ZERO))
	)

	step("Given the symmetric bar selected with the move tool again", func():
		_paint_symmetric_bar()
		_select_bar()
		State.undo_redo.clear_history()
	)

	step("When the user drags the bar along the mirror normal", func():
		_drag_voxels(Vector3i(1, 0, 0))
		_press_option("Commit")
	)

	step("Then the halves move apart by the mirrored offset and stay mirror images", func():
		_expect_cells([Vector3i(2, 0, 0), Vector3i(3, 0, 0), Vector3i(4, 0, 0),
			Vector3i(-3, 0, 0), Vector3i(-4, 0, 0), Vector3i(-5, 0, 0)])
		_expect_symmetric()
	)

	step("Given the symmetric bar selected with the rotate tool", func():
		_paint_symmetric_bar()
		_select_bar()
		select_toolbar_item("transform", "Rotate")
		State.undo_redo.clear_history()
	)

	step("When the user drags up to turn a quarter turn and commits", func():
		_drag_screen(Vector2(0, -100))
		_press_option("Commit")
	)

	step("Then the halves turn opposite ways and stay a mirror pair", func():
		expect(_frame().count() == _bar_cells(Vector3i.ZERO).size(), "the rotation keeps six voxels with no extra reflected copies (has %d)" % _frame().count())
		_expect_symmetric()
		expect(not _frame().has(Vector3i(1, 0, 0)), "the bar left its original row")
	)

	step("When the user undoes the rotation", func():
		State.undo_redo.undo()
	)

	step("Then the symmetric bar returns to its original row", func():
		_expect_cells(_bar_cells(Vector3i.ZERO))
	)

	step("Given the symmetric bar selected with the scale tool", func():
		_paint_symmetric_bar()
		_select_bar()
		select_toolbar_item("transform", "Scale")
		State.undo_redo.clear_history()
	)

	step("When the user drags outward to double the size and commits", func():
		_drag_from_pivot(Vector2(2, 2), Vector2(4, 4))
		_press_option("Commit")
	)

	step("Then both halves scale together and stay a mirror pair", func():
		expect(_frame().count() > _bar_cells(Vector3i.ZERO).size(), "the scaled bar holds more voxels (has %d)" % _frame().count())
		_expect_symmetric()
	)

	step("Given a voxel and its mirrors across two planes", func():
		State.document = VoxelDocument.new()
		State.symmetry_axes = 3
		State.symmetry_origin = Vector3(-0.5, -0.5, -0.5)
		_frame().clear()
		State.selection.clear()
		for c in [Vector3i(1, 1, 0), Vector3i(-2, 1, 0), Vector3i(1, -2, 0), Vector3i(-2, -2, 0)]:
			_frame().set_cell(c, Color.from_rgba8(200, 60, 60))
			State.selection.add(c)
		State.selection_changed.emit()
		activate_tool("transform")
		select_toolbar_item("transform", "Move")
		State.undo_redo.clear_history()
	)

	step("When the user drags the mirrored cluster up one voxel and commits", func():
		_drag_voxels(Vector3i(0, 1, 0))
		_press_option("Commit")
	)

	step("Then all four mirrored voxels stay mirror images", func():
		_expect_cells([Vector3i(1, 2, 0), Vector3i(-2, 2, 0), Vector3i(1, -3, 0), Vector3i(-2, -3, 0)])
		_expect_symmetric()
	)

	step("Given a symmetric bar with the mirror plane off", func():
		_paint_symmetric_bar()
		_select_bar()
		State.symmetry_axes = 0
		select_toolbar_item("transform", "Move")
		State.undo_redo.clear_history()
	)

	step("When the user drags the bar along X", func():
		_drag_voxels(Vector3i(1, 0, 0))
		_press_option("Commit")
	)

	step("Then the bar translates without mirroring", func():
		_expect_cells([Vector3i(2, 0, 0), Vector3i(3, 0, 0), Vector3i(4, 0, 0),
			Vector3i(-1, 0, 0), Vector3i(-2, 0, 0), Vector3i(-3, 0, 0)])
		State.symmetry_axes = 1
	)


func _view_setup() -> void:
	viewport = editor_viewport()
	var container := viewport.get_parent()
	container.stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().set_view("front")


func _bar_cells(offset: Vector3i) -> Array:
	var cells := []
	for x in [1, 2, 3, -2, -3, -4]:
		cells.append(Vector3i(x, 0, 0) + offset)
	return cells


func _paint_symmetric_bar() -> void:
	_frame().clear()
	State.selection.clear()
	for c in _bar_cells(Vector3i.ZERO):
		_frame().set_cell(c, Color.from_rgba8(200, 60, 60))


func _select_bar() -> void:
	State.selection.clear()
	for c in _bar_cells(Vector3i.ZERO):
		State.selection.add(c)
	State.selection_changed.emit()


func _frame() -> VoxelFrame:
	return State.document.frames[0]


func _mirror(c: Vector3i) -> Vector3i:
	var origin_twice := Vector3i(State.symmetry_origin * 2.0)
	var mirrored := c
	for axis in 3:
		if State.symmetry_axes & (1 << axis):
			mirrored[axis] = origin_twice[axis] - c[axis]
	return mirrored


func _expect_symmetric() -> void:
	for c in _frame().positions():
		expect(_frame().has(_mirror(c)), "the mirror of %s is present" % c)


func _current_center() -> Vector3:
	var b := AABB()
	var first := true
	for c in _frame().positions():
		var cb := AABB(Vector3(c) - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
		b = cb if first else b.merge(cb)
		first = false
	return b.get_center()


func _drag_voxels(off: Vector3i) -> void:
	var c := _current_center()
	_mouse_button(camera_rig().unproject_position(c), true)
	_mouse_motion(camera_rig().unproject_position(c + Vector3(off)))
	_mouse_button(camera_rig().unproject_position(c + Vector3(off)), false)


func _drag_screen(rel: Vector2) -> void:
	var from := camera_rig().unproject_position(_current_center())
	var to := from + rel
	_mouse_button(from, true)
	_mouse_motion(to)
	_mouse_button(to, false)


func _drag_from_pivot(press_offset: Vector2, drag_offset: Vector2) -> void:
	var pivot := _current_center()
	var from := camera_rig().unproject_position(pivot + Vector3(press_offset.x, press_offset.y, 0))
	var to := camera_rig().unproject_position(pivot + Vector3(drag_offset.x, drag_offset.y, 0))
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


func _expect_cells(list: Array) -> void:
	expect(_frame().count() == list.size(), "the frame holds %d voxels" % list.size())
	for c in list:
		expect(_frame().has(c), "cell %s is present" % c)
