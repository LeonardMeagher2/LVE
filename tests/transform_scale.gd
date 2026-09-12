extends "res://tests/test.gd"

var viewport: SubViewport


func _ready() -> void:
	test("the scale tool stretches, mirrors, and compounds around the selection's own center", _run)


func _run() -> void:
	step("Given a solid 4x4 block selected with the scale tool active in the front view", func():
		_view_setup()
		State.undo_redo.clear_history()
		_paint_block(4)
		activate_tool("transform")
		select_toolbar_item("transform", "Scale")
	)

	step("When the user drags to double the distance from the pivot with uniform on", func():
		_drag_from_pivot(Vector2(4, 4), Vector2(8, 8))
		_press_option("Commit")
	)

	step("Then the block doubles cleanly into an 8x8x2 block with no holes or duplicates", func():
		# Uniform scale is a true 3D scale, so the depth axis (invisible from the front view)
		# doubles from 1 layer to 2 right along with the two visible axes: 8 * 8 * 2 = 128.
		expect(_cells().size() == 128, "the scaled block holds exactly 128 voxels (has %d)" % _cells().size())
		_expect_bounds(Vector3i(-2, -2, 0), Vector3i(5, 5, 1))
	)

	step("Given the same solid 4x4 block again with uniform off", func():
		State.undo_redo.clear_history()
		_paint_block(4)
		press_option("Scale uniformly")
	)

	step("When the user drags to double the distance along only one axis", func():
		_drag_from_pivot(Vector2(4, 4), Vector2(8, 4))
		_press_option("Commit")
	)

	step("Then only that axis stretches, into an 8x4 block", func():
		expect(_cells().size() == 32, "the stretched block holds exactly 32 voxels (has %d)" % _cells().size())
		_expect_bounds(Vector3i(-2, 0, 0), Vector3i(5, 3, 0))
	)

	step("Given the block again with uniform back on, plus a marker in one corner", func():
		State.undo_redo.clear_history()
		press_option("Scale uniformly")
		_paint_block(4)
		_cells()[Vector3i(3, 3, 0)] = Color.from_rgba8(40, 120, 40)
	)

	step("When the user drags past the pivot to the opposite side", func():
		_drag_from_pivot(Vector2(4, 4), Vector2(-4, -4))
		_press_option("Commit")
	)

	step("Then the shape mirrors through the pivot, keeping its size and voxel count", func():
		expect(_cells().size() == 16, "the mirrored block still holds 16 voxels (has %d)" % _cells().size())
		# A -1 factor is still uniform (all 3 axes flip through the pivot), so the depth axis
		# mirrors from z=0 to z=-1 instead of staying put.
		_expect_bounds(Vector3i(-1, -1, -1), Vector3i(2, 2, -1))
		expect(_color_at(Vector3i(-1, -1, -1)).is_equal_approx(Color.from_rgba8(40, 120, 40)), "the marker moved to the mirrored corner")
	)

	step("Given a solid 2x2 block selected with the scale tool active", func():
		State.undo_redo.clear_history()
		_paint_block(2)
	)

	step("When the user scales up 2x, pauses, then scales up 2x again from the new size", func():
		_drag_from_pivot(Vector2(2, 2), Vector2(4, 4))
		_drag_from_pivot(Vector2(4, 4), Vector2(8, 8))
		_press_option("Commit")
	)

	step("Then the two 2x steps compound into a single 4x scale, centered where it started", func():
		# The depth axis compounds too: 1 layer -> 4 layers, same as the two visible axes' 2x2.
		expect(_cells().size() == 256, "compounding two 2x scales holds exactly 256 voxels (has %d)" % _cells().size())
		_expect_bounds(Vector3i(-3, -3, -1), Vector3i(4, 4, 2))
		expect(State.undo_redo.has_undo(), "the compounded scale is still a single undo step")
	)

	step("When the user undoes the compounded scale", func():
		State.undo_redo.undo()
	)

	step("Then the original 2x2 block returns exactly", func():
		expect(_cells().size() == 4, "the original block returns with 4 voxels")
		_expect_bounds(Vector3i(0, 0, 0), Vector3i(1, 1, 0))
	)


func _view_setup() -> void:
	viewport = editor_viewport()
	var container := viewport.get_parent()
	container.stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().set_view("front")


func _paint_block(size: int) -> void:
	State.selection.clear()
	_cells().clear()
	for x in size:
		for y in size:
			var c := Vector3i(x, y, 0)
			_cells()[c] = Color.from_rgba8(200, 60, 60)
			State.selection.add(c)
	State.selection_changed.emit()


func _cells() -> Dictionary:
	return State.document.frames[0].cells


func _color_at(c: Vector3i) -> Color:
	return State.document.get_color_at(0, c)


func _expect_bounds(lo: Vector3i, hi: Vector3i) -> void:
	var min_c := Vector3i(999999, 999999, 999999)
	var max_c := Vector3i(-999999, -999999, -999999)
	for c in _cells():
		min_c = Vector3i(mini(min_c.x, c.x), mini(min_c.y, c.y), mini(min_c.z, c.z))
		max_c = Vector3i(maxi(max_c.x, c.x), maxi(max_c.y, c.y), maxi(max_c.z, c.z))
	expect(min_c == lo, "the shape's low corner is %s (was %s)" % [lo, min_c])
	expect(max_c == hi, "the shape's high corner is %s (was %s)" % [hi, max_c])


func _current_center() -> Vector3:
	var b := AABB()
	var first := true
	for c in _cells():
		var cb := AABB(Vector3(c) - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
		b = cb if first else b.merge(cb)
		first = false
	return b.get_center()


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