extends "res://tests/test.gd"

# The deform tools: Grab and Pose.
#
# Grab moves every captured source by a weighted, mirrored offset from one
# baseline snapshot. Pose bends the connected limb around its joint. Both commit
# one history action on release and roll back on Escape.
#
# The cases drive the real pointer input through the viewport, so the pick, the
# view plane, and the undo path are the shipped ones.

const FLOOR_AXIS := {
	"top": Vector3.Axis.AXIS_Y,
	"bottom": Vector3.Axis.AXIS_Y,
	"front": Vector3.Axis.AXIS_Z,
	"back": Vector3.Axis.AXIS_Z,
	"left": Vector3.Axis.AXIS_X,
	"right": Vector3.Axis.AXIS_X,
	"isometric": Vector3.Axis.AXIS_Y,
}

var _settings := preload("res://plugins/Deform/settings.tres")
var viewport: SubViewport
var tool: Node3D
var frame: VoxelFrame
var press := Vector2.ZERO
var anchor := Vector3i.ZERO
# A step lambda captures a local by value, so the pose cases keep the values they
# compare across steps on members.
var pose_before := {}
var pose_bent := {}
var pose_count := 0


func _ready() -> void:
	timeout = 30.0
	
	test("grab drags on the true camera-facing plane", _grab_oblique, "grab_oblique")
	test("grab stretches voxels, keeps materials, and preserves unrelated geometry", _grab_stretch, "grab_stretch")
	test("grab moves a selected source outside the selection and follows it", _grab_selection_destination, "grab_selection_destination")
	test("grab ignores sources and destinations outside the document size", _grab_stops_at_document_edge, "grab_stops_at_document_edge")
	test("grab without a source changes nothing", _grab_empty, "grab_empty")
	test("a large grab runs on the worker pool and publishes once", _grab_worker, "grab_worker")
	test("a grab honors the shared size bound past the old cap", _grab_shared_radius, "grab_shared_radius")
	test("a queued return to the origin closes the edit", _grab_pending_return, "grab_pending_return")
	test("a drag that returns to the origin restores the selection", _deform_return_selection, "deform_return_selection")
	test("a cancelled worker cannot touch a replacement stroke", _cancel_repress, "cancel_repress")
	test("a click right after a cancelled worker job closes its edit", _cancel_worker_click, "cancel_worker_click")
	test("the deform options and menu hold Grab and Pose", _deform_controls, "deform_controls")
	
	test("pose bends the connected limb and keeps the far side still", _pose_limb, "pose_limb")
	test("a hover shows the rotation point before the press", _pose_hover_pivot, "pose_hover_pivot")
	test("the cursor circle spans the joint reach around the picked cell", _pose_cursor_circle, "pose_cursor_circle")
	test("pose keeps the bent limb solid", _pose_solid, "pose_solid")
	test("a limb that runs into the screen bases near the press", _pose_end_on, "pose_end_on")
	test("pose mirrors its bend through the symmetry", _pose_symmetry, "pose_symmetry")
	test("pose keeps the bend inside the document size", _pose_document_edge, "pose_document_edge")
	test("a pose stroke supports undo and Escape", _pose_history, "pose_history")
	test("a selection limits a pose and follows the moved cells", _pose_selection, "pose_selection")
	test("a second pointer motion does not flash the bend", _pose_stable, "pose_stable")
	test("the rotation angle is the angle from the base to the pointer", _pose_pointer_angle, "pose_pointer_angle")
	test("a wide brush on a thin limb cannot smear the turn", _pose_no_smear, "pose_no_smear")
	test("the joint search stays near the press on a long limb", _pose_search_bound, "pose_search_bound")
	test("the base prefers a cell on the view plane of the pressed cell", _pose_depth_bias, "pose_depth_bias")
	test("the base leans to the half of the face under the pointer", _pose_face_bias, "pose_face_bias")
	test("pose on a large blob bends a bounded set and keeps it solid", _pose_large_blob, "pose_large_blob")


func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	State.slice_layers = 0
	_use(_settings.Tools.GRAB)
	_settings.size = 5
	_settings.falloff = 0.5
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().is_orthogonal = true
	frame = State.get_current_voxel_frame()
	activate_tool("deform")
	plugin("DeformPlugin").activate_tool()
	tool = plugin("DeformPlugin")._current_tool
	tool.set_process(true)
	await get_tree().process_frame


# Selects one deform tool and refreshes the tool handle. The plugin swaps the
# active node on the settings change, so a test must read the node after it.
func _use(kind: int) -> void:
	_settings.tool = kind
	tool = plugin("DeformPlugin")._current_tool


func after_test() -> void:
	if tool != null and tool._edit != null:
		tool.finish_on_switch()
	State.stop()


# --- Helpers ----------------------------------------------------------------


func _view(view: String) -> void:
	State.floor_axis = FLOOR_AXIS[view]
	camera_rig().set_view(view)
	camera_rig().is_orthogonal = true


func _pos(world: Vector3) -> Vector2:
	return camera_rig().unproject_position(world)


func _press(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	viewport.push_input(event)


func _release(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = pos
	viewport.push_input(event)


func _motion(pos: Vector2, relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(event)


func _hover(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	viewport.push_input(event)


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	get_tree().root.push_input(event)


func _cell_colors(source: VoxelFrame) -> Dictionary:
	var colors := {}
	for cell in source.positions():
		colors[cell] = source.get_color(cell)
	return colors


func _await_tool_idle() -> void:
	for _frame in 600:
		if tool._job == null and not State.edit_busy():
			await get_tree().process_frame
			return
		await get_tree().process_frame


func _await_edit_closed() -> void:
	for _frame in 600:
		if tool._edit == null and tool._job == null and not State.edit_busy():
			await get_tree().process_frame
			return
		await get_tree().process_frame


# --- Grab -------------------------------------------------------------------


func _grab_oblique() -> void:
	step("Given a voxel seen from an isometric view", func():
		_use(_settings.Tools.GRAB)
		_settings.size = 5
		_settings.falloff = 0.5
		_view("isometric")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(-1, 2):
			for z in range(-1, 2):
				frame.set_cell(anchor + Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3(anchor))
	)
	step("When the user presses and drags", func():
		_press(press)
		expect(tool._plane != null, "the grab press locks a plane")
		var forward := -camera_rig().basis.z
		expect(tool._plane.normal.is_equal_approx(forward.normalized()), "the plane normal is the true camera forward")
		var drag_pos := _pos(Vector3(anchor + Vector3i(3, 2, 1)))
		_motion(drag_pos, drag_pos - press)
		var delta: Vector3i = tool._drag - anchor
		expect(delta.x != 0 and delta.y != 0 and delta.z != 0, "the drag keeps all three world-axis components")
		_release(drag_pos)
	)
	step("Then the drag lands on the camera-facing plane", func():
		expect(State.edit_busy() == false, "the release ends the drag")
	)


func _grab_stretch() -> void:
	step("Given a line of voxels with two colors", func():
		_use(_settings.Tools.GRAB)
		_settings.size = 9
		_settings.falloff = 0.5
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(0, 5):
			var color := Color.RED if x == 0 else Color.BLUE
			frame.set_cell(anchor + Vector3i(x, 0, 0), VoxelFrame.material(color))
		frame.set_cell(anchor + Vector3i(10, 0, 0), VoxelFrame.material(Color.GREEN))
		sync_viewport()
		press = _pos(Vector3(anchor))
	)
	step("When the user presses and drags three cells", func():
		_press(press)
		expect(not tool._sources.is_empty(), "the press captures the source voxels")
		expect(tool._sources.size() == 5, "the source region holds the five voxels")
		var drag_pos := _pos(Vector3(anchor + Vector3i(3, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	step("Then the center stretches full and the edge moves less", func():
		expect(frame.get_color(anchor + Vector3i(3, 0, 0)) == Color.RED, "the center moves full and keeps its material")
		expect(not frame.has(anchor), "the center leaves its old cell")
		expect(frame.has(anchor + Vector3i(6, 0, 0)), "the far source moves a shorter distance")
		expect(not frame.has(anchor + Vector3i(7, 0, 0)), "the far source does not move the full distance")
	)
	step("Then the unrelated geometry stays", func():
		expect(frame.get_color(anchor + Vector3i(10, 0, 0)) == Color.GREEN, "the distant voxel keeps its material")
	)


func _grab_selection_destination() -> void:
	step("Given a line of voxels with a selection over the first two", func():
		_use(_settings.Tools.GRAB)
		_settings.size = 3
		_settings.falloff = 0.0
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(0, 5):
			frame.set_cell(anchor + Vector3i(x, 0, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		State.selection.clear()
		State.selection.add(anchor)
		State.selection.add(anchor + Vector3i(1, 0, 0))
		State.selection_changed.emit()
		press = _pos(Vector3(anchor))
	)
	step("When the user drags the selected voxels far outside the selection", func():
		_press(press)
		var drag_pos := _pos(Vector3(anchor + Vector3i(8, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	await _await_edit_closed()
	step("Then the selected voxels move and the selection follows them", func():
		expect(frame.has(anchor + Vector3i(8, 0, 0)), "the first source lands outside the selection")
		expect(frame.has(anchor + Vector3i(9, 0, 0)), "the second source lands outside the selection")
		expect(not frame.has(anchor), "the first source leaves its cell")
		expect(frame.get_color(anchor + Vector3i(9, 0, 0)) == Color.WHITE, "the second source keeps its material")
		expect(State.selection.contains(anchor + Vector3i(8, 0, 0)), "the selection follows the moved cells")
		expect(not State.selection.contains(anchor), "a cell that the drag emptied leaves the selection")
	)

func _grab_stops_at_document_edge() -> void:
	step("Given a line of voxels with a four-cell X size", func():
		_use(_settings.Tools.GRAB)
		_settings.size = 9
		_settings.falloff = 0.0
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(0, 5):
			frame.set_cell(anchor + Vector3i(x, 0, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		State.set_size(Vector3i(4, 0, 0))
		press = _pos(Vector3(anchor))
		expect(State.document.axis_cell_range(0) == Vector2i(-2, 2), "the X size covers cells minus two through one")
	)
	step("When the user presses and drags outside the size", func():
		_press(press)
		expect(not tool._sources.is_empty(), "the press captures the inside source voxels")
		expect(tool._sources.size() == 2, "only the two inside voxels join the drag")
		var drag_pos := _pos(Vector3(anchor + Vector3i(3, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	step("Then no voxel moves outside the size", func():
		expect(frame.count() == 5, "the outside destinations are refused")
		expect(frame.has(anchor), "the first source stays in place")
		expect(frame.has(anchor + Vector3i(1, 0, 0)), "the second source stays in place")
	)


func _grab_empty() -> void:
	step("Given the Grab tool on an empty floor", func():
		_use(_settings.Tools.GRAB)
		_view("top")
		press = _pos(Vector3.ZERO)
	)
	step("When the user presses and drags", func():
		_press(press)
		_motion(press + Vector2(20.0, 0.0), Vector2(20.0, 0.0))
		_release(press)
	)
	step("Then nothing changes and no history is recorded", func():
		expect(frame.count() == 0, "the empty grab changes nothing")
		expect(not State.undo_redo.has_undo(), "the empty grab adds no history")
	)


func _grab_worker() -> void:
	step("Given a wide plate with the Grab tool", func():
		_use(_settings.Tools.GRAB)
		_settings.size = 25
		_settings.falloff = 0.5
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(-12, 13):
			for z in range(-12, 13):
				var color := Color.RED if (x == 0 and z == 0) else Color.BLUE
				frame.set_cell(anchor + Vector3i(x, 0, z), VoxelFrame.material(color))
		sync_viewport()
		press = _pos(Vector3(anchor))
	)
	step("When the user drags far", func():
		_press(press)
		expect(not tool._sources.is_empty(), "the press captures the wide source region")
		var drag_pos := _pos(Vector3(anchor + Vector3i(30, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		expect(tool._job != null, "the large drag runs on the worker pool")
		expect(State.edit_busy(), "the worker drag owns a foreground operation")
	)
	await _await_tool_idle()
	step("Then the worker publishes the drag once", func():
		expect(frame.get_color(anchor + Vector3i(30, 0, 0)) == Color.RED, "the worker moves the center and keeps its material")
		expect(not State.edit_busy(), "the worker releases its operation")
		_release(press)
	)
	step("Then the whole drag is one history action", func():
		expect(State.undo_redo.has_undo(), "the worker drag records one action")
		State.undo_redo.undo()
		expect(not frame.has(anchor + Vector3i(30, 0, 0)), "one undo clears the worker drag")
	)


func _grab_shared_radius() -> void:
	step("Given a wide plate with the Grab tool and a large shared size", func():
		_use(_settings.Tools.GRAB)
		_settings.size = 50
		_settings.falloff = 0.5
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(-20, 21):
			for z in range(-20, 21):
				var color := Color.RED if (x == 0 and z == 0) else Color.BLUE
				frame.set_cell(anchor + Vector3i(x, 0, z), VoxelFrame.material(color))
		sync_viewport()
		press = _pos(Vector3(anchor))
	)
	step("When the user presses, the capture uses the shared size", func():
		_press(press)
		expect(not tool._sources.is_empty(), "the press captures the wide source region")
		expect(tool._sources.size() > 785, "the capture uses the shared size, not the old small cap")
	)
	step("When the user drags far", func():
		var drag_pos := _pos(Vector3(anchor + Vector3i(10, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		expect(tool._job != null, "the large drag runs on the worker pool")
	)
	await _await_tool_idle()
	step("Then the center moves by the full delta", func():
		expect(frame.get_color(anchor + Vector3i(10, 0, 0)) == Color.RED, "the center moves the full drag and keeps its material")
	)
	step("Then a weighted source reaches its partial destination", func():
		expect(frame.get_color(anchor + Vector3i(21, 0, 0)) == Color.BLUE, "the weighted source reaches its partial destination and keeps its material")
	)
	step("Then the user releases", func():
		_release(press)
	)
	step("Then the whole drag is one history action", func():
		expect(State.undo_redo.has_undo(), "the shared-size drag records one action")
		State.undo_redo.undo()
		expect(frame.get_color(anchor) == Color.RED, "one undo restores the center to its origin")
		expect(frame.get_color(anchor + Vector3i(10, 0, 0)) == Color.BLUE, "one undo restores the moved position to the plate")
	)


func _grab_pending_return() -> void:
	step("Given a wide plate and a far worker drag", func():
		_use(_settings.Tools.GRAB)
		_settings.size = 25
		_settings.falloff = 0.5
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(-12, 13):
			for z in range(-12, 13):
				frame.set_cell(anchor + Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3(anchor))
		_press(press)
		var drag_pos := _pos(Vector3(anchor + Vector3i(30, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		expect(tool._job != null, "the large drag runs on the worker pool")
	)
	step("When the user returns to the origin and releases", func():
		var origin_pos := _pos(Vector3(anchor))
		_motion(origin_pos, origin_pos - press)
		_release(origin_pos)
		expect(tool._pending_target != null, "the return is queued while the worker runs")
	)
	await _await_edit_closed()
	step("Then the model returns to the baseline and the edit closes", func():
		expect(tool._edit == null, "the queued return closes the edit")
		expect(not State.edit_busy(), "no operation remains")
		expect(frame.count() == 625, "the plate is back to its original cell count")
		expect(not State.undo_redo.has_undo(), "the net-zero drag adds no history")
	)


func _deform_return_selection() -> void:
	# A drag that comes back to its origin republishes the baseline. The selection
	# must return with it, or the next stroke searches cells that no longer exist.
	step("Given a bar with a selection over its first two cells", func():
		_use(_settings.Tools.GRAB)
		_settings.size = 3
		_settings.falloff = 0.0
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(0, 5):
			frame.set_cell(anchor + Vector3i(x, 0, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		State.selection.clear()
		State.selection.add(anchor)
		State.selection.add(anchor + Vector3i(1, 0, 0))
		State.selection_changed.emit()
		press = _pos(Vector3(anchor))
	)
	step("When the user drags four cells out and back", func():
		_press(press)
		var out := _pos(Vector3(anchor + Vector3i(4, 0, 0)))
		_motion(out, out - press)
		_motion(press, press - out)
		_release(press)
	)
	await _await_edit_closed()
	step("Then the model and the selection are back at the press state", func():
		expect(frame.has(anchor), "the source returns to its cell")
		expect(frame.has(anchor + Vector3i(1, 0, 0)), "the second source returns to its cell")
		expect(State.selection.contains(anchor), "the first source stays selected")
		expect(State.selection.contains(anchor + Vector3i(1, 0, 0)), "the second source stays selected")
		expect(State.selection.count() == 2, "no destination stays selected")
		for cell in State.selection.to_array():
			expect(frame.has(cell), "the selection holds only cells that exist")
		expect(not State.undo_redo.has_undo(), "the returned drag adds no history")
	)


func _cancel_worker_click() -> void:
	# A release that arrives while an older, cancelled job still runs must settle
	# the new stroke when that job retires. Otherwise the edit stays open and the
	# next press is swallowed until the pointer moves.
	step("Given a wide plate and a running worker grab", func():
		_use(_settings.Tools.GRAB)
		_settings.size = 25
		_settings.falloff = 0.5
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(-12, 13):
			for z in range(-12, 13):
				frame.set_cell(anchor + Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3(anchor))
		_press(press)
		var drag_pos := _pos(Vector3(anchor + Vector3i(30, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		expect(tool._job != null, "the drag runs on the worker pool")
		_key(KEY_ESCAPE)
		expect(tool._edit == null, "Escape cancels the stroke")
	)
	step("When the user clicks again without a drag", func():
		_press(press)
		expect(tool._edit != null, "the new press opens an edit")
		_release(press)
	)
	await _await_edit_closed()
	step("Then the click closes its edit", func():
		expect(tool._edit == null, "the click closes the edit")
		expect(not State.edit_busy(), "no operation remains")
		expect(frame.count() == 625, "the click changes no cell")
	)


func _cancel_repress() -> void:
	step("Given a wide plate and a worker grab", func():
		_use(_settings.Tools.GRAB)
		_settings.size = 25
		_settings.falloff = 0.5
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(-12, 13):
			for z in range(-12, 13):
				var color := Color.RED if (x == 0 and z == 0) else Color.BLUE
				frame.set_cell(anchor + Vector3i(x, 0, z), VoxelFrame.material(color))
		sync_viewport()
		press = _pos(Vector3(anchor))
		_press(press)
		var drag_pos := _pos(Vector3(anchor + Vector3i(30, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		expect(tool._job != null, "the large drag runs on the worker pool")
	)
	step("When the user cancels and presses again", func():
		_key(KEY_ESCAPE)
		expect(tool._edit == null, "Escape cancels the stroke")
		_press(press)
		expect(tool._edit != null, "the new press opens a new edit")
		var small := _pos(Vector3(anchor + Vector3i(2, 0, 0)))
		_motion(small, small - press)
		_release(small)
	)
	await _await_edit_closed()
	step("Then the cancelled job cannot touch the new stroke", func():
		expect(tool._edit == null, "the new stroke closes after its release")
		expect(not State.edit_busy(), "no operation remains")
		expect(frame.get_color(anchor + Vector3i(2, 0, 0)) == Color.RED, "the new drag applied")
	)


func _deform_controls() -> void:
	step("Given the deform options and menu", func():
		var options: Control = plugin("DeformPlugin")._options
		var toolbar: MenuButton = plugin("DeformPlugin")._toolbar
		_settings.size = 72
		expect(_settings.size == 32, "the deform size keeps the shared bound")
		expect(options.get_node("Size").max_value == 32.0, "the size control keeps the shared bound")
		expect(options.get_node_or_null("Strength") == null, "neither deform tool shows a strength control")
		expect(options.get_node_or_null("UseSelection") == null, "the pose row holds no selection control")
		var popup := toolbar.get_popup()
		expect(popup.item_count == 2, "the deform menu holds two tools")
		expect(
			popup.get_item_text(0) == "Grab" and popup.get_item_text(1) == "Pose",
			"the menu order is Grab, Pose"
		)
		expect(popup.get_item_id(1) == 1, "the Pose item keeps its fixed id")
	)
	step("When the user selects Pose", func():
		var toolbar: MenuButton = plugin("DeformPlugin")._toolbar
		toolbar.get_popup().index_pressed.emit(1)
		expect(_settings.tool == _settings.Tools.POSE, "the second entry selects Pose")
		expect(plugin("DeformPlugin")._current_tool.name == "PoseTool", "the pose tool node is the active tool")
		expect(plugin("DeformPlugin")._current_tool.get_node_or_null("Bone") != null, "the pose tool has a bone cursor")
	)
	step("When the user selects Grab", func():
		var toolbar: MenuButton = plugin("DeformPlugin")._toolbar
		toolbar.get_popup().index_pressed.emit(0)
		expect(_settings.tool == _settings.Tools.GRAB, "the first entry selects Grab")
		expect(plugin("DeformPlugin")._current_tool.name == "GrabTool", "the grab tool node is the active tool")
	)


# --- Pose -------------------------------------------------------------------


# Builds a bar along X. The front view shows the whole bar, so the local limb
# axis is X and the bone lies in the view plane.
func _bar(from_x: int, to_x: int) -> void:
	for x in range(from_x, to_x + 1):
		frame.set_cell(Vector3i(x, 0, 0), VoxelFrame.material(Color.WHITE))
	sync_viewport()


func _pose_limb() -> void:
	step("Given a bar seen from the front and the Pose tool", func():
		_use(_settings.Tools.POSE)
		_settings.size = 4
		_settings.falloff = 0.0
		_view("front")
		_bar(-8, 8)
		press = _pos(Vector3(0.0, 0.0, 0.0))
		anchor = aim(press).target
		expect(anchor == Vector3i(0, 0, 0), "the front view picks the cell under the pointer")
	)
	step("When the user presses the bar", func():
		_press(press)
		expect(tool._edit != null, "the pose press opens an edit")
		expect(tool._joint_found, "the pose finds the joint")
		expect(tool._bone_dir.is_equal_approx(Vector3.LEFT), "the bone runs from the joint to the picked cell")
		expect(tool._pivot.distance_to(Vector3(0, 0, 0)) <= 2.5, "the joint sits within the brush radius")
		expect(tool._pivot.distance_to(Vector3(0, 0, 0)) >= 1.0, "the joint keeps a lever")
		expect(not tool._limb.is_empty(), "the pose captures the limb")
	)
	step("When the user drags the tip upward", func():
		var drag_pos := press + Vector2(0.0, -300.0)
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	await _await_edit_closed()
	step("Then the limb turns in the view plane", func():
		expect(frame.has(Vector3i(4, 0, 0)), "the limb beyond the joint stays in place")
		expect(frame.has(Vector3i(8, 0, 0)), "the far end stays in place")
		expect(not frame.has(Vector3i(0, 0, 0)), "the picked cell leaves the row")
		var raised := 0
		var off_plane := 0
		for cell in frame.positions():
			if cell.y > 0:
				raised += 1
			if cell.z != 0:
				off_plane += 1
		expect(raised > 0, "the bent limb leaves the original row")
		expect(off_plane == 0, "the bend stays in the view plane")
	)
	step("Then the pose is one history action", func():
		expect(State.undo_redo.has_undo(), "the pose records one action")
	)


func _pose_hover_pivot() -> void:
	step("Given a bar and the Pose tool, with no press", func():
		_use(_settings.Tools.POSE)
		_settings.size = 4
		_settings.falloff = 0.0
		_view("front")
		_bar(-8, 8)
		_hover(_pos(Vector3(6.0, 0.0, 0.0)))
	)
	await get_tree().process_frame
	step("Then the hover shows the rotation point", func():
		var bone := tool.get_node("Bone") as MeshInstance3D
		expect(bone.is_visible_in_tree(), "the bone is visible before a press")
		expect(tool._edit == null, "a hover opens no edit")
		var origin := bone.global_transform.origin
		var vertices: PackedVector3Array = (bone.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		expect(vertices.size() >= 2, "the bone has at least one segment")
		expect(vertices[1].is_equal_approx(Vector3(6, 0, 0)), "the bone ends at the picked cell")
		expect(origin.is_equal_approx(Vector3.ZERO), "the bone vertices are in world space")
		var joint: Vector3 = tool._hover_joint["pivot"]
		expect(Vector3(joint).distance_to(Vector3(6, 0, 0)) <= 4.5, "the joint sits within the brush radius")
		expect(frame.has(Vector3i(joint)), "the joint is an occupied cell")
		expect(vertices[0].is_equal_approx(Vector3(joint)), "the bone starts at the joint")
		pose_before = {"x": Vector3(joint).x}
	)
	step("When the pointer moves to another cell", func():
		_hover(_pos(Vector3(1.0, 0.0, 0.0)))
	)
	await get_tree().process_frame
	step("Then the joint follows the pointer", func():
		var bone := tool.get_node("Bone") as MeshInstance3D
		var vertices: PackedVector3Array = (bone.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var joint: Vector3 = tool._hover_joint["pivot"]
		expect(vertices[1].is_equal_approx(Vector3(1, 0, 0)), "the bone ends at the new cell")
		expect(Vector3(joint).distance_to(Vector3(1, 0, 0)) <= 4.5, "the joint stays within the brush radius")
		expect(frame.has(Vector3i(joint)), "the joint is an occupied cell")
		expect(not is_equal_approx(float(pose_before["x"]), Vector3(joint).x), "the joint moves with the picked cell")
	)


func _pose_solid() -> void:
	step("Given a thicker bar and the Pose tool", func():
		_use(_settings.Tools.POSE)
		_settings.size = 4
		_settings.falloff = 0.5
		_view("front")
		for x in range(-8, 9):
			for y in range(0, 3):
				frame.set_cell(Vector3i(x, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3(0.0, 1.0, 0.0))
	)
	step("When the user presses and bends the bar", func():
		pose_count = frame.count()
		_press(press)
		expect(tool._joint_found, "the pose finds the joint")
		# The bar is symmetric around the pick, so either end can be the base.
		expect(absf(tool._bone_dir.dot(Vector3.RIGHT)) > 0.99, "the bone runs along the bar")
		var drag_pos := press + Vector2(0.0, -260.0)
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	await _await_edit_closed()
	step("Then the bent limb keeps its cells", func():
		expect(frame.count() >= pose_count - 4, "the bend leaves no hole in the limb")
		var moved := 0
		for cell in frame.positions():
			if cell.y > 2:
				moved += 1
		expect(moved > 0, "the bent part of the bar leaves the original block")
	)


func _pose_end_on() -> void:
	step("Given a bar seen along its own axis and the Pose tool", func():
		_use(_settings.Tools.POSE)
		_settings.size = 4
		_settings.falloff = 0.0
		_view("right")
		for x in range(-8, 9):
			frame.set_cell(Vector3i(x, 0, 0), VoxelFrame.material(Color.WHITE))
		# One off-axis cell next to the base makes a twist visible when the bone
		# points at the viewer.
		frame.set_cell(Vector3i(7, 0, 1), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		expect(anchor == Vector3i(8, 0, 0), "the end view picks the end cell")
	)
	step("When the user drags upward", func():
		_press(press)
		expect(tool._joint_found, "the pose finds the joint")
		var drag_pos := press + Vector2(0.0, -260.0)
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	await _await_edit_closed()
	step("Then the plane keeps the base near the press", func():
		expect(not frame.has(Vector3i(8, 0, 0)), "the end cell leaves its place")
		expect(frame.has(Vector3i(-8, 0, 0)), "the far end stays in place")
	)


func _pose_symmetry() -> void:
	step("Given a symmetric bar and the X symmetry plane", func():
		_use(_settings.Tools.POSE)
		_settings.size = 4
		_settings.falloff = 0.5
		_view("front")
		_bar(-9, 8)
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3(-0.5, -0.5, -0.5)
		press = _pos(Vector3(6.0, 0.0, 0.0))
		anchor = aim(press).target
	)
	step("When the user bends one end", func():
		_press(press)
		expect(tool._poses.size() == 2, "one pose entry per active mask")
		var drag_pos := press + Vector2(0.0, -240.0)
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	await _await_edit_closed()
	step("Then the other end mirrors the bend", func():
		var mirrored := true
		var moved := 0
		for cell in frame.positions():
			if cell.y == 0:
				continue
			moved += 1
			mirrored = mirrored and frame.has(Vector3i(-1 - cell.x, cell.y, cell.z))
		expect(moved > 0, "the bend leaves the original row")
		expect(mirrored, "every bent cell has its reflected counterpart")
	)


func _pose_document_edge() -> void:
	step("Given a bar in a document that limits Y", func():
		_use(_settings.Tools.POSE)
		_settings.size = 4
		_settings.falloff = 0.0
		_view("front")
		_bar(-8, 8)
		State.set_size(Vector3i(0, 6, 0))
		sync_viewport()
		press = _pos(Vector3(0.0, 0.0, 0.0))
		anchor = aim(press).target
	)
	step("When the user bends the tip up", func():
		_press(press)
		expect(tool._joint_found, "the pose finds the joint")
		var drag_pos := press + Vector2(0.0, -280.0)
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	await _await_edit_closed()
	step("Then no cell lands outside the size", func():
		var outside := 0
		var range_y := State.document.axis_cell_range(1)
		for cell in frame.positions():
			if cell.y < range_y.x or cell.y > range_y.y:
				outside += 1
		expect(outside == 0, "every posed cell stays inside the document size")
		expect(frame.has(Vector3i(8, 0, 0)), "the far end stays in place")
	)


func _pose_history() -> void:
	step("Given a bar and the Pose tool", func():
		_use(_settings.Tools.POSE)
		_settings.size = 4
		_settings.falloff = 0.0
		_view("front")
		_bar(-8, 8)
		press = _pos(Vector3(6.0, 0.0, 0.0))
		anchor = aim(press).target
		pose_before = _cell_colors(frame)
		expect(pose_before.size() == 17, "the bar holds seventeen cells")
	)
	step("When the user bends the bar and releases", func():
		_press(press)
		var drag_pos := press + Vector2(0.0, -280.0)
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	await _await_edit_closed()
	step("Then one undo restores the bar and one redo bends it again", func():
		pose_bent = _cell_colors(frame)
		expect(pose_bent != pose_before, "the pose changes the bar")
		State.undo_redo.undo()
		expect(_cell_colors(frame) == pose_before, "one undo restores the bar")
		State.undo_redo.redo()
		expect(_cell_colors(frame) == pose_bent, "one redo bends the bar again")
	)
	step("When the user bends the bar and presses Escape", func():
		State.undo_redo.undo()
		State.undo_redo.clear_history()
		_press(press)
		var drag_pos := press + Vector2(0.0, -280.0)
		_motion(drag_pos, drag_pos - press)
		_key(KEY_ESCAPE)
	)
	step("Then the pose rolls back and records no history", func():
		expect(tool._edit == null, "Escape cancels the pose")
		expect(_cell_colors(frame) == pose_before, "the cancelled pose restores the bar")
		expect(not State.undo_redo.has_undo(), "the cancelled pose adds no history")
	)


func _pose_depth_bias() -> void:
	# Two occupied cells tie at the same depth. The one behind the view plane of
	# the press must lose, so a screen-plane bend does not pick a cell that sits
	# in front of or behind the pointer.
	step("Given a pick with one candidate on the view plane and one behind it", func():
		_use(_settings.Tools.POSE)
		_settings.size = 4
		_settings.falloff = 0.0
		_view("right")
		frame.set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(-2, 0, 0), VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(0, 0, 2), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3(0.0, 0.0, 0.0))
	)
	step("When the user presses the pick", func():
		_press(press)
		expect(tool._joint_found, "the pose finds the joint")
		expect(Vector3i(tool._pivot) == Vector3i(0, 0, 2), "the base prefers the cell on the view plane")
		_release(press)
	)


func _pose_face_bias() -> void:
	# The base leans toward the half of the face under the pointer, and the cursor
	# draws a cross at that point so the bias is visible.
	step("Given a bar with one candidate on each side of the pick", func():
		_use(_settings.Tools.POSE)
		_settings.size = 4
		_settings.falloff = 0.0
		_view("front")
		_bar(-2, 2)
		_hover(_pos(Vector3(0.3, 0.0, 0.5)))
	)
	await get_tree().process_frame
	step("Then the base leans to the right half of the face", func():
		expect(Vector3i(tool._hover_joint["pivot"]) == Vector3i(2, 0, 0), "the right half picks the right cell")
		var bone := tool.get_node("Bone") as MeshInstance3D
		var vertices: PackedVector3Array = (bone.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var count := vertices.size()
		var center := (vertices[count - 4] + vertices[count - 3]) / 2.0
		expect(absf(absf(center.z) - 0.52) <= 0.01, "the face widget sits on the entered face")
		expect(absf(center.x) <= 0.01 and absf(center.y) <= 0.01, "the face widget crosses at the face center")
	)
	step("When the pointer moves to the left half", func():
		_hover(_pos(Vector3(-0.3, 0.0, 0.5)))
	)
	await get_tree().process_frame
	step("Then the base leans to the left half", func():
		expect(Vector3i(tool._hover_joint["pivot"]) == Vector3i(-2, 0, 0), "the left half picks the left cell")
	)


func _pose_large_blob() -> void:
	step("Given a solid block and the Pose tool", func():
		_use(_settings.Tools.POSE)
		_settings.size = 3
		_settings.falloff = 0.5
		_view("top")
		for x in range(-12, 13):
			for y in range(-12, 13):
				for z in range(-4, 1):
					frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3(0.0, 0.0, 0.0))
	)
	step("When the user presses the top of the block", func():
		pose_count = frame.count()
		_press(press)
		expect(tool._joint_found, "the pose still finds a joint")
		expect(tool._limb.size() <= 224, "a large blob bends a bounded set")
	)
	step("Then a small drag moves only the footprint", func():
		var drag_pos := press + Vector2(30.0, 0.0)
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	await _await_edit_closed()
	step("Then the block keeps its cells", func():
		expect(frame.count() >= pose_count - 8, "the footprint bend keeps the block solid")
		expect(not State.edit_busy(), "the pose releases the edit")
	)


func _pose_cursor_circle() -> void:
	# The circle shows the joint reach, not the flat footprint. A base outside
	# the brush is then still inside the circle.
	step("Given a bar and a hover with the Pose tool", func():
		_use(_settings.Tools.POSE)
		_settings.size = 4
		_settings.falloff = 0.0
		_view("front")
		_bar(-8, 8)
		_hover(_pos(Vector3(6.0, 0.0, 0.0)))
	)
	await get_tree().process_frame
	step("Then the circle spans the joint reach and centers on the picked cell", func():
		var circle := tool.get_node("Footprint") as MeshInstance3D
		expect(circle.is_visible_in_tree(), "the cursor is visible")
		var vertices: PackedVector3Array = (circle.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		expect(vertices.size() > 0, "the circle holds segments")
		var extent := 0.0
		for vertex in vertices:
			extent = maxf(extent, maxf(absf(vertex.x), absf(vertex.y)))
		expect(is_equal_approx(extent, 2.0), "the circle spans the brush footprint from the picked cell")
		var center := circle.global_transform.origin
		expect(center.is_equal_approx(Vector3(6, 0, 0)), "the circle centers on the picked cell")
		var joint: Vector3 = tool._hover_joint["pivot"]
		expect(Vector3(joint).distance_to(center) <= 4.0, "the joint sits inside the circle")
		expect(frame.has(Vector3i(joint)), "the joint is an occupied cell")
	)


func _pose_selection() -> void:
	step("Given a bar with a selection over its tip", func():
		_use(_settings.Tools.POSE)
		_settings.size = 4
		_settings.falloff = 0.0
		_view("front")
		_bar(-8, 8)
		State.selection.clear()
		for x in range(2, 9):
			State.selection.add(Vector3i(x, 0, 0))
		State.selection_changed.emit()
		press = _pos(Vector3(6.0, 0.0, 0.0))
	)
	step("When the user drags the tip upward", func():
		_press(press)
		expect(not tool._limb.is_empty(), "the press finds a limb through the selection")
		for cell in tool._limb:
			expect(Vector3i(cell).x >= 2, "only a selected cell joins the move")
		var drag_pos := press + Vector2(0.0, -300.0)
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	await _await_edit_closed()
	step("Then the selection limits the bend and follows it", func():
		expect(not frame.has(Vector3i(6, 0, 0)), "the selected tip leaves its cell")
		expect(frame.has(Vector3i(-8, 0, 0)), "an unselected cell stays")
		expect(State.selection.count() > 0, "the moved cells stay selected")
		expect(not State.selection.contains(Vector3i(6, 0, 0)), "a cell that the turn emptied leaves the selection")
		expect(not State.selection.contains(Vector3i(-8, 0, 0)), "an unselected cell stays out of the selection")
		var raised := 0
		for cell in State.selection.to_array():
			if cell.y > 0:
				raised += 1
		expect(raised > 0, "the selection follows the raised cells")
	)

func _pose_stable() -> void:
	# The wall above the bar stops a full bend, so the angle fit decides the
	# result. A fit that reads the published preview then changes on every second
	# motion, and the bend flashes between two angles.
	step("Given a bar with a wall above it and the Pose tool", func():
		_use(_settings.Tools.POSE)
		_settings.size = 4
		_settings.falloff = 0.0
		_view("front")
		_bar(-8, 8)
		for x in range(3, 7):
			frame.set_cell(Vector3i(x, 2, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3(0.0, 0.0, 0.0))
	)
	step("When the user reaches one point in a single motion", func():
		_press(press)
		var drag_pos := press + Vector2(0.0, -330.0)
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	await _await_edit_closed()
	step("When the user reaches the same point in two motions", func():
		pose_bent = _cell_colors(frame)
		State.undo_redo.undo()
		State.undo_redo.clear_history()
		_press(press)
		var first := press + Vector2(0.0, -40.0)
		_motion(first, first - press)
		var second := press + Vector2(0.0, -330.0)
		_motion(second, second - first)
		_release(second)
	)
	await _await_edit_closed()
	step("Then the pointer path changes nothing", func():
		expect(not pose_bent.is_empty(), "the single motion bends the bar")
		expect(_cell_colors(frame) == pose_bent, "a second motion does not flash the bend")
		expect(frame.has(Vector3i(8, 0, 0)), "the far end stays in place")
	)

func _pose_pointer_angle() -> void:
	step("Given a bar and the Pose tool", func():
		_use(_settings.Tools.POSE)
		_settings.size = 4
		_settings.falloff = 0.0
		_view("front")
		_bar(-8, 8)
		press = _pos(Vector3(0.0, 0.0, 0.0))
	)
	step("When the user drags the pointer to one cell beside the joint", func():
		_press(press)
		var drag_pos := _pos(Vector3(2.0, 2.0, 0.0))
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	await _await_edit_closed()
	step("Then the tip lands under the pointer", func():
		expect(frame.has(Vector3i(2, 2, 0)), "the tip cell sits at the pointer")
		expect(not frame.has(Vector3i(0, 0, 0)), "the tip leaves its old cell")
		expect(frame.has(Vector3i(8, 0, 0)), "the far end stays in place")
	)

func _pose_no_smear() -> void:
	# A large brush puts the joint far behind the pick, so the turned limb sweeps a
	# wide box. A fill along each source line would smear the limb across that box
	# and add cells, which a rigid turn never does.
	step("Given a thin bar and a brush wider than the bar", func():
		_use(_settings.Tools.POSE)
		_settings.size = 10
		_settings.falloff = 0.0
		_view("front")
		_bar(-8, 8)
		pose_count = frame.count()
		expect(pose_count == 17, "the bar holds seventeen cells")
		press = _pos(Vector3(6.0, 0.0, 0.0))
	)
	step("When the user turns the tip a quarter turn", func():
		_press(press)
		var drag_pos := _pos(Vector3(1.0, 7.0, 0.0))
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	await _await_edit_closed()
	step("Then the turn adds no cell", func():
		expect(frame.count() <= pose_count + 2, "the turn adds no fan between two cells (now %d, was %d)" % [frame.count(), pose_count])
		expect(frame.has(Vector3i(-8, 0, 0)), "the far end stays in place")
		expect(not frame.has(Vector3i(8, 0, 0)), "the tip leaves its old cell")
	)


func _pose_search_bound() -> void:
	# A long limb must not send the joint search across the model. The press sits
	# one brush size from the tip, so the walk sees the tip end within its reach
	# and keeps the joint on the body side.
	step("Given a long bar and the Pose tool", func():
		_use(_settings.Tools.POSE)
		_settings.size = 4
		_settings.falloff = 0.0
		_view("front")
		_bar(0, 40)
		press = _pos(Vector3(2.0, 0.0, 0.0))
	)
	step("When the user presses two cells from the tip", func():
		_press(press)
		expect(tool._joint_found, "the pose finds the joint")
		expect(tool._pivot.distance_to(Vector3(2, 0, 0)) <= 4.5, "the joint stays within the brush radius")
		var drag_pos := press + Vector2(0.0, -300.0)
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	await _await_edit_closed()
	step("Then only the tip side turns", func():
		expect(not frame.has(Vector3i(2, 0, 0)), "the tip leaves its old cell")
		expect(frame.has(Vector3i(10, 0, 0)), "the rest of the limb stays in place")
		expect(frame.has(Vector3i(40, 0, 0)), "the far end stays in place")
	)
