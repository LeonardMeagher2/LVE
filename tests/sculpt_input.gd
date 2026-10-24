extends "res://tests/test.gd"

# Exercise the public pointer input without advancing an internal edit clock.
# Replays must not depend on frame timing or the number of motion events.
var _settings := preload("res://plugins/Sculpt/settings.tres")
var _viewport: SubViewport
var _tool: Node3D
var _frame: VoxelFrame
var _pressed := Vector2.ZERO
var _after_press := {}
var _original := {}
var _fast := {}
var _stepped := {}
var _far_pointer := Vector2.ZERO


func _ready() -> void:
	test("a quick Grow click applies in its input event", _quick_click, "quick_click")
	test("Remove, Flatten, and Smooth apply once per click", _click_operators, "click_operators")
	test("a stationary Sculpt pointer never repeats its application", _stationary, "stationary")
	test("Grow path replay ignores frame and motion-event timing", _path_replay, "path_replay")
	test("a Smooth click removes isolated remnants only inside the brush", _smooth_remnants, "smooth_remnants")
	test("a new click cannot join a stroke that is finishing", _finishing_click, "finishing_click")
	test("a cancel and repress during a frame-yielded drain stays safe", _cancel_mid_drain, "cancel_mid_drain")
	test("the Sculpt implementation has no random source", _no_random_source, "no_random_source")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.symmetry_axes = 0
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	_settings.tool = _settings.Tools.GROW
	_settings.grow_mode = _settings.GrowMode.ADD
	_settings.radius = 2
	_settings.strength = 1.0
	_settings.falloff = 0.0
	_settings.normal_source = _settings.NormalSource.SURFACE
	_viewport = editor_viewport()
	_viewport.get_parent().stretch = false
	_viewport.size = Vector2i(800, 500)
	activate_tool("sculpt")
	plugin("SculptPlugin").activate_tool()
	_tool = plugin("SculptPlugin")._tool
	_tool.set_process(true)
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true
	_frame = State.get_current_voxel_frame()
	_pressed = camera_rig().unproject_position(Vector3.ZERO)
	_after_press = {}
	_original = {}
	_fast = {}
	_stepped = {}


func _cleanup_test() -> void:
	if _tool != null and _tool._edit != null:
		_tool.finish_on_switch()
		await _wait_idle()


func _button(pressed: bool, position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	event.position = position
	_viewport.push_input(event)


func _motion(position: Vector2, relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.position = position
	event.relative = relative
	_viewport.push_input(event)


func _wait_idle() -> void:
	while _tool._edit != null:
		await get_tree().process_frame


func _quick_click() -> void:
	step("Given an empty floor and the default-strength Grow tool", func():
		expect(_frame.count() == 0, "the floor starts empty")
	)
	step("When the user presses and releases before the next frame", func():
		_button(true, _pressed)
		expect(_frame.count() > 0, "the press visibly adds its first layer immediately")
		_button(false, _pressed)
	)
	await _wait_idle()
	step("Then the click records one complete undo action", func():
		expect(_frame.count() > 0, "the completed quick click keeps its voxels")
		expect(State.undo_redo.has_undo(), "the quick click records history")
		State.undo()
		expect(_frame.count() == 0, "one undo removes the entire click")
		expect(not State.undo_redo.has_undo(), "the click records only one action")
	)


func _stationary() -> void:
	step("When the user presses Grow without moving", func():
		_button(true, _pressed)
		_after_press = _frame.capture()
		expect(_frame.count() > 0, "the press applies before the hold")
	)
	# This wait exercises the actual runtime process callbacks, not a test clock.
	await get_tree().create_timer(1.2).timeout
	step("When repeated motion events report the same pointer position", func():
		for _event in 4:
			_motion(_pressed, Vector2.ZERO)
	)
	await get_tree().process_frame
	step("Then neither the hold nor duplicate events add another layer", func():
		expect(VoxelEditTransaction._chunks_equal(_after_press, _frame.capture()), "stationary input preserves the first application exactly")
		_button(false, _pressed)
	)
	await _wait_idle()


func _click_operators() -> void:
	for operator in [_settings.Tools.GROW, _settings.Tools.FLATTEN, _settings.Tools.SMOOTH]:
		step("Given an occupied surface and a one-application brush", func():
			State.document = VoxelDocument.new()
			_frame = State.get_current_voxel_frame()
			var cells := {}
			for x in range(-4, 1):
				for y in range(-4, 1):
					for z in range(-4, 1):
						cells[Vector3i(x, y, z)] = VoxelFrame.material(Color.CYAN)
			if operator == _settings.Tools.FLATTEN:
				cells[Vector3i(-2, 1, -2)] = VoxelFrame.material(Color.CYAN)
				cells[Vector3i(-2, 2, -2)] = VoxelFrame.material(Color.CYAN)
			_frame.set_cells(cells)
			_settings.tool = operator
			_settings.grow_mode = _settings.GrowMode.REMOVE
			_settings.radius = 2
			_settings.strength = 1.0
			_settings.falloff = 0.0
			camera_rig().set_view("top")
			camera_rig().is_orthogonal = true
			var point := Vector3(-2, 2, -2) if operator == _settings.Tools.FLATTEN else Vector3.ZERO
			_pressed = camera_rig().unproject_position(point)
			_after_press = _frame.capture()
			_original = _after_press
		)
		step("When the user presses the brush", func():
			_button(true, _pressed)
			expect(not VoxelEditTransaction._chunks_equal(_after_press, _frame.capture()), "the operator changes geometry in the press event")
			_after_press = _frame.capture()
		)
		await get_tree().create_timer(1.2).timeout
		step("Then a stationary pointer does not apply again", func():
			_motion(_pressed, Vector2.ZERO)
			expect(VoxelEditTransaction._chunks_equal(_after_press, _frame.capture()), "holding and duplicate motion preserve the first application")
			_button(false, _pressed)
		)
		await _wait_idle()
		step("Then one undo restores the stroke's original surface", func():
			expect(State.undo_redo.has_undo(), "the operator records one undo action")
			State.undo()
			expect(VoxelEditTransaction._chunks_equal(_original, _frame.capture()), "one undo restores the original geometry and materials")
			expect(not State.undo_redo.has_undo(), "the operator creates no second history action while held")
		)


func _path_replay() -> void:
	step("Given a hard-edged brush over the empty floor", func():
		expect(_settings.falloff == 0.0, "the footprint has uniform influence")
	)
	_fast = await _replay(false, false)
	_stepped = await _replay(true, false)
	var coalesced := await _replay(false, true)
	step("Then every delivery of the path produces the same voxels", func():
		expect(not _fast.is_empty(), "the replay produces visible voxels")
		expect(VoxelEditTransaction._chunks_equal(_fast, _stepped), "frame-spaced input matches the fast replay")
		expect(VoxelEditTransaction._chunks_equal(_fast, coalesced), "one long motion matches all crossed brush cells")
	)


func _replay(wait_frames: bool, coalesced: bool) -> Dictionary:
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true
	var start := camera_rig().unproject_position(Vector3.ZERO)
	_button(true, start)
	var previous := start
	for index in range(1, 7):
		if coalesced and index != 6:
			continue
		if wait_frames:
			await get_tree().process_frame
			await get_tree().process_frame
		var position := camera_rig().unproject_position(Vector3(float(index), 0, 0))
		_motion(position, position - previous)
		previous = position
	_button(false, previous)
	await _wait_idle()
	return _frame.capture()


func _cancel_mid_drain() -> void:
	step("Given a long queued Grow stroke that yields a frame", func():
		_settings.radius = 4
		_settings.strength = 1.0
		_settings.falloff = 0.5
		camera_rig().set_view("top")
		camera_rig().is_orthogonal = true
		_far_pointer = camera_rig().unproject_position(Vector3(80, 0, 0))
		_button(true, _pressed)
		var far := camera_rig().unproject_position(Vector3(150, 0, 0))
		_motion(far, far - _pressed)
		expect(_tool._edit != null, "the long stroke is open")
		expect(_tool._drain_active, "the long drain is still running")
	)
	await get_tree().process_frame
	step("When the user cancels and represses elsewhere before the drain ends", func():
		expect(_tool._drain_active, "the drain still waits on a frame")
		_escape()
		_button(true, _far_pointer)
		_button(false, _far_pointer)
	)
	await _wait_idle()
	step("Then the cancelled path consumed nothing of the new stroke", func():
		expect(_tool._edit == null, "the new stroke finished on its own")
		expect(_frame.has(Vector3i(80, 0, 0)), "the new press applied its own dab")
		expect(not _frame.has(Vector3i(30, 0, 0)), "the cancelled path applied no intermediate dab")
		expect(not _frame.has(Vector3i(60, 0, 0)), "the cancelled path applied no far dab")
		expect(State.undo_redo.has_undo(), "the new stroke records one action")
		State.undo()
		expect(_frame.count() == 0, "one undo removes only the new stroke")
	)


func _escape() -> void:
	var event := InputEventAction.new()
	event.action = "ui_cancel"
	event.pressed = true
	_tool.handle_input(event, Vector2.ZERO)


func _no_random_source() -> void:
	step("Then no Sculpt module calls a random source", func():
		var calls := RegEx.new()
		calls.compile("\\b(?:randf|randi|randfn|randf_range|randi_range|randomize|seed|shuffle)\\s*\\(|RandomNumberGenerator")
		for filename in ["SculptTool.gd", "SculptGeometry.gd", "SculptFrame.gd", "SmoothOperation.gd"]:
			var source := FileAccess.get_file_as_string("res://plugins/Sculpt/" + filename)
			expect(calls.search(source) == null, "%s has no random source" % filename)
	)


func _smooth_remnants() -> void:
	step("Given a small feature and a separate voxel outside the brush", func():
		var material := VoxelFrame.material(Color.CYAN)
		_frame.set_cells({
			Vector3i.LEFT: material, Vector3i.ZERO: material, Vector3i.RIGHT: material,
			Vector3i(12, 0, 0): material,
		})
		_original = _frame.capture()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 2
		_settings.strength = 1.0
		_settings.falloff = 0.0
		_pressed = camera_rig().unproject_position(Vector3.ZERO)
	)
	step("When the user clicks Smooth once", func():
		_button(true, _pressed)
		_button(false, _pressed)
	)
	await _wait_idle()
	step("Then the brush leaves no isolated middle voxel", func():
		expect(not _frame.has(Vector3i.ZERO), "the newly isolated middle is removed")
		expect(_frame.count() == 1, "only the voxel outside the brush remains")
		expect(_frame.get_material(Vector3i(12, 0, 0)) == VoxelFrame.material(Color.CYAN), "the outside voxel keeps its full material")
		State.undo()
		expect(VoxelEditTransaction._chunks_equal(_original, _frame.capture()), "one undo restores the original feature and materials")
	)


func _finishing_click() -> void:
	step("Given a large Grow stroke that finishes on the worker", func():
		_settings.radius = 32
		_settings.strength = 2.0
		_far_pointer = camera_rig().unproject_position(Vector3(80, 0, 0))
		_button(true, _pressed)
		_button(false, _pressed)
		expect(_tool._edit != null, "the released stroke still owns its pending edit")
	)
	step("When another click arrives before that stroke finishes", func():
		_settings.normal_source = _settings.NormalSource.FACE
		_button(true, _far_pointer)
		_button(false, _far_pointer)
	)
	await _wait_idle()
	step("Then the pending edit contains only its accepted stroke", func():
		expect(_frame.has(Vector3i.ZERO), "the original stroke finishes normally")
		expect(not _frame.has(Vector3i(80, 0, 0)), "a premature click does not join the finishing stroke")
		State.undo()
		expect(_frame.count() == 0, "one undo removes only the original completed stroke")
	)
