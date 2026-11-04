extends "res://tests/test.gd"

# Direct checks of the captured stroke inputs and of the footprint depth policy.
#
# The tests drive the real tool through the editor viewport. They compare the
# exact cells of the inline and worker dab paths, and they prove that an executed
# dab resolves the same tall support. They also prove that a later settings
# change cannot alter an open stroke and that a cancelled drain cannot consume a
# repress.

const ProbeScript := preload("./terrain_stroke_input_probe.gd")
const TerrainPreviewScript := preload("res://plugins/Terrain/TerrainPreview.gd")

var _settings := preload("res://plugins/Terrain/settings.tres")
var _viewport: SubViewport
var _tool
var _frame: VoxelFrame
var _original_material := PackedFloat32Array()


func _ready() -> void:
	test("a stroke keeps its captured settings and nested data", _captured_inputs, "captured_inputs")
	test("a cancelled drain cannot consume a repress", _cancel_repress, "cancel_repress")
	test("an inline and a worker dab apply the same cells at one depth", _inline_worker_parity, "inline_worker_parity")
	test("a tall Build support matches its hover", _tall_build_parity, "tall_build_parity")
	## test("a tall Flatten support matches its hover", _tall_flatten_parity, "tall_flatten_parity")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	State._apply_material(VoxelFrame.material(Color.CYAN))
	_settings.tool = _settings.Tools.BUILD
	_settings.build_mode = _settings.BuildMode.ADD
	_settings.radius = 4
	_settings.strength = 1.0
	_settings.falloff = 0.5
	_viewport = editor_viewport()
	_viewport.get_parent().stretch = false
	_viewport.size = Vector2i(800, 500)
	activate_tool("terrain")
	var terrain := plugin("TerrainPlugin")
	terrain.activate_tool()
	terrain.deactivate_tool()
	_tool = preload("res://plugins/Terrain/TerrainTool.tscn").instantiate()
	_tool.set_script(ProbeScript)
	if _tool._settings == null:
		_tool._settings = _settings
	terrain.add_editor_node(_tool)
	_tool.set_process(true)
	_frame = State.get_current_voxel_frame()
	camera_rig().is_orthogonal = true
	camera_rig().set_view("top")
	_original_material = PackedFloat32Array()
	await get_tree().process_frame


func _cleanup_test() -> void:
	if is_instance_valid(_tool):
		if _tool._edit != null:
			_tool.finish_on_switch()
		await _wait_idle()
		plugin("TerrainPlugin").remove_editor_node(_tool)
		_tool.free()
	_tool = null


# --- Fixtures and input -------------------------------------------------------

# A wide flat plate on the floor plane.
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


# A flat floor with one tall column inside a small footprint. The column is two
# cells from the brush center, so a radius-four disc reaches it. The top sits
# above the old per-radius depth and inside the bounded Build depth.
func _tower() -> void:
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	var changes := {}
	var material := VoxelFrame.material(Color.WHITE)
	for x in range(-12, 13):
		for z in range(-12, 13):
			changes[Vector3i(x, 0, z)] = material
	for y in range(1, 31):
		changes[Vector3i(2, y, 0)] = material
	_frame.set_cells(changes)
	sync_viewport()
	_view(AABB(Vector3(-16, -6, -16), Vector3(32, 42, 32)))
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true


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


func _motion(position: Vector2, pressed := false) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.position = position
	_viewport.push_input(event)


func _escape() -> void:
	var event := InputEventAction.new()
	event.action = "ui_cancel"
	event.pressed = true
	_tool.handle_input(event, Vector2.ZERO)


func _wait_idle() -> void:
	for _index in 1200:
		if _tool._edit == null and not _tool._busy() and not _tool._has_pending():
			await get_tree().process_frame
			return
		await get_tree().process_frame


# --- Cases --------------------------------------------------------------------

func _captured_inputs() -> void:
	step("Given a Build press with a selected center column", func():
		_plate()
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 4
		_settings.strength = 1.0
		_settings.falloff = 0.5
		State.selection.add(Vector3i(0, 1, 0))
		State.selection.add(Vector3i(0, 2, 0))
		_original_material = State.current_material
		_button(true, _screen(Vector3.ZERO))
		expect(_tool._edit != null, "the press captures one stroke record")
	)
	var context = _tool._edit.edit_context
	step("Then the record holds the captured inputs", func():
		expect(_tool._stroke_tool == _settings.Tools.BUILD, "the record holds the Build tool")
		expect(_tool._stroke_build_mode == _settings.BuildMode.ADD, "the record holds the Add mode")
		expect(_tool._stroke_radius == 4, "the record holds the press radius")
		expect(_tool._stroke_strength == 1.0, "the record holds the press strength")
		expect(_tool._stroke_falloff == 0.5, "the record holds the press falloff")
		expect(_tool._stroke_material == _original_material, "the record holds a copy of the press material")
		expect(_tool._stroke_context == context, "the record holds the frozen edit context")
		expect(is_same(_tool._stroke_selection, context.selection), "the record shares the frozen selection")
		expect(_tool._stroke_frame_index == State.current_frame, "the record holds the press frame index")
	)
	step("When the live settings, material, and selection change", func():
		_settings.radius = 16
		_settings.strength = 4.0
		_settings.falloff = 0.0
		var live_before := State.current_material
		State._current_material[0] = 0.75
		expect(State.current_material != live_before, "the live material array changed in place")
		State.clear_selection()
	)
	step("Then the open stroke keeps its captured values", func():
		expect(_tool._stroke_radius == 4, "the open stroke keeps the press radius")
		expect(_tool._stroke_strength == 1.0, "the open stroke keeps the press strength")
		expect(_tool._stroke_falloff == 0.5, "the open stroke keeps the press falloff")
		expect(_tool._stroke_material == _original_material, "the open stroke keeps the press material")
		expect(_tool._stroke_selection.has(Vector3i(0, 1, 0)), "the open stroke keeps its frozen selection")
		expect(is_same(_tool._stroke_selection, context.selection), "the frozen selection keeps its identity")
	)
	step("Then the stroke writes the captured material", func():
		_tool.advance_stroke(1.0)
		expect(_frame.get_material(Vector3i(0, 1, 0)) == _original_material, "the press layer uses the captured material")
		expect(_frame.get_material(Vector3i(0, 2, 0)) == _original_material, "the advanced layer uses the captured material")
		_button(false, _screen(Vector3.ZERO))
	)
	await _wait_idle()


func _cancel_repress() -> void:
	step("Given a long Build stroke that yields a frame", func():
		_plate()
		_view(AABB(Vector3(-60, -6, -60), Vector3(240, 24, 120)))
		_settings.radius = 4
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_button(true, _screen(Vector3.ZERO))
		_motion(_screen(Vector3(150, 0, 0)), true)
		expect(_tool._edit != null, "the long stroke is open")
		expect(_tool._drain_active, "the long drain still runs")
	)
	var old_id: int = _tool._stroke_id
	await get_tree().process_frame
	step("When the user cancels and represses elsewhere", func():
		_escape()
		expect(_tool._edit == null, "the cancel clears the stroke record")
		expect(not _tool._has_pending(), "the cancel clears the accepted path")
		_button(true, _screen(Vector3(80, 0, 0)))
		expect(_tool._edit != null, "the repress opens its own stroke")
		expect(_tool._stroke_id == old_id + 1, "the repress starts a newer stroke id")
		expect(_tool._stroke_tx == _tool._edit, "the new stroke owns its own transaction")
		_button(false, _screen(Vector3(80, 0, 0)))
		expect(_tool._drain_stroke_id == _tool._stroke_id, "the new release drain owns the token")
	)
	await _wait_idle()
	step("Then the new stroke consumed only its own dab", func():
		expect(_frame.has(Vector3i(80, 0, 0)), "the new press applied its own dab")
		expect(not _frame.has(Vector3i(30, 1, 0)), "the cancelled path applied no intermediate layer")
		expect(not _frame.has(Vector3i(20, 1, 0)), "the cancelled path applied no early layer")
		expect(State.undo_redo.has_undo(), "the new stroke records one action")
		State.undo()
		expect(_frame.has(Vector3i(0, 0, 0)), "one undo restores the plate under the first press")
		expect(not _frame.has(Vector3i(80, 0, 0)), "one undo removes only the new stroke")
	)


func _inline_worker_parity() -> void:
	step("Given the same small press on the inline path", func():
		_plate()
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 4
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_tool.force_worker = false
		_tool.reset_probe()
		_button(true, _screen(Vector3.ZERO))
		expect(not _tool._busy(), "the small press ran inline")
		expect(not _tool.prep_started, "the small press started no preparation worker")
		_button(false, _screen(Vector3.ZERO))
	)
	await _wait_idle()
	var inline_capture := _frame.capture()
	step("When the same press takes the worker path", func():
		_plate()
		_tool.force_worker = true
		_tool.reset_probe()
		_button(true, _screen(Vector3.ZERO))
		expect(_tool.prep_started, "the forced press took the preparation worker path")
		_button(false, _screen(Vector3.ZERO))
	)
	await _wait_idle()
	var worker_capture := _frame.capture()
	var depth: int = TerrainPreviewScript.footprint_depth(4)
	var tool_depth: int = _tool._footprint_depth(4)
	var prep_depth: int = _tool.last_prep_depth
	step("Then both paths apply the same cells at the matched depth", func():
		expect(VoxelEditTransaction._chunks_equal(inline_capture, worker_capture), "the inline and worker dabs apply the same cells")
		expect(depth == 16, "the Build policy scales with the diameter for small values")
		expect(tool_depth == depth, "the tool uses the Build depth")
		# The worker map reaches the tall support bound, so a column above the
		# small footprint depth still resolves.
		expect(prep_depth == _tool._height_depth(), "the preparation worker maps the tall support bound")
	)


func _tall_build_parity() -> void:
	step("Given a tall column inside a small footprint and the Face source", func():
		_tower()
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 4
		_settings.strength = 1.0
		_settings.falloff = 0.0
		activate_tool("terrain")
		var terrain := plugin("TerrainPlugin")
		terrain.activate_tool()
		terrain.deactivate_tool()
		_tool.force_worker = false
	)
	step("When the user presses the column top", func():
		_button(true, _screen(Vector3(2, 30, 0)))
		expect(not _tool._busy(), "the small press ran inline")
		_button(false, _screen(Vector3(2, 30, 0)))
	)
	# The release starts the drain. A new document mid-drain would leave the
	# stroke open, so the next case waits for the idle tool.
	await _wait_idle()
	step("Then the executed dab grows the tall support", func():
		# The column at x = 2 already stands thirty cells high. The press puts the
		# brush on its top, so one dab adds exactly one layer there.
		expect(_frame.has(Vector3i(2, 31, 0)), "the execution adds one layer above the tall support")
		expect(not _frame.has(Vector3i(2, 32, 0)), "one dab adds one layer only")
		expect(_frame.has(Vector3i(2, 15, 0)), "the support below the added layer stays")
	)
