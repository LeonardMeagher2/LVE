extends "res://tests/test.gd"

var viewport: SubViewport
var _saved_uniform := true


func _ready() -> void:
	test("a single rotate click opens a numeric dialog with live preview", _run)


func _run() -> void:
	step("Given an L shape selected with the rotate tool active in the front view", func():
		_view_setup()
		State.undo_redo.clear_history()
		_paint_l()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
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
	step("Then the rotate dialog opens with an angle per axis", func():
		expect(is_instance_valid(dialog), "the rotate dialog exists")
		expect(dialog.visible, "the rotate dialog is visible")
		var inputs := dialog.get_node("MarginContainer/RotateRow")
		expect(inputs is HBoxContainer, "the dialog inputs sit in one row")
		expect(inputs.get_node("AngleX") is SpinBox, "the dialog has an X angle")
		expect(inputs.get_node("AngleY") is SpinBox, "the dialog has a Y angle")
		expect(inputs.get_node("AngleZ") is SpinBox, "the dialog has a Z angle")
		expect(inputs.get_node("AngleX").value == 0.0, "the X angle starts at zero")
		expect(inputs.get_node("AngleY").value == 0.0, "the Y angle starts at zero")
		expect(inputs.get_node("AngleZ").value == 0.0, "the Z angle starts at zero")
		expect(not dialog.get_node("MarginContainer/ScaleRow").visible, "the scale row stays hidden")
		expect(not dialog.get_node("MarginContainer/MoveRow").visible, "the move row stays hidden")
	)

	step("When the user types 90 degrees about Z", func():
		dialog.get_node("MarginContainer/RotateRow/AngleZ").value = 90.0
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the viewport previews the upright L before commit", func():
		expect(_frame().count() == 4, "the preview holds 4 voxels (has %d)" % _frame().count())
		_expect_bounds(Vector3i(0, 0, 0), Vector3i(1, 2, 0))
	)

	step("When the user commits the dialog rotation", func():
		dialog.confirmed.emit()
		dialog.hide()
		_press_option("Commit")
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the rotation commits in one undo step", func():
		expect(_frame().count() == 4, "the committed shape holds 4 voxels")
		expect(State.undo_redo.has_undo(), "the dialog rotation is a single undo step")
		State.undo_redo.undo()
		expect(_frame().positions().has(Vector3i(2, 0, 0)), "undo returns the flat L")
		expect(not _frame().positions().has(Vector3i(1, 2, 0)), "undo removes the upright L")
	)
	State.undo_redo.clear_history()
	_paint_l()
	dialog.hide()
	await get_tree().process_frame

	step("Given a fresh click with a 45 degree edit that the user cancels", func():
		_click_at_center()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("When the user types 45 degrees about Z then cancels", func():
		dialog.get_node("MarginContainer/RotateRow/AngleZ").value = 45.0
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("And the user cancels without committing", func():
		dialog.canceled.emit()
		dialog.hide()
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the shape returns to the flat L with no undo step", func():
		expect(_frame().count() == 4, "the shape holds 4 voxels (has %d)" % _frame().count())
		expect(_frame().positions().has(Vector3i(2, 0, 0)), "the flat L returns")
		expect(not State.undo_redo.has_undo(), "the cancelled rotation leaves no undo step")
	)

	step("Given a pending dialog rotation of 90 degrees about Z", func():
		_click_at_center()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("When the user types 90 degrees about Z and accepts to stay pending", func():
		dialog.get_node("MarginContainer/RotateRow/AngleZ").value = 90.0
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("And the user accepts the dialog without committing", func():
		dialog.confirmed.emit()
		dialog.hide()
		expect(_frame().count() == 4, "the 90 degree preview stays pending")
	)
	await get_tree().process_frame

	step("When the user clicks again while the rotation is pending", func():
		_click_at_center()
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the dialog reopens showing the current angles", func():
		expect(dialog.visible, "the dialog reopens on a pending click")
		expect(dialog.get_node("MarginContainer/RotateRow/AngleX").value == 0.0, "the dialog shows the current X angle")
		expect(dialog.get_node("MarginContainer/RotateRow/AngleY").value == 0.0, "the dialog shows the current Y angle")
		expect(dialog.get_node("MarginContainer/RotateRow/AngleZ").value == 90.0, "the dialog shows the current Z angle")
	)
	step("When the user adds 90 degrees about X and accepts", func():
		dialog.get_node("MarginContainer/RotateRow/AngleX").value = 90.0
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the combined rotation previews without losing voxels", func():
		expect(_frame().count() == 4, "the combined preview holds 4 voxels (has %d)" % _frame().count())
	)
	step("When the user accepts the combined rotation", func():
		dialog.confirmed.emit()
		dialog.hide()
		_press_option("Commit")
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the combined rotation commits in one undo step", func():
		expect(_frame().count() == 4, "the committed shape holds 4 voxels")
		expect(State.undo_redo.has_undo(), "the combined rotation is a single undo step")
		State.undo_redo.undo()
		expect(_frame().positions().has(Vector3i(2, 0, 0)), "undo returns the flat L")
	)
	State.undo_redo.clear_history()
	_paint_l()
	dialog.hide()
	_scale_tool()._settings.uniform = _saved_uniform
	await get_tree().process_frame


func _view_setup() -> void:
	viewport = editor_viewport()
	var container := viewport.get_parent()
	container.stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().set_view("front")


func _paint_l() -> void:
	State.selection.clear()
	_frame().clear()
	for c in [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(0, 1, 0)]:
		_frame().set_cell(c, VoxelFrame.material(Color.from_rgba8(60, 60, 200)))
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


func _rotate_tool() -> Node:
	return plugin("TransformPlugin")._rotate


func _dialog() -> ConfirmationDialog:
	return _rotate_tool()._dialog


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


func _mouse_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(ev)


func _press_option(tooltip: String) -> void:
	var b := _find_option_button(tooltip)
	if b != null:
		b.pressed.emit()
