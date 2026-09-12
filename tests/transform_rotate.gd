extends "res://tests/test.gd"

var viewport: SubViewport


func _ready() -> void:
	test("the rotate tool turns a selected shape a quarter turn with snap, and the selection follows", _run)


func _run() -> void:
	step("Given a selected bar with the rotate tool and snap in the front view", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		camera_rig().set_view("front")
		State.undo_redo.clear_history()
		State.selection.clear()
		_cells().clear()
		_paint_bar()
		_select_bar()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
		press_option("Snap to 90 degrees")
	)

	step("When the user drags the bar straight up and commits", func():
		_drag_screen(Vector2(0, -100))
		_press_option("Commit")
	)

	step("Then the bar sits vertical around the pivot", func():
		_expect_cells([Vector3i(0, -1, 0), Vector3i(0, 0, 0), Vector3i(0, 1, 0)])
		expect(State.undo_redo.has_undo(), "the committed rotation is undoable")
	)

	step("When the user undoes the rotation", func():
		State.undo_redo.undo()
	)

	step("Then the cells and selection return to the horizontal bar", func():
		_expect_cells([Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)])
		_expect_selection([Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)])
	)

	step("When the user redoes the rotation", func():
		State.undo_redo.redo()
	)

	step("Then the cells and selection sit vertical", func():
		_expect_cells([Vector3i(0, -1, 0), Vector3i(0, 0, 0), Vector3i(0, 1, 0)])
		_expect_selection([Vector3i(0, -1, 0), Vector3i(0, 0, 0), Vector3i(0, 1, 0)])
	)

	step("Given the selected bar with the rotate tool again", func():
		State.undo_redo.clear_history()
		State.selection.clear()
		_cells().clear()
		_paint_bar()
		_select_bar()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
		press_option("Snap to 90 degrees")
	)

	step("When the user drags the bar straight up and cancels", func():
		_drag_screen(Vector2(0, -100))
		_press_option("Cancel")
	)

	step("Then the bar returns to the horizontal position", func():
		_expect_cells([Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)])
		_expect_selection([Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)])
		expect(not State.undo_redo.has_undo(), "cancelling the rotation leaves no undo step")
	)


func _paint_bar() -> void:
	var frame := State.document.frames[0]
	for i in 3:
		frame.cells[Vector3i(i, 0, 0)] = Color.from_rgba8(200, 60, 60)


func _select_bar() -> void:
	State.selection.clear()
	for i in 3:
		State.selection.add(Vector3i(i, 0, 0))
	State.selection_changed.emit()


func _cells() -> Dictionary:
	return State.document.frames[0].cells


func _current_center() -> Vector3:
	var b := AABB()
	var first := true
	for c in _cells():
		var cb := AABB(Vector3(c) - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
		b = cb if first else b.merge(cb)
		first = false
	return b.get_center()


func _drag_screen(rel: Vector2) -> void:
	var from := camera_rig().unproject_position(_current_center())
	var to := from + rel
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
	expect(_cells().size() == list.size(), "the frame holds %d voxels" % list.size())
	for c in list:
		expect(_cells().has(c), "cell %s is present" % c)


func _expect_selection(list: Array) -> void:
	expect(State.selection.cells.size() == list.size(), "the selection holds %d cells" % list.size())
	for c in list:
		expect(State.selection.cells.has(c), "the selection contains %s" % c)