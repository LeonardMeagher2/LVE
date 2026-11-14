extends "res://tests/test.gd"

# One process runs the transform-workflow tests. Each test keeps the steps and
# checks of its original scene. The user arguments after `--` name the tests to
# run, so an old scene name still selects its own test.

const TransformGizmoScript := preload("res://plugins/Transform/tools/TransformGizmo.gd")

var viewport: SubViewport

var _originals_captured := false
var _original_size := Vector2i.ZERO
var _original_stretch := true
var _mouse_held := false
var _last_mouse_pos := Vector2.ZERO
var _defaults_ready := false
var _default_tool := 0
var _default_snap := true
var _default_uniform := true
var _gizmo_radius := 0.0


func _ready() -> void:
	test("the transform toolbar swaps tools and the option bar reflects tool state", _transform_mode, "transform_mode")
	test("the move tool drags a whole shape, keeps the selection in sync, and commits or cancels", _transform_move, "transform_move")
	test("moving a selection over a stationary voxel hides it, restores it if passed, and overwrites it if landed on", _transform_obstacle, "transform_obstacle")
	test("the transform gizmo shows the source pivot and follows the transform", _transform_gizmo, "transform_gizmo")


# Each test starts from an empty frame, no selection, no history, the Move tool,
# and a known camera and viewport. The hooks run under the per-test watchdog.
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


# Finish any held press and pending transform, then restore the camera and
# viewport. A later test must not inherit a mid-drag transform or a moved view.
func after_test() -> void:
	await get_tree().process_frame
	_release_held_press()
	_stop_pending_transform()
	_restore_view_state()


func _transform_mode() -> void:
	step("Given a painted bar with the transform tool active", func():
		_view_setup()
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


func _transform_gizmo() -> void:
	step("Given a selected bar with the move tool active", func():
		_view_setup()
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_paint_bar()
		_select_bar()
		activate_tool("transform")
		select_toolbar_item("transform", "Move")
	)
	await get_tree().process_frame

	step("Then the move gizmo sits at the selection center", func():
		var p := plugin("TransformPlugin")
		var gizmo = p._move.get_node("Gizmo")
		expect(gizmo.is_visible_in_tree(), "the move gizmo is visible")
		expect(gizmo.global_position.is_equal_approx(Vector3(1, 0, 0)), "the move gizmo sits at the selection bounds center")
		var mesh := gizmo.mesh as ArrayMesh
		expect(mesh != null and mesh.get_surface_count() == 1, "the move gizmo has one line surface")
		var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		expect(vertices.size() > 0, "the move gizmo has line vertices")
		var material := gizmo.material_override as StandardMaterial3D
		expect(material != null and material.no_depth_test, "the gizmo draws over geometry")
		expect(material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, "the gizmo ignores the light")
	)

	step("When the user zooms in on the move gizmo", func():
		var gizmo = plugin("TransformPlugin")._move.get_node("Gizmo")
		_gizmo_radius = _gizmo_screen_radius(gizmo)
		camera_rig().set_zoom_percent(200)
	)

	step("Then the gizmo keeps its screen radius", func():
		var gizmo = plugin("TransformPlugin")._move.get_node("Gizmo")
		expect(absf(_gizmo_screen_radius(gizmo) - _gizmo_radius) <= 1.0, "the gizmo keeps a constant screen radius")
		camera_rig().set_zoom_percent(100)
	)

	step("When the user switches to Rotate and hovers away from the pivot", func():
		select_toolbar_item("transform", "Rotate")
		var gizmo = plugin("TransformPlugin")._rotate.get_node("Gizmo")
		var pointer := camera_rig().unproject_position(gizmo.global_position + Vector3(2, 1, 0))
		_hover_motion(pointer)
	)

	step("Then the rotate gizmo draws a bone to the pointer", func():
		var gizmo = plugin("TransformPlugin")._rotate.get_node("Gizmo")
		expect(gizmo.is_visible_in_tree(), "the rotate gizmo is visible")
		expect(gizmo.kind == TransformGizmoScript.Kind.ROTATE, "the rotate gizmo uses the rotate kind")
		expect(gizmo._has_tip, "the bone has a tip at the pointer")
		var pointer := camera_rig().unproject_position(gizmo.global_position + Vector3(2, 1, 0))
		expect(camera_rig().unproject_position(gizmo._last_tip).distance_to(pointer) <= 1.0, "the bone tip follows the pointer")
	)

	step("When the user drags the rotate bone", func():
		var gizmo = plugin("TransformPlugin")._rotate.get_node("Gizmo")
		var pivot: Vector3 = gizmo.global_position
		var from := camera_rig().unproject_position(pivot)
		var to := camera_rig().unproject_position(pivot + Vector3(0, 3, 0))
		_mouse_button(from, true)
		_mouse_motion(to)
	)

	step("Then the bone stays on the rotation pivot and follows the drag", func():
		var gizmo = plugin("TransformPlugin")._rotate.get_node("Gizmo")
		expect(gizmo.global_position.is_equal_approx(Vector3(1, 0, 0)), "the rotate gizmo stays on the rotation pivot")
		var drag_point := camera_rig().unproject_position(Vector3(1, 3, 0))
		expect(camera_rig().unproject_position(gizmo._last_tip).distance_to(drag_point) <= 1.0, "the bone tip follows the drag")
		_release_at(_last_mouse_pos)
		_press_option("Cancel")
	)

	step("When the user switches to Scale", func():
		select_toolbar_item("transform", "Scale")
	)

	step("Then the scale gizmo sits at the selection center", func():
		var gizmo = plugin("TransformPlugin")._scale.get_node("Gizmo")
		expect(gizmo.is_visible_in_tree(), "the scale gizmo is visible")
		expect(gizmo.kind == TransformGizmoScript.Kind.SCALE, "the scale gizmo uses the scale kind")
		expect(gizmo.global_position.is_equal_approx(Vector3(1, 0, 0)), "the scale gizmo starts at the selection center")
	)

	step("When the selection moves to one cell", func():
		State.selection.clear()
		State.selection.add(Vector3i(10, 0, 0))
		State.selection_changed.emit()
	)

	step("Then the gizmo follows the new selection", func():
		var gizmo = plugin("TransformPlugin")._scale.get_node("Gizmo")
		expect(gizmo.global_position.is_equal_approx(Vector3(10, 0, 0)), "the gizmo follows the selection bounds")
	)

	step("When the user switches to Move and grabs the gizmo", func():
		select_toolbar_item("transform", "Move")
		var gizmo = plugin("TransformPlugin")._move.get_node("Gizmo")
		var pivot: Vector3 = gizmo.global_position
		var from := camera_rig().unproject_position(pivot)
		var to := camera_rig().unproject_position(pivot + Vector3(1, 0, 0))
		_mouse_button(from, true)
		_mouse_motion(to)
		_mouse_button(to, false)
	)

	step("Then the move is pending and the gizmo follows the destination", func():
		var move = plugin("TransformPlugin")._move
		expect(move._pending, "the gizmo press starts a transform")
		var gizmo = move.get_node("Gizmo")
		expect(gizmo.global_position.is_equal_approx(Vector3(11, 0, 0)), "the move gizmo follows the destination center")
		_press_option("Commit")
	)

	step("When the frame and selection are empty", func():
		State.selection.clear()
		_frame().clear()
		State.selection_changed.emit()
		sync_viewport()
	)

	step("Then the move gizmo hides", func():
		var gizmo = plugin("TransformPlugin")._move.get_node("Gizmo")
		expect(not gizmo.is_visible_in_tree(), "the gizmo hides when the source is empty")
	)

	step("When the user switches to the brush", func():
		activate_tool("Toolbar")
	)

	step("Then the gizmo hides with the transform tool", func():
		var gizmo = plugin("TransformPlugin")._move.get_node("Gizmo")
		expect(not gizmo.is_visible_in_tree(), "the gizmo hides while the transform tool is inactive")
	)

	step("When the user returns to the transform tool with one selected cell", func():
		_frame().set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.RED))
		State.selection.add(Vector3i(0, 0, 0))
		State.selection_changed.emit()
		activate_tool("transform")
	)
	await get_tree().process_frame

	step("Then the gizmo shows again", func():
		var p := plugin("TransformPlugin")
		var gizmo = p._current_tool.get_node("Gizmo")
		expect(gizmo.is_visible_in_tree(), "the gizmo returns with the transform tool")
		expect(gizmo.global_position.is_equal_approx(Vector3.ZERO), "the gizmo sits on the new selection")
	)


func _transform_move() -> void:
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


func _transform_obstacle() -> void:
	step("Given a selected voxel, a stationary voxel in its path, and the move tool active", func():
		_view_setup()
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_frame().set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.from_rgba8(200, 60, 60)))
		_frame().set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.from_rgba8(40, 120, 40)))
		State.selection.add(Vector3i(0, 0, 0))
		State.selection_changed.emit()
		activate_tool("transform")
	)

	step("When the user drags the voxel across the stationary voxel and past it", func():
		_press_at(_screen(Vector3(0, 0, 0)))
		_move_to(_screen(Vector3(1, 0, 0)))
	)

	step("Then the stationary voxel is hidden under the moved voxel", func():
		expect(_color_at(Vector3i(1, 0, 0)).is_equal_approx(Color.from_rgba8(200, 60, 60)), "the moved voxel now shows at the covered cell")
	)

	step("When the user keeps dragging past the stationary voxel and releases", func():
		_move_to(_screen(Vector3(2, 0, 0)))
		_release_at(_screen(Vector3(2, 0, 0)))
		_press_option("Commit")
	)

	step("Then the stationary voxel is restored and the moved voxel sits at the far cell", func():
		expect(_color_at(Vector3i(1, 0, 0)).is_equal_approx(Color.from_rgba8(40, 120, 40)), "the stationary voxel survives the pass-over")
		expect(_color_at(Vector3i(2, 0, 0)).is_equal_approx(Color.from_rgba8(200, 60, 60)), "the moved voxel reached the far cell")
		expect(not _frame().has(Vector3i(0, 0, 0)), "the origin cell is empty")
		_expect_selection([Vector3i(2, 0, 0)])
	)

	step("Given the same setup again with the move tool active", func():
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		_frame().set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.from_rgba8(200, 60, 60)))
		_frame().set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.from_rgba8(40, 120, 40)))
		State.selection.add(Vector3i(0, 0, 0))
		State.selection_changed.emit()
	)

	step("When the user drags the voxel onto the stationary voxel and commits", func():
		_press_at(_screen(Vector3(0, 0, 0)))
		_move_to(_screen(Vector3(1, 0, 0)))
		_release_at(_screen(Vector3(1, 0, 0)))
		_press_option("Commit")
	)

	step("Then the moved voxel wins at the shared cell", func():
		expect(_color_at(Vector3i(1, 0, 0)).is_equal_approx(Color.from_rgba8(200, 60, 60)), "landing on the stationary voxel overwrites it")
		expect(_frame().count() == 1, "only one voxel remains at the destination")
	)


# Shared fixture: the viewport at a fixed size, looking at the front.
func _view_setup() -> void:
	viewport = editor_viewport()
	var container := viewport.get_parent()
	container.stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().set_view("front")


func _paint_bar() -> void:
	var frame := State.document.frames[0]
	for i in 3:
		frame.set_cell(Vector3i(i, 0, 0), VoxelFrame.material(Color.from_rgba8(200, 60, 60)))


func _select_bar() -> void:
	State.selection.clear()
	for i in 3:
		State.selection.add(Vector3i(i, 0, 0))
	State.selection_changed.emit()


func _frame() -> VoxelFrame:
	return State.document.frames[0]


func _color_at(c: Vector3i) -> Color:
	return State.document.get_color_at(0, c)


func _screen(world: Vector3) -> Vector2:
	return camera_rig().unproject_position(world)


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


func _press_at(pos: Vector2) -> void:
	_mouse_button(pos, true)


func _move_to(pos: Vector2) -> void:
	_mouse_motion(pos)


func _release_at(pos: Vector2) -> void:
	_mouse_button(pos, false)


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


func _hover_motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.button_mask = 0
	viewport.push_input(ev)
	_last_mouse_pos = pos


func _gizmo_screen_radius(gizmo) -> float:
	var center := camera_rig().unproject_position(gizmo.global_position)
	var edge := camera_rig().unproject_position(gizmo.global_transform * Vector3.RIGHT)
	return center.distance_to(edge)


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
	if not _defaults_ready:
		_default_tool = p._settings.tool
		_default_snap = p._settings.snap
		_default_uniform = p._settings.uniform
		_defaults_ready = true
	p._settings.tool = _default_tool
	p._settings.snap = _default_snap
	p._settings.uniform = _default_uniform
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
