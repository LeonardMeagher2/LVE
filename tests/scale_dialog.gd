extends "res://tests/test.gd"

var viewport: SubViewport
var _saved_uniform := true


func _ready() -> void:
	test("a single scale click opens a numeric dialog with live preview", _run)


func _run() -> void:
	step("Given a solid 4x4 block selected with the scale tool active in the front view", func():
		_view_setup()
		State.undo_redo.clear_history()
		_paint_block(4)
		activate_tool("transform")
		select_toolbar_item("transform", "Scale")
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
	step("Then the scale dialog opens with X Y Z and a uniform lock in one row", func():
		expect(is_instance_valid(dialog), "the scale dialog exists")
		expect(dialog.visible, "the scale dialog is visible")
		var inputs := dialog.get_node("MarginContainer/Inputs")
		expect(inputs is HBoxContainer, "the dialog inputs sit in one row")
		expect(inputs.get_node("ScaleX") is SpinBox, "the dialog has an X factor")
		expect(inputs.get_node("ScaleY") is SpinBox, "the dialog has a Y factor")
		expect(inputs.get_node("ScaleZ") is SpinBox, "the dialog has a Z factor")
		expect(inputs.get_node("Uniform") is BaseButton, "the dialog has a uniform lock")
		expect(inputs.get_child(3).name == "Uniform", "the lock sits at the end of the row")
	)

	step("Given uniform scale off", func():
		dialog.get_node("MarginContainer/Inputs/Uniform").button_pressed = false
	)
	await get_tree().process_frame

	step("When the user types 2 for X only", func():
		dialog.get_node("MarginContainer/Inputs/ScaleX").value = 2.0
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the viewport previews an 8x4 block before commit", func():
		expect(_frame().count() == 32, "the preview holds 32 voxels (has %d)" % _frame().count())
		_expect_bounds(Vector3i(-2, 0, 0), Vector3i(5, 3, 0))
	)

	step("When the user commits the dialog scale", func():
		dialog.confirmed.emit()
		_press_option("Commit")
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the 8x4 block commits in one undo step", func():
		expect(_frame().count() == 32, "the committed block holds 32 voxels")
		expect(State.undo_redo.has_undo(), "the dialog scale is a single undo step")
		State.undo_redo.undo()
		expect(_frame().count() == 16, "undo returns the 4x4 block")
	)
	State.undo_redo.clear_history()
	_paint_block(4)
	dialog.hide()
	await get_tree().process_frame

	step("Given a pending dialog scale of 2 on X", func():
		_click_at_center()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("When the user types 2 for X and accepts the dialog while pending", func():
		dialog.get_node("MarginContainer/Inputs/ScaleX").value = 2.0
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("And the user accepts the dialog without committing", func():
		dialog.confirmed.emit()
		dialog.hide()
		expect(_frame().count() == 32, "the 2x preview stays pending")
	)
	await get_tree().process_frame

	step("When the user clicks again while the scale is pending", func():
		_click_at_center()
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the dialog reopens showing the current 2x value", func():
		expect(dialog.visible, "the dialog reopens on a pending click")
		expect(dialog.get_node("MarginContainer/Inputs/ScaleX").value == 2.0, "the dialog shows the current X factor")
		expect(dialog.get_node("MarginContainer/Inputs/ScaleY").value == 1.0, "the dialog shows the current Y factor")
		expect(_frame().count() == 32, "the pending preview is kept")
	)

	step("When the user changes X to 3 and commits", func():
		dialog.get_node("MarginContainer/Inputs/ScaleX").value = 3.0
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("And the user commits the adjusted scale", func():
		dialog.confirmed.emit()
		dialog.hide()
		_press_option("Commit")
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the 3x scale replaces the 2x preview instead of compounding", func():
		expect(_frame().count() == 48, "the adjusted block holds 48 voxels (has %d)" % _frame().count())
		_expect_bounds(Vector3i(-3, 0, 0), Vector3i(8, 3, 0))
	)
	State.undo_redo.clear_history()
	_paint_block(4)
	dialog.hide()
	await get_tree().process_frame

	step("Given a fresh click with a 2x edit that the user cancels", func():
		_click_at_center()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("When the user types 2 for X then cancels the dialog", func():
		dialog.get_node("MarginContainer/Inputs/ScaleX").value = 2.0
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("And the user cancels without committing", func():
		dialog.canceled.emit()
		dialog.hide()
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the fresh scale returns to the original block with no undo step", func():
		expect(_frame().count() == 16, "the block returns to 16 voxels (has %d)" % _frame().count())
		_expect_bounds(Vector3i(0, 0, 0), Vector3i(3, 3, 0))
		expect(not State.undo_redo.has_undo(), "the cancelled scale leaves no undo step")
	)

	step("Given a pending dialog scale of 2 on X again", func():
		_click_at_center()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("When the user types 2 for X and accepts to stay pending", func():
		dialog.get_node("MarginContainer/Inputs/ScaleX").value = 2.0
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("And the user accepts the dialog without committing", func():
		dialog.confirmed.emit()
		dialog.hide()
		expect(_frame().count() == 32, "the 2x preview stays pending")
	)
	await get_tree().process_frame

	step("When the user reopens the dialog, types 5, then cancels", func():
		_click_at_center()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("And the user cancels the 5x edit", func():
		dialog.get_node("MarginContainer/Inputs/ScaleX").value = 5.0
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the preview returns to the pre-click 2x values with the scale still pending", func():
		dialog.canceled.emit()
		dialog.hide()
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("And the 2x scale is still pending for commit", func():
		expect(_frame().count() == 32, "the preview returns to 32 voxels (has %d)" % _frame().count())
		_expect_bounds(Vector3i(-2, 0, 0), Vector3i(5, 3, 0))
		_press_option("Commit")
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the 2x block commits in one undo step", func():
		expect(_frame().count() == 32, "the committed block holds 32 voxels")
		expect(State.undo_redo.has_undo(), "the restored scale is a single undo step")
	)
	State.undo_redo.clear_history()
	_paint_block(4)
	dialog.hide()
	await get_tree().process_frame

	step("Given a dialog scale of 2 on X left pending", func():
		_click_at_center()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("When the user types 2 for X and accepts to stay pending", func():
		dialog.get_node("MarginContainer/Inputs/ScaleX").value = 2.0
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("And the user accepts the dialog without committing", func():
		dialog.confirmed.emit()
		dialog.hide()
		expect(_frame().count() == 32, "the 2x preview stays pending")
	)
	await get_tree().process_frame

	step("When the user drags 1.5x further along X", func():
		_drag_from_pivot(Vector2(2, 2), Vector2(6, 2))
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the drag compounds onto the dialog scale", func():
		expect(_frame().count() == 48, "the compounded preview holds 48 voxels (has %d)" % _frame().count())
		_expect_bounds(Vector3i(-4, 0, 0), Vector3i(7, 3, 0))
	)

	step("When the user clicks again", func():
		_click_at_center()
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the dialog shows the compounded total of 3", func():
		expect(dialog.visible, "the dialog reopens after the drag")
		expect(dialog.get_node("MarginContainer/Inputs/ScaleX").value == 3.0, "the dialog shows the total X factor")
		expect(dialog.get_node("MarginContainer/Inputs/ScaleY").value == 1.0, "the dialog shows the total Y factor")
	)
	step("When the user commits the total", func():
		dialog.confirmed.emit()
		dialog.hide()
		_press_option("Commit")
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the 3x total commits in one undo step", func():
		expect(_frame().count() == 48, "the committed block holds 48 voxels")
		expect(State.undo_redo.has_undo(), "the compounded scale is a single undo step")
		State.undo_redo.undo()
		expect(_frame().count() == 16, "undo returns the 4x4 block")
	)
	State.undo_redo.clear_history()
	_paint_block(4)
	dialog.hide()
	await get_tree().process_frame

	step("Given uniform scale back on and a fresh 2x drag left pending", func():
		dialog.get_node("MarginContainer/Inputs/Uniform").button_pressed = true
		_paint_block(4)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("When the user drags to double the block uniformly", func():
		_drag_from_pivot(Vector2(4, 4), Vector2(8, 8))
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("And the user clicks with a 1px wobble", func():
		var pivot := _current_center()
		var pos := camera_rig().unproject_position(pivot)
		_mouse_button(pos, true)
		_mouse_motion(pos + Vector2(1, 0))
		_mouse_button(pos + Vector2(1, 0), false)
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the dialog opens and the wobble never becomes a degenerate drag", func():
		expect(dialog.visible, "the dialog opens despite the 1px wobble")
		expect(dialog.get_node("MarginContainer/Inputs/ScaleX").value == 2.0, "the dialog shows the drag X factor")
		expect(_frame().count() == 128, "the preview keeps 128 voxels (has %d)" % _frame().count())
	)
	State.undo_redo.clear_history()
	_paint_block(4)
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
			_frame().set_cell(c, Color.from_rgba8(200, 60, 60))
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


func _dialog() -> ConfirmationDialog:
	return _scale_tool()._dialog


func _click_at_center() -> void:
	var pivot := _current_center()
	var pos := camera_rig().unproject_position(pivot)
	_mouse_button(pos, true)
	_mouse_button(pos, false)


func _drag_from_pivot(press_offset: Vector2, drag_offset: Vector2) -> void:
	var pivot := _current_center()
	var from := camera_rig().unproject_position(pivot + Vector3(press_offset.x, press_offset.y, 0))
	var to := camera_rig().unproject_position(pivot + Vector3(drag_offset.x, drag_offset.y, 0))
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
