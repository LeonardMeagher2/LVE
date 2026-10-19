extends "res://tests/test.gd"

var viewport: SubViewport


func _ready() -> void:
	test("the transform toolbar swaps tools and the option bar reflects tool state", _run)


func _run() -> void:
	step("Given a painted bar with the transform tool active", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		camera_rig().set_view("front")
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_paint_bar()
		activate_tool("transform")
	)

	step("Then the move tool is active by default", func():
		var p := plugin("TransformPlugin")
		expect(p._current_tool == p._move, "the move tool is active by default")
	)

	step("When the user switches to Rotate in the toolbar", func():
		select_toolbar_item("transform", "Rotate")
	)

	step("Then the rotate tool becomes active", func():
		var p := plugin("TransformPlugin")
		expect(p._current_tool == p._rotate, "the rotate tool is now active")
	)

	step("When the user switches back to Move", func():
		select_toolbar_item("transform", "Move")
	)

	step("Then the move tool becomes active again", func():
		var p := plugin("TransformPlugin")
		expect(p._current_tool == p._move, "the move tool is active again")
	)

	step("When the user inspects the option bar for the move tool", func():
		expect(not _option("Snap to 90 degrees").visible, "snap is hidden for the move tool")
		expect(_option("Commit").disabled, "commit is disabled while idle")
		expect(_option("Cancel").disabled, "cancel is disabled while idle")
	)

	step("When the user drags the bar one voxel right", func():
		_drag_voxels(Vector3i(1, 0, 0))
	)

	step("Then the commit and cancel buttons enable while the move is pending", func():
		expect(not _option("Commit").disabled, "commit is enabled while the move is pending")
		expect(not _option("Cancel").disabled, "cancel is enabled while the move is pending")
	)

	step("When the user commits the move", func():
		_press_option("Commit")
	)

	step("Then the buttons disable again", func():
		expect(_option("Commit").disabled, "commit is disabled after committing")
		expect(_option("Cancel").disabled, "cancel is disabled after committing")
	)

	step("When the user switches to Rotate", func():
		select_toolbar_item("transform", "Rotate")
	)

	step("Then snap shows for the rotate tool", func():
		expect(_option("Snap to 90 degrees").visible, "snap is shown for the rotate tool")
	)


func _paint_bar() -> void:
	var frame := State.document.frames[0]
	for i in 3:
		frame.set_cell(Vector3i(i, 0, 0), VoxelFrame.material(Color.from_rgba8(200, 60, 60)))


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


func _option(tooltip: String) -> BaseButton:
	return _find_option_button(tooltip)


func _press_option(tooltip: String) -> void:
	var b := _find_option_button(tooltip)
	if b != null:
		b.pressed.emit()
