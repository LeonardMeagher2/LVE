extends "res://tests/test.gd"

var viewport: SubViewport


func _ready() -> void:
	test("the move tool drags a whole shape, keeps the selection in sync, and commits or cancels", _run)


func _run() -> void:
	step("Given a painted bar with the move tool active in the front view", func():
		_view_setup()
		_paint_bar()
		State.selection.clear()
		activate_tool("transform")
	)

	step("When the user drags the bar one voxel right and commits", func():
		_drag_voxels(Vector3i(1, 0, 0))
		_press_option("Commit")
	)

	step("Then the bar sits one voxel to the right and no selection appears", func():
		_expect_cells([Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(3, 0, 0)])
		expect(State.selection.is_empty(), "a move with no selection creates no selection")
	)

	step("Given the bar selected with the move tool active", func():
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_paint_bar()
		_select_bar()
	)

	step("When the user drags the bar one voxel right and releases", func():
		_drag_voxels(Vector3i(1, 0, 0))
	)

	step("Then the move is pending and the selection follows the cells", func():
		_expect_cells([Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(3, 0, 0)])
		_expect_selection([Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(3, 0, 0)])
		expect(not State.undo_redo.has_undo(), "the pending move is not yet committed")
		expect(not _option("Commit").disabled, "commit is enabled while the move is pending")
	)

	step("When the user commits the pending move", func():
		_press_option("Commit")
	)

	step("Then the move is one undo step", func():
		_expect_cells([Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(3, 0, 0)])
		expect(State.undo_redo.has_undo(), "the committed move is undoable")
	)

	step("When the user undoes the move", func():
		State.undo_redo.undo()
	)

	step("Then the cells and selection return to the origin", func():
		_expect_cells([Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)])
		_expect_selection([Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)])
	)

	step("When the user redoes the move", func():
		State.undo_redo.redo()
	)

	step("Then the cells and selection sit at the destination", func():
		_expect_cells([Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(3, 0, 0)])
		_expect_selection([Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(3, 0, 0)])
	)

	step("Given the bar selected with the move tool active", func():
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_paint_bar()
		_select_bar()
	)

	step("When the user drags the bar right and cancels", func():
		_drag_voxels(Vector3i(1, 0, 0))
		_press_option("Cancel")
	)

	step("Then the cells and selection return to the origin", func():
		_expect_cells([Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)])
		_expect_selection([Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)])
		expect(not State.undo_redo.has_undo(), "cancelling leaves no undo step")
	)

	step("Given the bar selected with the move tool active", func():
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_paint_bar()
		_select_bar()
	)

	step("When the user drags right, pauses, drags right again, and commits", func():
		_drag_voxels(Vector3i(1, 0, 0))
		_drag_voxels(Vector3i(1, 0, 0))
		_press_option("Commit")
	)

	step("Then the bar sits two voxels to the right as one undo step", func():
		_expect_cells([Vector3i(2, 0, 0), Vector3i(3, 0, 0), Vector3i(4, 0, 0)])
		State.undo_redo.undo()
		_expect_cells([Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)])
	)

	step("Given the bar selected with the move tool active", func():
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_paint_bar()
		_select_bar()
	)

	step("When the user drags the bar right and presses Enter", func():
		_drag_voxels(Vector3i(1, 0, 0))
		_key(KEY_ENTER)
	)

	step("Then the Enter key commits the move", func():
		_expect_cells([Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(3, 0, 0)])
		expect(State.undo_redo.has_undo(), "the Enter key commits the pending move")
	)

	step("Given the bar selected with the move tool active", func():
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_paint_bar()
		_select_bar()
	)

	step("When the user drags the bar right and presses Escape", func():
		_drag_voxels(Vector3i(1, 0, 0))
		_key(KEY_ESCAPE)
	)

	step("Then the Escape key cancels the move", func():
		_expect_cells([Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)])
		expect(not State.undo_redo.has_undo(), "the Escape key cancels without an undo step")
	)

	step("Given the bar selected with the move tool active", func():
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_paint_bar()
		_select_bar()
	)

	step("When the user drags the bar right and switches to Rotate", func():
		_drag_voxels(Vector3i(1, 0, 0))
		select_toolbar_item("transform", "Rotate")
	)

	step("Then the pending move is committed and the rotate tool is active", func():
		_expect_cells([Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(3, 0, 0)])
		expect(State.undo_redo.has_undo(), "switching tools commits the pending move")
		var p := plugin("TransformPlugin")
		expect(p._current_tool == p._rotate, "the rotate tool is now active")
	)

	step("Given the bar selected with the move tool active", func():
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_paint_bar()
		_select_bar()
		activate_tool("transform")
		select_toolbar_item("transform", "Move")
	)

	step("When the user drags the bar right and switches to the brush", func():
		_drag_voxels(Vector3i(1, 0, 0))
		activate_tool("Toolbar")
	)

	step("Then the pending move is committed", func():
		_expect_cells([Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(3, 0, 0)])
		expect(State.undo_redo.has_undo(), "deactivating the tool commits the pending move")
	)


func _view_setup() -> void:
	viewport = editor_viewport()
	var container := viewport.get_parent()
	container.stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().set_view("front")


func _paint_bar() -> void:
	var frame := State.document.frames[0]
	for i in 3:
		frame.set_cell(Vector3i(i, 0, 0), Color.from_rgba8(200, 60, 60))


func _select_bar() -> void:
	State.selection.clear()
	for i in 3:
		State.selection.add(Vector3i(i, 0, 0))
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


func _drag_voxels(off: Vector3i) -> void:
	var c := _current_center()
	_mouse_button(camera_rig().unproject_position(c), true)
	_mouse_motion(camera_rig().unproject_position(c + Vector3(off)))
	_mouse_button(camera_rig().unproject_position(c + Vector3(off)), false)


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


func _key(code: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	viewport.push_input(ev)


func _option(tooltip: String) -> BaseButton:
	return _find_option_button(tooltip)


func _press_option(tooltip: String) -> void:
	var b := _find_option_button(tooltip)
	if b != null:
		b.pressed.emit()


func _expect_cells(list: Array) -> void:
	expect(_frame().count() == list.size(), "the frame holds %d voxels" % list.size())
	for c in list:
		expect(_frame().has(c), "cell %s is present" % c)


func _expect_selection(list: Array) -> void:
	expect(State.selection.cells.size() == list.size(), "the selection holds %d cells" % list.size())
	for c in list:
		expect(State.selection.cells.has(c), "the selection contains %s" % c)
