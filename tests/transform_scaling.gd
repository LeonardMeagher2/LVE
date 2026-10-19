extends "res://tests/test.gd"

# One process runs the two transform-scaling tests. Each test keeps the steps
# and checks of its original scene. The user arguments after `--` name the tests
# to run, so an old scene name still selects its own test.

var viewport: SubViewport

var _originals_captured := false
var _original_size := Vector2i.ZERO
var _original_stretch := true
var _mouse_held := false
var _last_mouse_pos := Vector2.ZERO


func _ready() -> void:
	test("the scale tool stretches, mirrors, and compounds around the selection's own center", _transform_scale, "transform_scale")
	test("a pending scale continues correctly after the view changes mid-drag", _transform_scale_view_switch, "transform_scale_view_switch")


# Each test starts from an empty frame, no selection, no history, the Move tool,
# and a known camera and viewport. The hooks run under the per-test watchdog.
func _setup_test() -> void:
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


# Finish any held press and pending transform, then restore the camera and
# viewport. A later test must not inherit a mid-drag transform or a moved view.
func _cleanup_test() -> void:
	await get_tree().process_frame
	_release_held_press()
	_stop_pending_transform()
	_restore_view_state()


func _transform_scale() -> void:
	step("Given a solid 4x4 block selected with the scale tool active in the front view", func():
		_view_setup()
		State.undo_redo.clear_history()
		_paint_block(4)
		activate_tool("transform")
		select_toolbar_item("transform", "Scale")
	)

	step("When the user drags to double the distance from the pivot with uniform on", func():
		_drag_from_pivot(_current_center(), Vector3(4, 4, 0), Vector3(8, 8, 0))
		_press_option("Commit")
	)

	step("Then the block doubles cleanly into an 8x8x2 block with no holes or duplicates", func():
		# Uniform scale is a true 3D scale, so the depth axis (invisible from the front view)
		# doubles from 1 layer to 2 right along with the two visible axes: 8 * 8 * 2 = 128.
		expect(_frame().count() == 128, "the scaled block holds exactly 128 voxels (has %d)" % _frame().count())
		_expect_bounds(Vector3i(-2, -2, 0), Vector3i(5, 5, 1))
	)

	step("Given the same solid 4x4 block again with uniform off", func():
		State.undo_redo.clear_history()
		_paint_block(4)
		press_option("Scale uniformly")
	)

	step("When the user drags to double the distance along only one axis", func():
		_drag_from_pivot(_current_center(), Vector3(4, 4, 0), Vector3(8, 4, 0))
		_press_option("Commit")
	)

	step("Then only that axis stretches, into an 8x4 block", func():
		expect(_frame().count() == 32, "the stretched block holds exactly 32 voxels (has %d)" % _frame().count())
		_expect_bounds(Vector3i(-2, 0, 0), Vector3i(5, 3, 0))
	)

	step("Given the block again with uniform back on, plus a marker in one corner", func():
		State.undo_redo.clear_history()
		press_option("Scale uniformly")
		_paint_block(4)
		_frame().set_cell(Vector3i(3, 3, 0), VoxelFrame.material(Color.from_rgba8(40, 120, 40)))
	)

	step("When the user drags past the pivot to the opposite side", func():
		_drag_from_pivot(_current_center(), Vector3(4, 4, 0), Vector3(-4, -4, 0))
		_press_option("Commit")
	)

	step("Then the shape mirrors through the pivot, keeping its size and voxel count", func():
		expect(_frame().count() == 16, "the mirrored block still holds 16 voxels (has %d)" % _frame().count())
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
		_drag_from_pivot(_current_center(), Vector3(2, 2, 0), Vector3(4, 4, 0))
		_drag_from_pivot(_current_center(), Vector3(4, 4, 0), Vector3(8, 8, 0))
		_press_option("Commit")
	)

	step("Then the two 2x steps compound into a single 4x scale, centered where it started", func():
		# The depth axis compounds too: 1 layer -> 4 layers, same as the two visible axes' 2x2.
		expect(_frame().count() == 256, "compounding two 2x scales holds exactly 256 voxels (has %d)" % _frame().count())
		_expect_bounds(Vector3i(-3, -3, -1), Vector3i(4, 4, 2))
		expect(State.undo_redo.has_undo(), "the compounded scale is still a single undo step")
	)

	step("When the user undoes the compounded scale", func():
		State.undo_redo.undo()
	)

	step("Then the original 2x2 block returns exactly", func():
		expect(_frame().count() == 4, "the original block returns with 4 voxels")
		_expect_bounds(Vector3i(0, 0, 0), Vector3i(1, 1, 0))
	)


func _transform_scale_view_switch() -> void:
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


# Shared fixture: the viewport at a fixed size, looking at the named view.
func _view_setup(view_name := "front") -> void:
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
			_frame().set_cell(c, VoxelFrame.material(Color.from_rgba8(200, 60, 60)))
			State.selection.add(c)
	State.selection_changed.emit()


func _frame() -> VoxelFrame:
	return State.document.frames[0]


func _color_at(c: Vector3i) -> Color:
	return State.document.get_color_at(0, c)


func _current_center() -> Vector3:
	var b := AABB()
	var first := true
	for c in _frame().positions():
		var cb := AABB(Vector3(c) - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
		b = cb if first else b.merge(cb)
		first = false
	return b.get_center()


func _expect_bounds(lo: Vector3i, hi: Vector3i) -> void:
	var min_c := Vector3i(999999, 999999, 999999)
	var max_c := Vector3i(-999999, -999999, -999999)
	for c in _frame().positions():
		min_c = Vector3i(mini(min_c.x, c.x), mini(min_c.y, c.y), mini(min_c.z, c.z))
		max_c = Vector3i(maxi(max_c.x, c.x), maxi(max_c.y, c.y), maxi(max_c.z, c.z))
	expect(min_c == lo, "the shape's low corner is %s (was %s)" % [lo, min_c])
	expect(max_c == hi, "the shape's high corner is %s (was %s)" % [hi, max_c])


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
	_mouse_held = pressed
	_last_mouse_pos = pos


func _mouse_motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(ev)
	_last_mouse_pos = pos


func _press_option(tooltip: String) -> void:
	var b := _find_option_button(tooltip)
	if b != null:
		b.pressed.emit()


# Capture the viewport size and stretch once, before any test changes them.
func _capture_originals_once() -> void:
	if _originals_captured:
		return
	var vp := editor_viewport()
	_original_size = vp.size
	_original_stretch = vp.get_parent().stretch
	_originals_captured = true


# The transform settings live in a shared Resource. Reset the tool and the
# toggles so a test never inherits the previous test's choice.
func _reset_transform_settings() -> void:
	var p := plugin("TransformPlugin")
	if p == null:
		return
	p._settings.tool = p._settings.Tools.MOVE
	p._settings.snap = true
	p._settings.uniform = true
	p._settings.transforming = false


func _release_held_press() -> void:
	if not _mouse_held:
		return
	_mouse_button(_last_mouse_pos, false)


# Cancel a transform that a test left mid-drag or pending. The tool clears its
# grab and restores the source shape, so the next test starts clean.
func _stop_pending_transform() -> void:
	var p := plugin("TransformPlugin")
	if p == null:
		return
	var tool = p._current_tool
	if tool != null and (tool._dragging or tool._pending):
		tool._cancel()


func _restore_view_state() -> void:
	var vp := editor_viewport()
	if _originals_captured:
		vp.get_parent().stretch = _original_stretch
		vp.size = _original_size
	camera_rig().set_view("default")
	camera_rig().is_orthogonal = false
