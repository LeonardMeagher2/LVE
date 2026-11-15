extends "res://tests/test.gd"

# One process runs the transform view-axis tests. The option is on by default,
# so the camera plane drives the drag. The plane mode keeps the nearest world
# axis. A named view within two degrees of an axis stays exact.

const VIEW_TOOLTIP := "Use the view axis. When off, snap to the nearest world axis plane."

var viewport: SubViewport
var _originals_captured := false
var _original_size := Vector2i.ZERO
var _original_stretch := true
var _mouse_held := false
var _last_mouse_pos := Vector2.ZERO


func _ready() -> void:
	test("the view-axis toggle is on by default and stays in sync for every transform tool", _toggle, "transform_view_axis_toggle")
	test("a view-axis move follows the camera plane instead of the nearest world axis plane", _move, "transform_view_axis_move")
	test("a view-axis rotate turns about the camera normal", _rotate, "transform_view_axis_rotate")
	test("a non-uniform view scale uses the camera plane and resamples", _scale, "transform_view_axis_scale")
	test("a top view stays on the exact world axis", _top, "transform_view_axis_top")
	test("a plane-mode quarter turn keeps every voxel in each named view", _plane_rotation, "transform_view_axis_plane_rotation")
	test("a plane-mode rotation measures the drag on the screen plane", _plane_screen_angle, "transform_view_axis_plane_screen_angle")


func before_test() -> void:
	_capture_originals_once()
	State.stop()
	State.current_frame = 0
	State.active_tag = 0
	State.selection.clear()
	State.undo_redo.clear_history()
	_frame().clear()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	_reset_transform_settings()
	camera_rig().set_view("default")
	camera_rig().is_orthogonal = false


func after_test() -> void:
	await get_tree().process_frame
	_release_held_press()
	_stop_pending_transform()
	_restore_view_state()


func _toggle() -> void:
	step("Given the transform tool with the Move tool active", func():
		_view_setup("default")
		activate_tool("transform")
		select_toolbar_item("transform", "Move")
	)

	step("Then the view-axis option is visible and on", func():
		var button := _option(VIEW_TOOLTIP)
		expect(button != null, "the option bar has a view-axis button")
		expect(button.visible, "the view-axis button is visible for Move")
		expect(button.button_pressed, "the view-axis option starts on")
		expect(_settings().view_axis, "the setting starts on")
	)

	step("When the user switches to Rotate and Scale", func():
		select_toolbar_item("transform", "Rotate")
		expect(_option(VIEW_TOOLTIP).visible, "the view-axis button is visible for Rotate")
		select_toolbar_item("transform", "Scale")
		expect(_option(VIEW_TOOLTIP).visible, "the view-axis button is visible for Scale")
	)

	step("When the user turns the option off", func():
		press_option(VIEW_TOOLTIP)
	)

	step("Then the setting and the button turn off", func():
		expect(not _settings().view_axis, "the setting turns off")
		expect(not _option(VIEW_TOOLTIP).button_pressed, "the button shows the off state")
	)

	step("When the setting changes outside the button", func():
		_settings().view_axis = true
	)

	step("Then the button follows the setting", func():
		expect(_option(VIEW_TOOLTIP).button_pressed, "the button follows a setting change")
	)


func _move() -> void:
	step("Given a selected voxel in the default view with Move active", func():
		_view_setup("default")
		_paint_cell(Vector3i.ZERO)
		_select_cells([Vector3i.ZERO])
		activate_tool("transform")
		select_toolbar_item("transform", "Move")
	)

	step("When the user drags one cell along screen up", func():
		_drag_world(Vector3.ZERO, Vector3(0, 1, -1))
	)

	step("Then the voxel follows the camera plane", func():
		_expect_cells([Vector3i(0, 1, -1)])
		_expect_selection([Vector3i(0, 1, -1)])
		var camera := camera_rig()
		var view_plane: Vector3 = _move_tool()._plane.normal
		expect(absf(view_plane.dot(-camera.global_transform.basis.z)) >= 0.999, "the drag plane faces the camera")
		_press_option("Cancel")
	)

	step("When the user turns the option off and presses again", func():
		press_option(VIEW_TOOLTIP)
		_press_world(Vector3.ZERO)
	)

	step("Then the drag plane uses the nearest world axis", func():
		var plane: Vector3 = _move_tool()._plane.normal
		expect(_move_tool()._axis_of(plane) == 1, "the plane faces the Y axis")
		_release_at(_last_mouse_pos)
		_press_option("Cancel")
	)


func _rotate() -> void:
	step("Given a selected bar in the default view with Rotate active and snap on", func():
		_view_setup("default")
		_paint_bar()
		_select_cells([Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)])
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
		_settings().snap = true
	)

	step("When the user drags a quarter turn on screen", func():
		_drag_screen_from_center(Vector2(0, -120))
	)

	step("Then the rotation axis is the camera normal", func():
		var axis: Vector3 = _rotate_tool()._job_axis
		var camera := camera_rig()
		expect(not axis.is_zero_approx(), "the drag captured a rotation axis")
		expect(absf(axis.dot(-camera.global_transform.basis.z)) >= 0.999, "the axis faces the camera")
		expect(_rotate_tool()._axis_of(axis) == -1, "the axis is not a world axis")
		expect(_frame().count() > 0, "the view rotation keeps voxels")
		expect(_rotate_tool()._total_basis.is_equal_approx(Basis.from_euler(_rotate_tool()._euler, EULER_ORDER_XYZ)), "the dialog Euler round-trips the view rotation")
		_press_option("Cancel")
	)

	step("When the user turns the option off and drags again", func():
		press_option(VIEW_TOOLTIP)
		_drag_screen_from_center(Vector2(0, -120))
	)

	step("Then the rotation axis is the nearest world axis", func():
		expect(_rotate_tool()._axis_of(_rotate_tool()._job_axis) == 1, "the rotation axis is Y")
		_press_option("Cancel")
	)


func _scale() -> void:
	step("Given a selected block in the isometric view with Scale active and uniform off", func():
		_view_setup("isometric")
		_paint_cell(Vector3i.ZERO)
		_select_cells([Vector3i.ZERO])
		activate_tool("transform")
		select_toolbar_item("transform", "Scale")
		_settings().uniform = false
	)

	step("When the user doubles along screen X only", func():
		var center := _current_center()
		var right := camera_rig().global_transform.basis.x
		var up := camera_rig().global_transform.basis.y
		_drag_world(center + right * 2.0 + up * 2.0, center + right * 4.0 + up * 2.0)
	)

	step("Then the scale uses the screen basis and resamples", func():
		var tool := _scale_tool()
		expect(tool._use_view_scale, "the drag uses the view basis")
		expect(tool._view_basis.is_orthonormal(), "the view basis is orthonormal")
		expect(is_equal_approx(tool._view_scale.x, 2.0), "screen X doubles")
		expect(is_equal_approx(tool._view_scale.y, 1.0), "screen Y stays")
		var job = tool._make_job()
		expect(job.use_view_scale, "the job resamples in the view basis")
		expect(_frame().count() > 1, "the view scale writes the resampled shape")
	)

	step("When the user clicks without a drag to open the scale dialog", func():
		_click_world(_current_center())
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the dialog opens with the screen factors", func():
		var dialog = _scale_tool()._dialog
		expect(dialog.visible, "the scale dialog opens")
		expect(is_equal_approx(dialog.get_node("MarginContainer/ScaleRow/ScaleX").value, 2.0), "the dialog shows the screen X factor")
		dialog.get_node("MarginContainer/ScaleRow/ScaleX").value = 3.0
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("When the user cancels the dialog", func():
		var dialog = _scale_tool()._dialog
		dialog.canceled.emit()
		dialog.hide()
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the pending view scale returns", func():
		var tool := _scale_tool()
		expect(tool._use_view_scale, "the cancel restores the view scale")
		var job = tool._make_job()
		expect(job.use_view_scale, "the restored job resamples in the view basis")
		_press_option("Cancel")
	)

	step("When the user switches to the front view and drags again", func():
		_paint_cell(Vector3i.ZERO)
		_select_cells([Vector3i.ZERO])
		camera_rig().set_view("front")
		var center := _current_center()
		_drag_world(center + Vector3(2, 2, 0), center + Vector3(4, 2, 0))
	)

	step("Then the near-axis view keeps the world-axis scale path", func():
		var tool := _scale_tool()
		expect(not tool._use_view_scale, "a named view uses the world-axis path")
		var job = tool._make_job()
		expect(not job.use_view_scale, "the job does not resample in a view basis")
		_press_option("Cancel")
	)


func _top() -> void:
	step("Given a selected asymmetric shape in the top view with Rotate active and snap on", func():
		_view_setup("top")
		_paint_shape()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
		_settings().snap = true
	)

	step("When the user drags a quarter turn", func():
		_drag_screen_from_center(Vector2(0, -120))
	)

	step("Then the rotation stays on the exact Y axis", func():
		var tool := _rotate_tool()
		expect(tool._axis_of(tool._job_axis) == 1, "the near-axis view snaps to Y")
		expect(absf(tool._job_axis.y) >= 0.999, "the axis points along Y")
	)

	step("When the user commits the quarter turn", func():
		_press_option("Commit")
	)

	step("Then the rotation keeps every voxel", func():
		expect(_frame().count() == 9, "the quarter turn keeps all 9 voxels (has %d)" % _frame().count())
	)


func _plane_rotation() -> void:
	var original: Array[Vector3i] = [
		Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0),
		Vector3i(0, 1, 0), Vector3i(2, 1, 1),
		Vector3i(1, 0, 2), Vector3i(1, 1, 3),
		Vector3i(0, 0, 1), Vector3i(2, 0, 3),
	]
	for view_name in ["front", "right", "top"]:
		step("Given the asymmetric shape in the %s view with the view axis off" % view_name, func():
			_view_setup(view_name)
			_paint_shape()
			activate_tool("transform")
			select_toolbar_item("transform", "Rotate")
			_settings().snap = true
			_settings().view_axis = false
		)

		step("When the user turns the shape four quarter turns in the %s view" % view_name, func():
			for _i in 4:
				_drag_screen_from_center(Vector2(0, -120))
				_press_option("Commit")
		)

		step("Then the %s view returns the original shape" % view_name, func():
			expect(_frame().count() == original.size(), "the shape still holds %d voxels (has %d)" % [original.size(), _frame().count()])
			for cell in original:
				expect(_frame().has(cell), "cell %s returned" % cell)
		)


func _plane_screen_angle() -> void:
	step("Given a selected shape in the default view with the view axis off and snap off", func():
		_view_setup("default")
		_paint_shape()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
		_settings().snap = false
		_settings().view_axis = false
	)

	step("When the user drags sixty degrees on screen", func():
		var from := _screen(_current_center())
		var to := from + Vector2(60.0, -103.923)
		_mouse_button(from, true)
		_mouse_motion(to)
	)

	step("Then the drag angle follows the screen and the axis is Y", func():
		var tool := _rotate_tool()
		expect(tool._axis_of(tool._view_normal) == 1, "the rotation axis is the nearest world axis")
		expect(absf(rad_to_deg(tool._job_angle) - 60.0) <= 2.0, "the drag angle follows the screen (was %.1f degrees)" % rad_to_deg(tool._job_angle))
		_press_option("Cancel")
	)


func _view_setup(view_name: String) -> void:
	viewport = editor_viewport()
	var container := viewport.get_parent()
	container.stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().set_view(view_name)


func _screen(world: Vector3) -> Vector2:
	return camera_rig().unproject_position(world)


func _paint_cell(cell: Vector3i) -> void:
	State.selection.clear()
	_frame().clear()
	_frame().set_cell(cell, VoxelFrame.material(Color.RED))
	State.selection_changed.emit()


func _paint_bar() -> void:
	State.selection.clear()
	_frame().clear()
	for i in 3:
		_frame().set_cell(Vector3i(i, 0, 0), VoxelFrame.material(Color.RED))
	State.selection_changed.emit()


func _paint_shape() -> void:
	State.selection.clear()
	_frame().clear()
	var shape: Array[Vector3i] = [
		Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0),
		Vector3i(0, 1, 0), Vector3i(2, 1, 1),
		Vector3i(1, 0, 2), Vector3i(1, 1, 3),
		Vector3i(0, 0, 1), Vector3i(2, 0, 3),
	]
	for cell in shape:
		_frame().set_cell(cell, VoxelFrame.material(Color.RED))
		State.selection.add(cell)
	State.selection_changed.emit()


func _select_cells(cells: Array) -> void:
	State.selection.clear()
	for cell in cells:
		State.selection.add(cell)
	State.selection_changed.emit()


func _frame() -> VoxelFrame:
	return State.document.frames[0]


func _settings():
	return plugin("TransformPlugin")._settings


func _move_tool() -> Node:
	return plugin("TransformPlugin")._move


func _rotate_tool() -> Node:
	return plugin("TransformPlugin")._rotate


func _scale_tool() -> Node:
	return plugin("TransformPlugin")._scale


func _current_center() -> Vector3:
	var bounds := AABB()
	var first := true
	for cell in _frame().positions():
		var cell_bounds := AABB(Vector3(cell) - Vector3.ONE * 0.5, Vector3.ONE)
		bounds = cell_bounds if first else bounds.merge(cell_bounds)
		first = false
	return bounds.get_center()


func _drag_world(from: Vector3, to: Vector3) -> void:
	_mouse_button(_screen(from), true)
	_mouse_motion(_screen(to))
	_mouse_button(_screen(to), false)


func _drag_screen_from_center(rel: Vector2) -> void:
	var from := _screen(_current_center())
	var to := from + rel
	_mouse_button(from, true)
	_mouse_motion(to)
	_mouse_button(to, false)


func _press_world(world: Vector3) -> void:
	_mouse_button(_screen(world), true)


func _click_world(world: Vector3) -> void:
	_mouse_button(_screen(world), true)
	_mouse_button(_screen(world), false)


func _mouse_button(pos: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = pos
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(event)
	_mouse_held = pressed
	_last_mouse_pos = pos


func _mouse_motion(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(event)
	_last_mouse_pos = pos


func _release_at(pos: Vector2) -> void:
	_mouse_button(pos, false)


func _press_option(tooltip: String) -> void:
	var button := _find_option_button(tooltip)
	if button != null:
		button.pressed.emit()


func _option(tooltip: String) -> BaseButton:
	return _find_option_button(tooltip)


func _expect_cells(cells: Array) -> void:
	expect(_frame().count() == cells.size(), "the frame holds %d voxels" % cells.size())
	for cell in cells:
		expect(_frame().has(cell), "cell %s is present" % cell)


func _expect_selection(cells: Array) -> void:
	expect(State.selection.cells.size() == cells.size(), "the selection holds %d cells" % cells.size())
	for cell in cells:
		expect(State.selection.cells.has(cell), "the selection contains %s" % cell)


func _capture_originals_once() -> void:
	if _originals_captured:
		return
	var vp := editor_viewport()
	_original_size = vp.size
	_original_stretch = vp.get_parent().stretch
	_originals_captured = true


func _reset_transform_settings() -> void:
	var settings = _settings()
	settings.tool = settings.Tools.MOVE
	settings.view_axis = true
	settings.snap = true
	settings.uniform = true
	settings.transforming = false


func _release_held_press() -> void:
	if not _mouse_held:
		return
	_mouse_button(_last_mouse_pos, false)


func _stop_pending_transform() -> void:
	var tool = plugin("TransformPlugin")._current_tool
	if tool != null and (tool._dragging or tool._pending):
		tool._cancel()


func _restore_view_state() -> void:
	var container := editor_viewport().get_parent()
	if _originals_captured:
		container.stretch = _original_stretch
		editor_viewport().size = _original_size
	camera_rig().set_view("default")
	camera_rig().is_orthogonal = false
