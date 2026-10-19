extends "res://tests/test.gd"

# One process runs the four transform-rotation tests. Each test keeps the steps
# and checks of its original scene. The user arguments after `--` name the tests
# to run, so an old scene name still selects its own test.

var viewport: SubViewport
var _source: VoxelFrame

# A shape whose per-axis extents deliberately mismatch parity, mirroring the Flamingo asset that
# exposed the bug: X spans 3 cells, Y spans 2, Z spans 4. Rotating about Z (X,Y in-plane) or about
# Y (X,Z in-plane) both hit a genuine parity mismatch, which produced holes under the old
# floating-point rotation. Deliberately irregular (not a solid block), like real voxel art.
# The same shape also backs the view-switch test: parity mismatches on every axis catch rotation
# bugs that a solid or symmetric block would hide.
const SHAPE: Array = [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0),
	Vector3i(0, 1, 0), Vector3i(2, 1, 1),
	Vector3i(1, 0, 2), Vector3i(1, 1, 3),
	Vector3i(0, 0, 1), Vector3i(2, 0, 3),
]

# Hand-derived: SHAPE rotated 90 degrees around Z (front view), then 90 degrees around X (right
# view), both with the bounding box's own min corner held fixed, matching RotateTool's exact
# integer rotation convention.
const EXPECTED: Array = [
	Vector3i(1, 3, 0), Vector3i(1, 3, 1), Vector3i(1, 3, 2),
	Vector3i(0, 3, 0), Vector3i(0, 2, 2),
	Vector3i(1, 1, 1), Vector3i(0, 0, 1),
	Vector3i(1, 2, 0), Vector3i(1, 0, 2),
]

var _originals_captured := false
var _original_size := Vector2i.ZERO
var _original_stretch := true
var _mouse_held := false
var _last_mouse_pos := Vector2.ZERO


func _ready() -> void:
	test("the rotate tool turns a selected shape a quarter turn with snap, and the selection follows", _transform_rotate, "transform_rotate")
	test("rotating an asymmetric selection 90 degrees never leaves holes or duplicates, on any axis", _transform_rotate_asymmetric, "transform_rotate_asymmetric")
	test("rotating an irregular model 90 degrees preserves every voxel on each axis", _transform_rotate_flamingo, "transform_rotate_flamingo")
	test("a pending rotation continues correctly after the view changes mid-drag", _transform_rotate_view_switch, "transform_rotate_view_switch")


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


func _transform_rotate() -> void:
	step("Given a selected bar with the rotate tool and snap in the front view", func():
		_viewport_setup()
		camera_rig().set_view("front")
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_paint_bar()
		_select_bar()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
	)

	step("When the user drags the bar straight up and commits", func():
		_drag_screen(Vector2(0, -100))
		_press_option("Commit")
	)

	step("Then the bar sits vertical, its bounding box's near corner unmoved", func():
		_expect_cells([Vector3i(0, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 2, 0)])
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
		_expect_cells([Vector3i(0, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 2, 0)])
		_expect_selection([Vector3i(0, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 2, 0)])
	)

	step("Given the selected bar with the rotate tool again", func():
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_paint_bar()
		_select_bar()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
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


func _transform_rotate_asymmetric() -> void:
	step("Given the asymmetric shape selected with the rotate tool active", func():
		_viewport_setup()
		State.undo_redo.clear_history()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
	)

	for axis_name in ["front", "right", "top"]:
		step("When the user rotates the shape 90 degrees viewed from %s" % axis_name, func():
			_paint_shape()
			camera_rig().set_view(axis_name)
			_drag_screen(Vector2(0, -100))
			_press_option("Commit")
		)

		step("Then the rotated shape (%s) keeps every voxel, with no holes or duplicates" % axis_name, func():
			expect(_frame().count() == SHAPE.size(), "the rotated shape still holds %d voxels" % SHAPE.size())
		)

		step("When the user rotates the same shape 90 degrees three more times", func():
			for _i in 3:
				_drag_screen(Vector2(0, -100))
				_press_option("Commit")
		)

		step("Then four quarter turns (%s) return the exact original shape" % axis_name, func():
			var expected := {}
			for c in SHAPE:
				expected[c] = true
			expect(_frame().count() == SHAPE.size(), "the shape still holds %d voxels after four turns" % SHAPE.size())
			for c in expected:
				expect(_frame().has(c), "cell %s returned to its original position" % c)
		)


func _transform_rotate_flamingo() -> void:
	step("Given an irregular model fixture and the active Rotate tool", func():
		_viewport_setup()
		var fixture: VoxelFrame = load("res://tests/fixtures/rotation_model.tres")
		_source = fixture.copy_frame()
		expect(_source.count() > 0, "the model fixture contains voxels")
		State.undo_redo.clear_history()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
	)

	for axis_name in ["front", "right", "top"]:
		step("When the user rotates the model 90 degrees viewed from %s" % axis_name, func():
			State.selection.clear()
			_frame().restore(_source.capture())
			_select_all(_source)
			camera_rig().set_view(axis_name)
			_drag_screen(Vector2(0, -100))
			_press_option("Commit")
		)

		step("Then the rotated model preserves every voxel in the %s view" % axis_name, func():
			expect(_frame().count() == _source.count(), "the rotated model contains %d voxels" % _source.count())
		)


func _transform_rotate_view_switch() -> void:
	step("Given the asymmetric shape rotated 90 degrees in the front view, not yet committed", func():
		_viewport_setup()
		State.undo_redo.clear_history()
		_paint_shape()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
		camera_rig().set_view("front")
		_drag_screen(Vector2(0, -100))
	)

	step("When the user switches to a perpendicular view and rotates again without committing", func():
		camera_rig().set_view("right")
		_drag_screen(Vector2(0, -100))
		_press_option("Commit")
	)

	step("Then both rotations compose correctly, seen from either view", func():
		expect(_frame().count() == SHAPE.size(), "the shape still holds %d voxels" % SHAPE.size())
		for c in EXPECTED:
			expect(_frame().has(c), "cell %s is at its expected composed position" % c)
		expect(State.undo_redo.has_undo(), "the composed rotation is still a single undo step")
	)

	step("When the user undoes", func():
		State.undo_redo.undo()
	)

	step("Then the original shape returns exactly", func():
		expect(_frame().count() == SHAPE.size(), "the shape still holds %d voxels" % SHAPE.size())
		for c in SHAPE:
			expect(_frame().has(c), "cell %s is back at its original position" % c)
	)


# Shared fixture: the viewport at a fixed size. The caller sets the view.
func _viewport_setup() -> void:
	viewport = editor_viewport()
	var container := viewport.get_parent()
	container.stretch = false
	viewport.size = Vector2i(800, 500)


func _paint_bar() -> void:
	var frame := State.document.frames[0]
	for i in 3:
		frame.set_cell(Vector3i(i, 0, 0), VoxelFrame.material(Color.from_rgba8(200, 60, 60)))


func _select_bar() -> void:
	State.selection.clear()
	for i in 3:
		State.selection.add(Vector3i(i, 0, 0))
	State.selection_changed.emit()


func _paint_shape() -> void:
	State.selection.clear()
	_frame().clear()
	for c in SHAPE:
		_frame().set_cell(c, VoxelFrame.material(Color.from_rgba8(200, 60, 60)))
		State.selection.add(c)
	State.selection_changed.emit()


func _select_all(source: VoxelFrame) -> void:
	State.selection.clear()
	for c in source.positions():
		State.selection.add(c)
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


func _expect_cells(list: Array) -> void:
	expect(_frame().count() == list.size(), "the frame holds %d voxels" % list.size())
	for c in list:
		expect(_frame().has(c), "cell %s is present" % c)


func _expect_selection(list: Array) -> void:
	expect(State.selection.cells.size() == list.size(), "the selection holds %d cells" % list.size())
	for c in list:
		expect(State.selection.cells.has(c), "the selection contains %s" % c)


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
