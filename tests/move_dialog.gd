extends "res://tests/test.gd"

var viewport: SubViewport
var _saved_uniform := true


func _ready() -> void:
	test("a single move click opens a numeric dialog with live preview", _run)


func _run() -> void:
	step("Given a solid 2x2 block selected with the move tool active in the front view", func():
		_view_setup()
		State.undo_redo.clear_history()
		_paint_block(2)
		activate_tool("transform")
		select_toolbar_item("transform", "Move")
		_saved_uniform = _scale_tool()._settings.uniform
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("When the user clicks without a drag", func():
		_click_at_center()
	)
	await get_tree().process_frame
	await get_tree().process_frame

	var dialog := _dialog()
	step("Then the move dialog opens with integer X Y Z and no lock", func():
		expect(is_instance_valid(dialog), "the move dialog exists")
		expect(dialog.visible, "the move dialog is visible")
		var inputs := dialog.get_node("MarginContainer/MoveRow")
		expect(inputs is HBoxContainer, "the dialog inputs sit in one row")
		expect(inputs.get_node("MoveX") is SpinBox, "the dialog has an X offset")
		expect(inputs.get_node("MoveY") is SpinBox, "the dialog has a Y offset")
		expect(inputs.get_node("MoveZ") is SpinBox, "the dialog has a Z offset")
		expect(not dialog.get_node("MarginContainer/ScaleRow").visible, "the scale row stays hidden")
		expect(not dialog.get_node("MarginContainer/RotateRow").visible, "the rotate row stays hidden")
	)

	step("When the user types 2 for X only", func():
		dialog.get_node("MarginContainer/MoveRow/MoveX").value = 2.0
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the viewport previews the shifted block before commit", func():
		expect(_frame().count() == 4, "the preview holds 4 voxels (has %d)" % _frame().count())
		_expect_bounds(Vector3i(2, 0, 0), Vector3i(3, 1, 0))
	)

	step("When the user commits the dialog move", func():
		dialog.confirmed.emit()
		dialog.hide()
		_press_option("Commit")
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the move commits in one undo step", func():
		expect(_frame().count() == 4, "the committed block holds 4 voxels")
		expect(State.undo_redo.has_undo(), "the dialog move is a single undo step")
		State.undo_redo.undo()
		expect(_frame().count() == 4, "undo returns 4 voxels (has %d)" % _frame().count())
		_expect_bounds(Vector3i(0, 0, 0), Vector3i(1, 1, 0))
	)
	State.undo_redo.clear_history()
	_paint_block(2)
	dialog.hide()
	await get_tree().process_frame

	step("Given a pending dialog move of 2 on X", func():
		_click_at_center()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("When the user types 2 for X and accepts to stay pending", func():
		dialog.get_node("MarginContainer/MoveRow/MoveX").value = 2.0
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("And the user accepts the dialog without committing", func():
		dialog.confirmed.emit()
		dialog.hide()
		expect(_frame().count() == 4, "the 2-cell preview stays pending")
		_expect_bounds(Vector3i(2, 0, 0), Vector3i(3, 1, 0))
	)
	await get_tree().process_frame

	step("When the user drags 1 cell further along X", func():
		_drag_world(Vector2(0, 0), Vector2(1, 0))
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the drag compounds onto the dialog move", func():
		_expect_bounds(Vector3i(3, 0, 0), Vector3i(4, 1, 0))
	)

	step("When the user clicks again", func():
		_click_at_center()
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the dialog shows the compounded total of 3", func():
		expect(dialog.visible, "the dialog reopens after the drag")
		expect(dialog.get_node("MarginContainer/MoveRow/MoveX").value == 3.0, "the dialog shows the total X offset")
	)
	step("When the user cancels the total", func():
		dialog.canceled.emit()
		dialog.hide()
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the preview returns to the pre-click total and stays pending", func():
		_expect_bounds(Vector3i(3, 0, 0), Vector3i(4, 1, 0))
		_press_option("Commit")
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the 3-cell total commits in one undo step", func():
		expect(State.undo_redo.has_undo(), "the compounded move is a single undo step")
		State.undo_redo.undo()
		_expect_bounds(Vector3i(0, 0, 0), Vector3i(1, 1, 0))
	)
	State.undo_redo.clear_history()
	_paint_block(2)
	dialog.hide()
	_scale_tool()._settings.uniform = _saved_uniform
	await get_tree().process_frame


func _view_setup() -> void:
	viewport = editor_viewport()
	var container := viewport.get_parent()
	container.stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().set_view("front")


func _paint_block(size: int) -> void:
	State.selection.clear()
	_frame().clear()
	for x in size:
		for y in size:
			var c := Vector3i(x, y, 0)
			_frame().set_cell(c, Color.from_rgba8(60, 200, 60))
			State.selection.add(c)
	State.selection_changed.emit()


func _frame() -> VoxelFrame:
	return State.document.frames[0]


func _expect_bounds(lo: Vector3i, hi: Vector3i) -> void:
	var min_c := Vector3i(999999, 999999, 999999)
	var max_c := Vector3i(-999999, -999999, -999999)
	for c in _frame().positions():
		min_c = Vector3i(mini(min_c.x, c.x), mini(min_c.y, c.y), mini(min_c.z, c.z))
		max_c = Vector3i(maxi(max_c.x, c.x), maxi(max_c.y, c.y), maxi(max_c.z, c.z))
	expect(min_c == lo, "the shape's low corner is %s (was %s)" % [lo, min_c])
	expect(max_c == hi, "the shape's high corner is %s (was %s)" % [hi, max_c])


func _scale_tool() -> Node:
	return plugin("TransformPlugin")._scale


func _move_tool() -> Node:
	return plugin("TransformPlugin")._move


func _dialog() -> ConfirmationDialog:
	return _move_tool()._dialog


func _click_at_center() -> void:
	var pivot := _current_center()
	var pos := camera_rig().unproject_position(pivot)
	_mouse_button(pos, true)
	_mouse_button(pos, false)


func _current_center() -> Vector3:
	var b := AABB()
	var first := true
	for c in _frame().positions():
		var cb := AABB(Vector3(c) - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
		b = cb if first else b.merge(cb)
		first = false
	return b.get_center()


func _drag_world(from_offset: Vector2, to_offset: Vector2) -> void:
	var pivot := _current_center()
	var from := camera_rig().unproject_position(pivot + Vector3(from_offset.x, from_offset.y, 0))
	var to := camera_rig().unproject_position(pivot + Vector3(to_offset.x, to_offset.y, 0))
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
