extends "res://tests/test.gd"

# Run this optional benchmark directly. Keep it outside automatic suite discovery.
# Compare warmed alternatives in one process with alternating execution order.
# Each tool, radius, and gesture runs on the small and the large model. Each
# pair restores the fixture, resets the counters, drives one real stroke, and
# reads the phase counters and the surface profile.
const REPEATS := 5
const WARMUPS := 2
const DRAG_STEPS := 12
# The maximum-radius Smooth drag rounds a 4x larger field per dab. Its edit
# wait needs more than the shared 120 s deadline. Only it gets this one.
const HEAVY_TIMEOUT := 900.0
const ProbeScript := preload("./terrain_latency_tool.gd")
const TOOLS := ["Build", "Flatten", "Grab", "Smooth"]
const RADII := [2, 4, 16, 32]
const MODES := ["tap", "drag"]
const FIXTURES := ["small", "large"]

var _tool: Node3D
var _frame: VoxelFrame
var _fixture: VoxelFrame
var _fixture_chunks := {}
var _renderer: VoxelRenderer
var _viewport: SubViewport
var _settings := preload("res://plugins/Terrain/settings.tres")
var _measuring := false
var _last_frame_us := 0
var _longest_frame_us := 0
var _last_chunks := {}
var _large_fixture: VoxelFrame = null
var _large_fixture_us := 0


func _ready() -> void:
	timeout = 120.0
	test("a small rendered Smooth stroke matches its reference", func(): await _compare(4), "small")
	test("a medium rendered Smooth stroke matches its reference", func(): await _compare(16), "medium")
	test("a maximum rendered Smooth stroke matches its reference", func(): await _compare(32), "large")
	for tool in TOOLS:
		for radius in RADII:
			for mode in MODES:
				for fixture in FIXTURES:
					var description := "a %s %s at radius %d on the %s model" % [tool, mode, radius, fixture]
					var name := "%s-%s-%d-%s" % [tool.to_lower(), mode, radius, fixture]
					var heavy: bool = tool == "Smooth" and mode == "drag" and radius == 32
					if heavy:
						timeout = HEAVY_TIMEOUT
					test(description, func(): await _run(_tool_id(tool), radius, mode, fixture), name)
					if heavy:
						timeout = 120.0


func _process(_delta: float) -> void:
	if not _measuring:
		return
	var now := Time.get_ticks_usec()
	_longest_frame_us = maxi(_longest_frame_us, now - _last_frame_us)
	_last_frame_us = now


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.symmetry_axes = 0
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	_settings.tool = _settings.Tools.SMOOTH
	_settings.strength = 1.0
	_settings.falloff = 0.5
	_viewport = editor_viewport()
	_viewport.get_parent().stretch = false
	_viewport.size = Vector2i(800, 500)
	activate_tool("terrain")
	plugin("TerrainPlugin").deactivate_tool()
	_tool = preload("res://plugins/Terrain/TerrainTool.tscn").instantiate()
	_tool.set_script(ProbeScript)
	plugin("TerrainPlugin").add_editor_node(_tool)
	_tool.set_process(false)
	_renderer = viewport_scene().get_node("VoxelRenderer")
	_frame = State.get_current_voxel_frame()
	if _desc.contains("on the large model"):
		_build_large_fixture()
		_frame.chunks = _large_fixture.chunks.duplicate()
		_frame.invalidate_bounds()
	else:
		var changes := {}
		var material := VoxelFrame.material(Color.from_rgba8(100, 180, 220))
		for x in range(-36, 37):
			for z in range(-36, 37):
				for y in range(-3, 1):
					changes[Vector3i(x, y, z)] = material
				if posmod(x, 3) == 0 and posmod(z, 3) == 0:
					changes[Vector3i(x, 1, z)] = material
		_frame.set_cells(changes)
	_fixture = _frame.copy_frame()
	_fixture_chunks = _fixture.capture()
	sync_viewport()
	camera_rig().configure()
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true
	await _settle()


func _cleanup_test() -> void:
	_measuring = false
	if is_instance_valid(_tool):
		if _tool._edit != null:
			_tool.finish_on_switch()
		while _tool._smooth_job != null:
			await get_tree().process_frame
		while _tool._tick_job != null or _tool._grab_job != null:
			await get_tree().process_frame
		_tool.free()
	_fixture = null
	_fixture_chunks = {}
	_last_chunks = {}


func _compare(radius: int) -> void:
	step("Given the same rough surface and brush radius", func():
		_settings.radius = radius
	)
	var reference := []
	var candidate := []
	for pair in WARMUPS + REPEATS:
		var first: bool = pair % 2 == 0
		var a: Dictionary = await _stroke(first)
		var a_chunks := _last_chunks
		var b: Dictionary = await _stroke(not first)
		step("Then the paired strokes preserve the same geometry and materials", func():
			expect(VoxelEditTransaction._chunks_equal(a_chunks, _last_chunks), "the paired strokes produce identical full materials")
		)
		if pair >= WARMUPS:
			reference.append(a if first else b)
			candidate.append(b if first else a)
	step("Then the real strokes report edit and visible completion", func():
		for path in ["reference", "candidate"]:
			var rows: Array = reference if path == "reference" else candidate
			print("MEASURE terrain_viewport radius=%d path=%s headless=%s input_us=%d edit_us=%d visible_us=%d gap_us=%d" % [
				radius, path, str(DisplayServer.get_name() == "headless"),
				_median(rows, "input"), _median(rows, "edit"),
				_median(rows, "visible"), _median(rows, "gap"),
			])
	)


# Runs one configuration: warm up, then measure alternating paired strokes.
# Both paths run the same tool and the same input, so their geometry must match
# and their latencies expose drift across the run.
func _run(tool_id: int, radius: int, mode: String, fixture: String) -> void:
	step("Given the %s model, %s, and radius %d" % [fixture, TOOLS[tool_id], radius], func():
		_settings.tool = tool_id
		_settings.radius = radius
	)
	var a_rows := []
	var b_rows := []
	for pair in WARMUPS + REPEATS:
		var a: Dictionary = await _stroke_pair(mode)
		var a_chunks := _last_chunks
		var b: Dictionary = await _stroke_pair(mode)
		step("Then the paired strokes preserve the same geometry and materials", func():
			expect(VoxelEditTransaction._chunks_equal(a_chunks, _last_chunks), "the paired strokes produce identical full materials")
		)
		if pair >= WARMUPS:
			a_rows.append(a)
			b_rows.append(b)
	step("Then the measured stroke reports edit and visible completion", func():
		for path in ["a", "b"]:
			var rows: Array = a_rows if path == "a" else b_rows
			print("MEASURE terrain_use tool=%s radius=%d mode=%s fixture=%s path=%s headless=%s input_us=%d edit_us=%d visible_us=%d gap_us=%d" % [
				TOOLS[tool_id], radius, mode, fixture, path,
				str(DisplayServer.get_name() == "headless"),
				_median(rows, "input"), _median(rows, "edit"),
				_median(rows, "visible"), _median(rows, "gap"),
			])
			print("MEASURE terrain_use_phases tool=%s radius=%d mode=%s fixture=%s path=%s headless=%s %s" % [
				TOOLS[tool_id], radius, mode, fixture, path,
				str(DisplayServer.get_name() == "headless"),
				_phases(rows),
			])
	)


# Drives one legacy Smooth stroke with the reference or the live job. The
# paired strokes must leave the same geometry.
func _stroke(reference: bool) -> Dictionary:
	_frame.restore(_fixture_chunks)
	State.undo_redo.clear_history()
	sync_viewport()
	await _settle()
	_tool.use_reference = reference
	var position := camera_rig().unproject_position(Vector3(0, 1, 0))
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_LEFT
	button.pressed = true
	button.button_mask = MOUSE_BUTTON_MASK_LEFT
	button.position = position
	var started := Time.get_ticks_usec()
	_last_frame_us = started
	_longest_frame_us = 0
	_measuring = true
	_viewport.push_input(button)
	button = button.duplicate()
	button.pressed = false
	button.button_mask = 0
	_viewport.push_input(button)
	var input_us := Time.get_ticks_usec() - started
	while _tool._edit != null:
		await get_tree().process_frame
	var edit_us := Time.get_ticks_usec() - started
	await _settle()
	var visible_us := Time.get_ticks_usec() - started
	_measuring = false
	_last_chunks = _frame.capture()
	step("Then the stroke changes the surface and supports undo", func():
		expect(State.undo_redo.has_undo(), "the Smooth stroke changes the rough surface")
		State.undo()
		expect(VoxelEditTransaction._chunks_equal(_fixture_chunks, _frame.capture()), "one undo restores the full fixture")
	)
	return {"input": input_us, "edit": edit_us, "visible": visible_us, "gap": _longest_frame_us}


# Drives one real stroke on a restored fixture and reads its timing, its phase
# counters, and its surface profile. The stroke must leave the model changed and
# one undo must restore the fixture.
func _stroke_pair(mode: String) -> Dictionary:
	_reset_counters()
	_frame.restore(_fixture_chunks)
	State.undo_redo.clear_history()
	sync_viewport()
	await _settle()
	var press := _press_event()
	var started := Time.get_ticks_usec()
	_last_frame_us = started
	_longest_frame_us = 0
	_measuring = true
	_viewport.push_input(press)
	if mode == "drag":
		for i in range(1, DRAG_STEPS + 1):
			_viewport.push_input(_drag_event(i * 2))
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.button_mask = 0
	release.position = press.position
	_viewport.push_input(release)
	var input_us := Time.get_ticks_usec() - started
	while _tool._edit != null:
		await get_tree().process_frame
	var edit_us := Time.get_ticks_usec() - started
	await _settle()
	var visible_us := Time.get_ticks_usec() - started
	_measuring = false
	_last_chunks = _frame.capture()
	var counters := _read_counters()
	var surface := _renderer.profile_snapshot()
	_renderer.reset_profile()
	var changed := not VoxelEditTransaction._chunks_equal(_fixture_chunks, _last_chunks)
	step("Then the stroke leaves one undo that restores the fixture", func():
		expect(State.undo_redo.has_undo() == changed, "the stroke records a history action only when it changes the model")
		if changed:
			State.undo()
			expect(VoxelEditTransaction._chunks_equal(_fixture_chunks, _frame.capture()), "one undo restores the full fixture")
	)
	return {
		"input": input_us, "edit": edit_us, "visible": visible_us, "gap": _longest_frame_us,
		"phases": counters, "surface": surface, "changed": changed,
	}


func _press_event() -> InputEventMouseButton:
	var position := camera_rig().unproject_position(Vector3(0, 1, 0))
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_LEFT
	button.pressed = true
	button.button_mask = MOUSE_BUTTON_MASK_LEFT
	button.position = position
	return button


func _drag_event(cells: int) -> InputEventMouseMotion:
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.position = camera_rig().unproject_position(Vector3(cells, 1, 0))
	return motion


func _reset_counters() -> void:
	VoxelFrame._profile_capture_calls = 0
	VoxelFrame._profile_capture_us = 0
	VoxelFrame._profile_restore_calls = 0
	VoxelFrame._profile_restore_us = 0
	VoxelFrame._profile_copy_frame_calls = 0
	VoxelFrame._profile_job_frame_calls = 0
	VoxelFrame._profile_publish_calls = 0
	VoxelFrame._profile_publish_us = 0
	VoxelFrame._profile_set_cells_calls = 0
	VoxelFrame._profile_set_cells_us = 0
	VoxelFrame._profile_cell_writes = 0
	VoxelFrame._profile_bounds_rescan_calls = 0
	VoxelFrame._profile_bounds_rescan_us = 0
	VoxelEditTransaction._profile_chunks_equal_calls = 0
	VoxelEditTransaction._profile_chunks_equal_us = 0
	VoxelDocument._profile_rescan_calls = 0
	VoxelDocument._profile_rescan_us = 0
	TerrainPreview._profile_sample_candidates = 0
	TerrainPreview._profile_smooth_candidates = 0
	_renderer.profile_surfaces = true
	_renderer.reset_profile()


func _read_counters() -> Dictionary:
	return {
		"capture_calls": VoxelFrame._profile_capture_calls,
		"capture_us": VoxelFrame._profile_capture_us,
		"restore_calls": VoxelFrame._profile_restore_calls,
		"restore_us": VoxelFrame._profile_restore_us,
		"copy_frame_calls": VoxelFrame._profile_copy_frame_calls,
		"job_frame_calls": VoxelFrame._profile_job_frame_calls,
		"publish_calls": VoxelFrame._profile_publish_calls,
		"publish_us": VoxelFrame._profile_publish_us,
		"set_cells_calls": VoxelFrame._profile_set_cells_calls,
		"set_cells_us": VoxelFrame._profile_set_cells_us,
		"cell_writes": VoxelFrame._profile_cell_writes,
		"bounds_rescan_calls": VoxelFrame._profile_bounds_rescan_calls,
		"bounds_rescan_us": VoxelFrame._profile_bounds_rescan_us,
		"chunks_equal_calls": VoxelEditTransaction._profile_chunks_equal_calls,
		"chunks_equal_us": VoxelEditTransaction._profile_chunks_equal_us,
		"doc_rescan_calls": VoxelDocument._profile_rescan_calls,
		"doc_rescan_us": VoxelDocument._profile_rescan_us,
		"sample_candidates": TerrainPreview._profile_sample_candidates,
		"smooth_candidates": TerrainPreview._profile_smooth_candidates,
	}


func _phases(rows: Array) -> String:
	var totals := {}
	var surface := {}
	for key in ["launch", "material_us", "cache_us", "install_us", "snapshot_us", "snapshots"]:
		surface[key] = 0
	for row in rows:
		var phases: Dictionary = row["phases"]
		for key in phases:
			totals[key] = int(totals.get(key, 0)) + int(phases[key])
		var s: Dictionary = row["surface"]
		for key in surface:
			surface[key] += int(s[key])
	var parts := PackedStringArray()
	for key in totals:
		parts.append("%s=%d" % [key, int(totals[key])])
	for key in surface:
		parts.append("surf_%s=%d" % [key, int(surface[key])])
	return " ".join(parts)


func _tool_id(name: String) -> int:
	match name:
		"Build":
			return _settings.Tools.BUILD
		"Flatten":
			return _settings.Tools.FLATTEN
		"Grab":
			return _settings.Tools.GRAB
		"Smooth":
			return _settings.Tools.SMOOTH
	return _settings.Tools.BUILD


# Builds the large fixture once. A 96 by 96 by 4 slab plus a 32 by 32 grid of
# 2 by 2 by 2 blocks every 32 cells holds about a thousand chunks. The blocks
# that sit over the slab are skipped, so every block owns one chunk.
func _build_large_fixture() -> void:
	if _large_fixture != null:
		return
	var started := Time.get_ticks_usec()
	var frame := VoxelFrame.new()
	var changes := {}
	var material := VoxelFrame.material(Color.from_rgba8(100, 180, 220))
	for x in range(-48, 48):
		for z in range(-48, 48):
			for y in range(-3, 1):
				changes[Vector3i(x, y, z)] = material
	for bx in range(-496, 497, 32):
		for bz in range(-496, 497, 32):
			if absi(bx) < 50 and absi(bz) < 50:
				continue
			for x in [bx, bx + 1]:
				for z in [bz, bz + 1]:
					for y in [0, 1]:
						changes[Vector3i(x, y, z)] = material
	frame.set_cells(changes, null, material)
	_large_fixture = frame
	_large_fixture_us = Time.get_ticks_usec() - started
	print("MEASURE terrain_fixture large chunks=%d cells=%d build_us=%d" % [
		_large_fixture.chunks.size(), _large_fixture.positions().size(), _large_fixture_us,
	])


func _settle() -> void:
	await get_tree().process_frame
	while not _renderer.is_settled():
		await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw


func _median(rows: Array, key: String) -> int:
	var values := []
	for row in rows:
		values.append(int(row[key]))
	values.sort()
	return values[values.size() / 2]
