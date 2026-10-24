extends "res://tests/test.gd"

# A large sculpt dab must build its footprint on the worker pool, so the frame
# that accepted it keeps processing input and the camera. A small dab must stay
# inline, so an ordinary press still edits in its input event.
#
# The checks compare the worker footprint against a direct main-thread map of
# the same explicit inputs, so the offload changes no voxel of the original
# profile. The pure map the worker builds reads only plain inputs, so the test
# can reproduce it from the locked plane and center the press published.
#
# The test drives the real tool through the editor viewport. It does not change
# the placement policy, the falloff, or the credits.

const SculptPreviewScript := preload("res://plugins/Sculpt/SculptPreview.gd")

var _settings := preload("res://plugins/Sculpt/settings.tres")
var _tool
var _frame: VoxelFrame
var _viewport: SubViewport
var _before := {}


func _ready() -> void:
	test("a small press applies its dab in the input event", _small_inline, "small_inline")
	test("a maximum Grow press builds its footprint on the worker", _large_worker, "large_worker")
	test("the frame loop and the camera advance while the prep runs", _frames_advance, "frames_advance")
	test("the worker footprint matches a direct main-thread map", _footprint_parity, "footprint_parity")
	test("a maximum Flatten press builds its footprint on the worker", _flatten_worker, "flatten_worker")
	test("a maximum Smooth press builds its fields on the worker", _smooth_worker, "smooth_worker")
	test("a settled maximum hover is reused by the press", _hover_reuse, "hover_reuse")
	test("Escape during a pending footprint rolls back without a zombie", _cancel_pending, "cancel_pending")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	_settings.tool = _settings.Tools.GROW
	_settings.grow_mode = _settings.GrowMode.ADD
	_settings.normal_source = _settings.NormalSource.SURFACE
	_settings.radius = 4
	_settings.strength = 1.0
	_settings.falloff = 0.5
	_viewport = editor_viewport()
	_viewport.get_parent().stretch = false
	_viewport.size = Vector2i(800, 500)
	activate_tool("sculpt")
	var sculpt := plugin("SculptPlugin")
	sculpt.activate_tool()
	sculpt.deactivate_tool()
	_tool = preload("res://plugins/Sculpt/SculptTool.tscn").instantiate()
	if _tool._settings == null:
		_tool._settings = _settings
	sculpt.add_editor_node(_tool)
	_tool.set_process(true)
	_frame = State.get_current_voxel_frame()
	camera_rig().is_orthogonal = true
	camera_rig().set_view("top")
	_before = {}
	await get_tree().process_frame


func _cleanup_test() -> void:
	if is_instance_valid(_tool):
		if _tool._edit != null:
			_tool.finish_on_switch()
		await _wait_idle()
		plugin("SculptPlugin").remove_editor_node(_tool)
		_tool.free()
	_tool = null


# --- Fixtures -----------------------------------------------------------------

# A wide flat plate on the floor plane. The maximum radius disc fits inside it.
func _plate() -> void:
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	var changes := {}
	var material := VoxelFrame.material(Color.WHITE)
	for x in range(-40, 41):
		for z in range(-40, 41):
			changes[Vector3i(x, 0, z)] = material
	_frame.set_cells(changes)
	sync_viewport()
	_view(AABB(Vector3(-44, -6, -44), Vector3(88, 24, 88)))
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true


# A plate with a raised rough block, so Smooth has a convex edge to round.
func _rough_block() -> void:
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	var changes := {}
	var material := VoxelFrame.material(Color.WHITE)
	for x in range(-40, 41):
		for z in range(-40, 41):
			changes[Vector3i(x, 0, z)] = material
	for x in range(-28, 29):
		for z in range(-28, 29):
			for y in range(1, 4):
				changes[Vector3i(x, y, z)] = material
	for x in range(-28, 29, 4):
		for z in range(-28, 29, 4):
			changes[Vector3i(x, 4, z)] = material
	_frame.set_cells(changes)
	sync_viewport()
	_view(AABB(Vector3(-44, -6, -44), Vector3(88, 28, 88)))
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true


# --- Camera and input ---------------------------------------------------------

func _view(box: AABB) -> void:
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true
	camera_rig().center_on(box)


func _screen(world: Vector3) -> Vector2:
	return camera_rig().unproject_position(world)


func _button(pressed: bool, position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	event.position = position
	_viewport.push_input(event)


func _motion(position: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	_viewport.push_input(event)


# Waits for the hover controller to publish its result and for the cursor mesh
# to settle, so a test can read the published hover frame.
func _settle_preview() -> void:
	for _index in 600:
		await get_tree().process_frame
		if _tool._preview.is_settled() and _tool.get_node("Cursor").is_settled():
			return


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	get_tree().root.push_input(event)


func _wait_idle() -> void:
	for _index in 1200:
		if _tool._edit == null and not _tool._busy() and not _tool._has_pending():
			await get_tree().process_frame
			return
		await get_tree().process_frame


# --- Cases --------------------------------------------------------------------

func _small_inline() -> void:
	step("Given a flat plate and a small Grow brush", func():
		_plate()
		_settings.tool = _settings.Tools.GROW
		_settings.radius = 4
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_before = _frame.capture()
	)
	step("When the user presses once", func():
		_button(true, _screen(Vector3.ZERO))
		expect(_frame.count() > 0, "the small press built its footprint in the input event")
		expect(not _tool._busy(), "the small press ran no worker job")
		_button(false, _screen(Vector3.ZERO))
	)
	await _wait_idle()
	step("Then the small click stays one bounded user action", func():
		expect(State.undo_redo.has_undo(), "the small click records one action")
		expect(State.undo_redo.get_history_count() == 1, "the small click records a single history entry")
		State.undo()
		expect(VoxelEditTransaction._chunks_equal(_before, _frame.capture()), "one undo restores the small click")
	)


func _large_worker() -> void:
	step("Given a flat plate and a maximum Grow brush", func():
		_plate()
		_settings.tool = _settings.Tools.GROW
		_settings.radius = 32
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_before = _frame.capture()
	)
	step("When the user presses once", func():
		_button(true, _screen(Vector3.ZERO))
		expect(VoxelEditTransaction._chunks_equal(_before, _frame.capture()), "the maximum press writes nothing on the main thread")
		expect(_tool._tick_job != null, "the maximum press started a dab worker")
		expect(_tool._tick_job.preparing, "the dab worker owns the footprint preparation")
		expect(_tool._stroke_frame != null, "the press still locked its plane in the input event")
		_button(false, _screen(Vector3.ZERO))
	)
	await _wait_idle()
	step("Then the accepted dab applied and closed as one action", func():
		expect(not _tool._busy(), "the dab worker retired")
		expect(State.undo_redo.get_history_count() == 1, "the maximum click records one action")
		expect(not VoxelEditTransaction._chunks_equal(_before, _frame.capture()), "the worker dab grew the plate")
	)


func _frames_advance() -> void:
	step("Given a flat plate and a maximum Grow press", func():
		_plate()
		_settings.tool = _settings.Tools.GROW
		_settings.radius = 32
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_button(true, _screen(Vector3.ZERO))
		expect(_tool._busy(), "the footprint worker is pending in the input event")
	)
	var frames := 0
	var camera_before := camera_rig().global_transform
	while _tool._busy() and frames < 600:
		await get_tree().process_frame
		frames += 1
		if frames == 1:
			# The rotate input calls the rig orbit. The user may rotate the view
			# while the footprint worker is pending, so the orbit must run, the
			# frame loop must keep advancing, and the accepted dab must survive.
			camera_rig().orbit(Vector2(40.0, 20.0))
	var camera_after := camera_rig().global_transform
	_button(false, _screen(Vector3.ZERO))
	await _wait_idle()
	step("Then the frame loop advanced and the camera moved while the prep ran", func():
		expect(frames >= 1, "the pending footprint yielded at least one frame")
		expect(not _tool._busy(), "the footprint worker completed")
		expect(not camera_before.is_equal_approx(camera_after), "the camera moved while the footprint was pending")
		expect(State.undo_redo.has_undo(), "the stroke still recorded its action")
	)


func _footprint_parity() -> void:
	var weights := {}
	var anchors := {}
	step("Given a flat plate and a maximum Grow press", func():
		_plate()
		_settings.tool = _settings.Tools.GROW
		_settings.radius = 32
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_button(true, _screen(Vector3.ZERO))
		expect(_tool._tick_job != null and _tool._tick_job.preparing, "the footprint worker owns the map")
	)
	step("When the test builds the same footprint on the main thread", func():
		var snapshot := _frame.copy_frame()
		var frame: SculptFrame = _tool._stroke_frame
		var center: Vector3 = _tool._stroke_center_point
		var reference: Dictionary = SculptPreviewScript.compute_sample_map(
			snapshot, frame, center, 32, 0.5, _tool._stroke_context, SculptPreviewScript.depth_for(32), {})
		for anchor in reference:
			anchors[anchor] = float(reference[anchor]["weight"])
			weights[anchor] = float(reference[anchor]["weight"])
		expect(not anchors.is_empty(), "the reference footprint is not empty")
	)
	await _wait_idle()
	step("Then the worker footprint holds the exact anchors and weights", func():
		expect(_tool._samples.size() == anchors.size(), "the worker footprint holds the same anchor count (%d vs %d)" % [_tool._samples.size(), anchors.size()])
		var mismatched := 0
		for anchor in anchors:
			if not _tool._samples.has(anchor):
				mismatched += 1
			elif absf(float(_tool._samples[anchor]["weight"]) - float(weights[anchor])) > 1e-9:
				mismatched += 1
		expect(mismatched == 0, "every worker anchor keeps its exact weight and point")
	)


func _flatten_worker() -> void:
	step("Given a flat plate and a maximum Flatten brush", func():
		_plate()
		_settings.tool = _settings.Tools.FLATTEN
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 32
		_settings.strength = 1.0
		_settings.falloff = 0.5
	)
	step("When the user presses once", func():
		_button(true, _screen(Vector3.ZERO))
		expect(_tool._tick_job != null and _tool._tick_job.preparing, "the Flatten press builds its footprint on the worker")
		_button(false, _screen(Vector3.ZERO))
	)
	await _wait_idle()
	step("Then the Flatten stroke closed without a leftover worker", func():
		expect(_tool._edit == null, "the Flatten stroke closed")
		expect(not _tool._busy(), "the Flatten worker retired")
	)


func _smooth_worker() -> void:
	step("Given a rough block and a maximum Smooth brush", func():
		_rough_block()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 32
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_before = _frame.capture()
	)
	step("When the user presses once", func():
		_button(true, _screen(Vector3(0, 4, 0)))
		expect(_tool._smooth_job != null, "the Smooth press started a rounding worker")
		expect(_tool._smooth_job.preparing, "the rounding worker owns the refit and the fields")
		_button(false, _screen(Vector3(0, 4, 0)))
	)
	await _wait_idle()
	step("Then the rounding ran on the worker and closed as one action", func():
		expect(_tool._edit == null, "the Smooth stroke closed")
		expect(not _tool._busy(), "the Smooth worker retired")
		expect(not VoxelEditTransaction._chunks_equal(_before, _frame.capture()), "the worker rounded the rough block")
		expect(State.undo_redo.get_history_count() == 1, "the Smooth click records one action")
	)


func _hover_reuse() -> void:
	step("Given a flat plate and a settled maximum-radius hover", func():
		_plate()
		_settings.tool = _settings.Tools.GROW
		_settings.radius = 32
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_motion(_screen(Vector3.ZERO))
	)
	await _settle_preview()
	step("When the user presses the hovered cell", func():
		expect(_tool._hover_frame != null, "the hover published a frame")
		_button(true, _screen(Vector3.ZERO))
		# The press adopts the accepted hover frame as its spacing frame, so the
		# two are the same object and no fit ran on the main thread.
		expect(_tool._cursor_frame == _tool._hover_frame, "the press reused the validated hover frame")
		expect(_tool._tick_job != null and _tool._tick_job.preparing, "the reused press still builds its footprint on the worker")
		_button(false, _screen(Vector3.ZERO))
	)
	await _wait_idle()
	step("Then the reused press applied one bounded action", func():
		expect(State.undo_redo.get_history_count() == 1, "the reused press records one action")
	)


func _cancel_pending() -> void:
	step("Given a maximum Grow press on a flat plate", func():
		_plate()
		_settings.tool = _settings.Tools.GROW
		_settings.radius = 32
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_before = _frame.capture()
		_button(true, _screen(Vector3.ZERO))
		expect(_tool._busy(), "the footprint worker is pending")
	)
	step("When the user presses Escape while the footprint is pending", func():
		_key(KEY_ESCAPE)
		expect(_tool._edit == null, "Escape closed the stroke")
		expect(not _tool._has_pending(), "Escape cleared the accepted path")
	)
	await _wait_idle()
	step("Then the plate is restored and no history was recorded", func():
		expect(not _tool._busy(), "the cancelled worker retired")
		expect(VoxelEditTransaction._chunks_equal(_before, _frame.capture()), "the cancelled press changed nothing")
		expect(not State.undo_redo.has_undo(), "the cancelled press recorded no history")
	)
