extends "res://tests/test.gd"

# A rendered-latency benchmark for the sculpt hover preview.
#
# Run it directly. Keep it outside automatic suite discovery.
#
#   godot --path . --screen 1 res://tests/benchmarks/sculpt_preview.tscn
#   godot --path . --screen 1 res://tests/benchmarks/sculpt_preview.tscn -- ramp_r4
#
# The benchmark drives the real editor viewport with real mouse events and a real
# windowed renderer. It measures the hover path only:
#
#   * the mouse event through the viewport: the ray pick and the plane fit,
#   * the frame update: the preview rebuild, the footprint sample map, and the
#     cell set it submits,
#   * the mesh install: the first frame at which a new settled cursor mesh
#     appears.
#
# The fixture, the tool build, and the first settle stay outside every timed
# region. The benchmark does not measure the stroke edit path. The existing
# sculpt_latency benchmark covers that path and it disables the tool `_process`,
# so it cannot see any preview cost.
#
# The cursor already drops an identical request, so a repeated cell set costs no
# mesh work. The probe counts the requests that reached the mesh layer
# (`submits`) apart from the requests the layer dropped as identical (`dedupe`).
# The sample map still runs on every dirty frame, so `sample_maps` with zero
# `submits` is the wasted CPU work.
#
# The tool `_process` stays on. Every scenario reads the cursor of a probe tool
# instance, and the plugin's own tool is out of the tree, so one node handles
# input.
#
# Two limits of the numbers:
#
# * The preview layer keeps one static mesh cache for the process. Only the first
#   case that requests a given cell set pays the outline build. `cache_hits`
#   reports the requests the cache could serve. Run one case with
#   `-- <name>` for a cold mesh measurement.
# * This node processes before the tool, so a rebuild and an install of the last
#   measured frame are read by a flush. A frame slot can hold one event and one
#   rebuild, so a rebuild count can be one below the event count. The reported
#   means and medians use the collected rows.

const ProbeScript := preload("./sculpt_preview_probe.gd")
# The viewport size of the rendered cases.
const VIEWPORT_SIZE := Vector2i(800, 500)
# The half extent of the fixture in cells.
const HALF := 36
# The body layers under the surface.
const BODY := 3
# The cell step of the ramp height. Four cells raise the surface by one.
const SLOPE_STEP := 4
# The repeated no-button motions at one cell.
const SAME_EVENTS := 6
# The no-button motions over changing cells.
const SWEEP_EVENTS := 10
# The cell step between two sweep cells.
const SWEEP_STEP := 3
# The selection box of the selection case, in cells.
const SELECTION_MIN := Vector3i(-20, -6, -12)
const SELECTION_MAX := Vector3i(20, 4, 12)
# The cursor color of the material-only case.
const COLOR_A := Color(0.9, 0.2, 0.2)
const COLOR_B := Color(0.2, 0.9, 0.3)
# The frames a scenario waits for a new settled cursor mesh.
const INSTALL_FRAMES := 60

# The measured cases. A full case also measures the material-only change and the
# geometry change, because the other cases only need the hover path.
const SPECS := [
	{"name": "ramp_r4", "radius": 4, "axes": 0, "selection": false, "mixed": false, "full": true},
	{"name": "ramp_r16", "radius": 16, "axes": 0, "selection": false, "mixed": false, "full": true},
	{"name": "ramp_r32", "radius": 32, "axes": 0, "selection": false, "mixed": false, "full": true},
	{"name": "mixed_r4", "radius": 4, "axes": 0, "selection": false, "mixed": true, "full": false},
	{"name": "symmetry_r4", "radius": 4, "axes": 3, "selection": false, "mixed": false, "full": false},
	{"name": "selection_r4", "radius": 4, "axes": 0, "selection": true, "mixed": false, "full": false},
]

var _settings := preload("res://plugins/Sculpt/settings.tres")
var _tool
var _cursor: MeshInstance3D
var _frame: VoxelFrame
var _renderer: VoxelRenderer
var _viewport: SubViewport
var _path: Array[Vector3i] = []
var _fixture_cells := 0
var _fixture_chunks := 0
var _fixture_us := 0
var _settle_us := 0

# The frame sampling. `_process` fills it while `_measuring`.
var _measuring := false
var _last_frame_us := 0
var _longest_frame_us := 0
var _frames := 0
var _last_cursor_mesh := 0
var _cursor_installs := 0
var _last_rebuild_us := 0
var _rebuild_rows: Array = []
var _snapshots := {}


func _ready() -> void:
	timeout = 60.0
	for spec in SPECS:
		test("the sculpt hover preview cost at %s" % spec["name"], func(): await _run(spec), spec["name"])


func _process(_delta: float) -> void:
	if not _measuring:
		return
	var now := Time.get_ticks_usec()
	_longest_frame_us = maxi(_longest_frame_us, now - _last_frame_us)
	_last_frame_us = now
	_frames += 1
	_sample_cursor()
	# A rebuild that landed since the last frame. The sample can belong to the
	# frame before this one, because this node processes before the tool. The
	# final frame of a scenario is sampled by [method _flush_measure] instead.
	var rebuild_us: int = _tool.rebuild_total_us
	if rebuild_us != _last_rebuild_us:
		_rebuild_rows.append(rebuild_us - _last_rebuild_us)
		_last_rebuild_us = rebuild_us


# Samples the cursor mesh installs once. An install that lands in the last frame
# of a scenario is sampled by [method _flush_measure].
func _sample_cursor() -> void:
	var id := _cursor_mesh_id()
	if id != _last_cursor_mesh:
		_last_cursor_mesh = id
		if id != 0:
			_cursor_installs += 1


# Samples the tail of a scenario. This node processes before the tool, so the
# last rebuild and the last install of a measured frame are read here.
func _flush_measure() -> void:
	_sample_cursor()
	var rebuild_us: int = _tool.rebuild_total_us
	if rebuild_us != _last_rebuild_us:
		_rebuild_rows.append(rebuild_us - _last_rebuild_us)
		_last_rebuild_us = rebuild_us


# --- One case -----------------------------------------------------------------

func _run(spec: Dictionary) -> void:
	await _prepare(spec)
	step("Given the %s fixture at radius %d, symmetry %d, selection %s" % [
		spec["name"], spec["radius"], spec["axes"], str(spec["selection"]),
	], func():
		expect(_frame.count() > 0, "the fixture holds voxels")
		expect(_tool.is_processing(), "the tool processes its frames")
		print("MEASURE sculpt_preview %s env: headless=%s engine=%s viewport=%s cells=%d chunks=%d build_us=%d settle_us=%d process=%s cursor_parent=%s" % [
			spec["name"], str(DisplayServer.get_name() == "headless"),
			Engine.get_version_info()["string"], str(_viewport.size),
			_fixture_cells, _fixture_chunks, _fixture_us, _settle_us,
			str(_tool.is_processing()), str(_cursor.get_parent() != null),
		])
	)
	var cold := await _scenario_cold()
	_print_row(spec, "cold_hover", cold)
	var same := await _scenario_same()
	_print_row(spec, "same_cell", same)
	var sweep := await _scenario_sweep()
	_print_row(spec, "changed_cell", sweep)
	var color := {}
	var geometry := {}
	if spec["full"]:
		color = await _scenario_color()
		_print_row(spec, "color_only", color)
		geometry = await _scenario_geometry()
		_print_row(spec, "geometry_only", geometry)
	step("Then the hover preview follows the flow without a repeated submit", func():
		expect(int(cold["cells"]) > 0, "the first hover outlines support voxels")
		expect(int(cold["installs"]) >= 1, "the first hover installs a cursor mesh")
		expect(int(same["rebuilds"]) >= 1, "a same-cell motion marks the preview dirty")
		expect(int(same["submits"]) == 0, "a repeated identical set reaches no mesh build")
		expect(int(sweep["submits"]) >= 1, "a changed cell submits a new set")
		if spec["full"]:
			expect(int(color["rebuilds"]) == 0, "a color-only change needs no preview rebuild")
			expect(int(color["submits"]) == 0, "a color-only change submits no geometry")
			expect(not color["mesh_changed"], "a color-only change installs no new mesh")
			expect(int(geometry["submits"]) >= 1, "a geometry change submits a new set")
	)
	_snapshots[spec["name"]] = {
		"cold": cold.get("mesh", {}),
		"changed": sweep.get("mesh", {}),
		"cells": cold.get("digest", 0),
	}


# --- Scenarios ----------------------------------------------------------------

# The first hover after the tool entry and the first settle. It pays the cold fit
# and the cold sample map, and it shows the install latency of the first preview.
func _scenario_cold() -> Dictionary:
	var pos := _screen_of(_mid_cell())
	_tool.reset_probe()
	_reset_frame_stats()
	var before_mesh := _cursor_mesh_id()
	_begin_measure()
	var started := Time.get_ticks_usec()
	_hover(pos)
	var input_us := Time.get_ticks_usec() - started
	var visible_us := 0
	var visible_frames := 0
	for index in INSTALL_FRAMES:
		await get_tree().process_frame
		if _cursor_mesh_id() != before_mesh and _cursor.is_settled():
			visible_us = Time.get_ticks_usec() - started
			visible_frames = index + 1
			break
	_end_measure()
	return _row(1, [input_us], [input_us], [input_us], [input_us], [input_us], {
		"visible_us": visible_us, "visible_frames": visible_frames,
		"mesh_changed": _cursor_mesh_id() != before_mesh,
		"mesh": _tool.mesh_snapshot(), "hit": _pick_target(),
	})


# Repeated no-button motions at one settled cell. The cell, the frame, and the
# preview set stay the same, so the mesh layer drops every request.
func _scenario_same() -> Dictionary:
	var pos := _screen_of(_mid_cell())
	await _settle_all()
	_tool.reset_probe()
	_reset_frame_stats()
	var before_mesh := _cursor_mesh_id()
	_begin_measure()
	var inputs: Array[int] = []
	var picks: Array[int] = []
	var fits: Array[int] = []
	var visuals: Array[int] = []
	var hovers: Array[int] = []
	for index in SAME_EVENTS:
		var pick_before: int = _tool.pick_total_us
		var fit_before: int = _tool.fit_us
		var visual_before: int = _tool.visual_total_us
		var hover_before: int = _tool.hover_frame_us
		var started := Time.get_ticks_usec()
		_hover(pos)
		inputs.append(Time.get_ticks_usec() - started)
		picks.append(_tool.pick_total_us - pick_before)
		fits.append(_tool.fit_us - fit_before)
		visuals.append(_tool.visual_total_us - visual_before)
		hovers.append(_tool.hover_frame_us - hover_before)
		await get_tree().process_frame
	_end_measure()
	return _row(SAME_EVENTS, inputs, picks, fits, visuals, hovers, {
		"mesh_changed": _cursor_mesh_id() != before_mesh,
		"mesh": _tool.mesh_snapshot(), "hit": _pick_target(),
	})


# No-button motions over changing cells. The model does not change, so this
# separates the hover preview cost from the renderer cost. The last event is
# handled alone, so its install latency is measured on its own.
func _scenario_sweep() -> Dictionary:
	await _settle_all()
	_tool.reset_probe()
	_reset_frame_stats()
	var before_mesh := _cursor_mesh_id()
	_begin_measure()
	var inputs: Array[int] = []
	var picks: Array[int] = []
	var fits: Array[int] = []
	var visuals: Array[int] = []
	var hovers: Array[int] = []
	var targets := {}
	var last_started := 0
	var mesh_before_last := before_mesh
	var started := Time.get_ticks_usec()
	for index in _path.size():
		var cell: Vector3i = _path[index]
		if index == _path.size() - 1:
			mesh_before_last = _cursor_mesh_id()
		var pick_before: int = _tool.pick_total_us
		var fit_before: int = _tool.fit_us
		var visual_before: int = _tool.visual_total_us
		var hover_before: int = _tool.hover_frame_us
		last_started = Time.get_ticks_usec()
		_hover(_screen_of(cell))
		inputs.append(Time.get_ticks_usec() - last_started)
		picks.append(_tool.pick_total_us - pick_before)
		fits.append(_tool.fit_us - fit_before)
		visuals.append(_tool.visual_total_us - visual_before)
		hovers.append(_tool.hover_frame_us - hover_before)
		targets[_pick_target()] = true
		await get_tree().process_frame
	var span_us := Time.get_ticks_usec() - started
	# The last set installs after the last event, so its install latency starts
	# at that event.
	var visible_us := 0
	var visible_frames := 0
	for index in INSTALL_FRAMES:
		await get_tree().process_frame
		if _cursor_mesh_id() != mesh_before_last and _cursor.is_settled():
			visible_us = Time.get_ticks_usec() - last_started
			visible_frames = index + 1
			break
	_end_measure()
	return _row(_path.size(), inputs, picks, fits, visuals, hovers, {
		"visible_us": visible_us, "visible_frames": visible_frames, "span_us": span_us,
		"mesh_changed": _cursor_mesh_id() != before_mesh,
		"install_frames": visible_frames,
		"hits": targets.size(), "mesh": _tool.mesh_snapshot(), "hit": _pick_target(),
	})


# A material-only change on a settled hover. The preview geometry cannot change,
# so every cost in this scenario is wasted work.
func _scenario_color() -> Dictionary:
	await _settle_all()
	_tool.reset_probe()
	_reset_frame_stats()
	var before: Dictionary = _tool.mesh_snapshot()
	_begin_measure()
	var started := Time.get_ticks_usec()
	State.current_color = COLOR_B if State.current_color != COLOR_B else COLOR_A
	State.color_changed.emit(State.current_color)
	var pending_us := Time.get_ticks_usec() - started
	var rebuild_frames := 0
	for index in INSTALL_FRAMES:
		await get_tree().process_frame
		if _tool.rebuild_calls > 0:
			rebuild_frames = index + 1
			break
	await _settle_cursor()
	var visible_us := Time.get_ticks_usec() - started
	var after: Dictionary = _tool.mesh_snapshot()
	_end_measure()
	return _row(1, [pending_us], [0], [0], [0], [0], {
		"visible_us": visible_us, "visible_frames": rebuild_frames,
		"mesh_changed": after["id"] != before["id"],
		"mesh_before": before, "mesh": after, "hit": _pick_target(),
	})


# A geometry change on a settled hover. The hover returns to the middle cell
# first. One voxel then appears above that column, so the fit, the sample map,
# and the cell set all change.
func _scenario_geometry() -> Dictionary:
	var cell := _mid_cell()
	_hover(_screen_of(cell))
	await _settle_all()
	_tool.reset_probe()
	_reset_frame_stats()
	var before: Dictionary = _tool.mesh_snapshot()
	_begin_measure()
	var started := Time.get_ticks_usec()
	_frame.set_cell(Vector3i(cell.x, cell.y + 1, cell.z), VoxelFrame.material(Color.WHITE))
	sync_viewport()
	var edit_us := Time.get_ticks_usec() - started
	var visible_frames := 0
	for index in INSTALL_FRAMES:
		await get_tree().process_frame
		if _cursor_mesh_id() != before["id"] and _cursor.is_settled():
			visible_frames = index + 1
			break
		if index >= 3 and _tool.rebuild_calls > 0 and _cursor.is_settled():
			# The rebuild landed without a new mesh. Keep the frame count.
			visible_frames = index + 1
			break
	var visible_us := Time.get_ticks_usec() - started
	var after: Dictionary = _tool.mesh_snapshot()
	_end_measure()
	return _row(1, [edit_us], [0], [0], [0], [0], {
		"visible_us": visible_us, "visible_frames": visible_frames,
		"mesh_changed": after["id"] != before["id"],
		"mesh_before": before, "mesh": after, "hit": _pick_target(),
	})


# --- Fixture and setup --------------------------------------------------------

func _prepare(spec: Dictionary) -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = int(spec["axes"])
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.current_color = COLOR_A
	State.is_playing = false
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	_frame = State.get_current_voxel_frame()
	var fixture_started := Time.get_ticks_usec()
	_build_fixture(bool(spec["mixed"]))
	_fixture_cells = _frame.count()
	_fixture_chunks = _frame.chunks.size()
	_fixture_us = Time.get_ticks_usec() - fixture_started
	_settings.tool = _settings.Tools.GROW
	_settings.grow_mode = _settings.GrowMode.ADD
	_settings.radius = int(spec["radius"])
	_settings.falloff = 0.0
	_settings.strength = 1.0
	_path = _build_path()
	if spec["selection"]:
		State.selection.from_box(SELECTION_MIN, SELECTION_MAX)
		State.selection_changed.emit()
	_install_tool()
	_viewport.get_parent().stretch = false
	_viewport.size = VIEWPORT_SIZE
	sync_viewport()
	camera_rig().is_orthogonal = true
	camera_rig().center_on(_frame.get_bounds())
	camera_rig().set_view("top")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	var settle_started := Time.get_ticks_usec()
	await _settle_all()
	_settle_us = Time.get_ticks_usec() - settle_started


# Builds the ramp through the batch write. The surface rises one layer every four
# cells along the x and z diagonal, so a fitted plane is never cardinal. The
# body is solid under the surface. The material split is the only difference of
# the mixed case. No random source is used.
func _build_fixture(mixed: bool) -> void:
	var changes := {}
	var material_a := VoxelFrame.material(Color.from_rgba8(90, 160, 220))
	var material_b := VoxelFrame.material(Color.from_rgba8(220, 120, 90))
	for x in range(-HALF, HALF + 1):
		for z in range(-HALF, HALF + 1):
			var top := _height(x, z)
			var material := material_a
			if mixed and posmod(x, 8) < 4:
				material = material_b
			for y in range(top - BODY + 1, top + 1):
				changes[Vector3i(x, y, z)] = material
	_frame.set_cells(changes)


# The deterministic surface height of one column.
func _height(x: int, z: int) -> int:
	return clampi(int(round(float(x + z) / float(SLOPE_STEP))), -3, 3)


# The hover path: a deterministic row of surface cells around the middle. The
# cells change the fitted plane as well as the footprint.
func _build_path() -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var span := (SWEEP_EVENTS - 1) * SWEEP_STEP
	var x0 := -span / 2
	for index in SWEEP_EVENTS:
		var x := x0 + index * SWEEP_STEP
		var z := 6 if index % 2 == 0 else -6
		cells.append(Vector3i(x, _height(x, z), z))
	return cells


func _mid_cell() -> Vector3i:
	return _path[_path.size() / 2]


func _install_tool() -> void:
	var sculpt := plugin("SculptPlugin")
	# The plugin's own tool must not receive input, so it stays out of the tree.
	activate_tool("sculpt")
	sculpt.activate_tool()
	sculpt.deactivate_tool()
	_tool = preload("res://plugins/Sculpt/SculptTool.tscn").instantiate()
	_tool.set_script(ProbeScript)
	# `set_script` replaces the script instance. Reassign the shared settings when
	# the replacement did not run the tool initializer.
	if _tool._settings == null:
		_tool._settings = _settings
	sculpt.add_editor_node(_tool)
	_tool.bind_cursor()
	_cursor = _tool.get_node("Cursor")
	_viewport = editor_viewport()
	_renderer = viewport_scene().get_node("VoxelRenderer")


func _cleanup_test() -> void:
	_measuring = false
	if is_instance_valid(_tool):
		if _tool._edit != null:
			_tool.finish_on_switch()
		while _tool._busy():
			await get_tree().process_frame
		await _settle_cursor()
		while not _renderer.is_settled():
			await get_tree().process_frame
		plugin("SculptPlugin").remove_editor_node(_tool)
		_tool.free()
	_tool = null
	_cursor = null
	_frame = null
	_path = []
	_snapshots = {}
	_rebuild_rows = []
	# Restore the plugin's own tool, so the editor keeps a sculpt tool.
	var sculpt := plugin("SculptPlugin")
	if sculpt != null:
		sculpt.activate_tool()
		await get_tree().process_frame


# --- Frame sampling -----------------------------------------------------------

func _begin_measure() -> void:
	_last_frame_us = Time.get_ticks_usec()
	_longest_frame_us = 0
	_frames = 0
	_cursor_installs = 0
	_last_cursor_mesh = _cursor_mesh_id()
	_last_rebuild_us = _tool.rebuild_total_us
	_rebuild_rows = []
	_measuring = true


func _end_measure() -> void:
	_measuring = false


func _reset_frame_stats() -> void:
	_last_frame_us = Time.get_ticks_usec()
	_longest_frame_us = 0
	_frames = 0


func _cursor_mesh_id() -> int:
	if _cursor == null or _cursor.mesh == null:
		return 0
	return _cursor.mesh.get_instance_id()


func _pick_target() -> Vector3i:
	if _tool._last_pick == null:
		return VoxelPicking.NONE
	return _tool._last_pick.target


# --- Input and settling -------------------------------------------------------

func _hover(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	_viewport.push_input(event)


func _screen_of(cell: Vector3i) -> Vector2:
	return camera_rig().unproject_position(Vector3(cell))


func _settle_tool() -> void:
	while _tool._busy():
		await get_tree().process_frame


func _settle_cursor() -> void:
	while not _cursor.is_settled():
		await get_tree().process_frame


func _settle_all() -> void:
	# Two frames let a pending preview rebuild run and let the cursor start.
	for _index in 2:
		await get_tree().process_frame
	await _settle_tool()
	await _settle_cursor()
	while not _renderer.is_settled():
		await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw


# --- Reporting ----------------------------------------------------------------

func _row(events: int, inputs: Array, picks: Array, fits: Array, visuals: Array, hovers: Array, extra: Dictionary) -> Dictionary:
	_flush_measure()
	var row: Dictionary = _tool.counters()
	row["installs"] = _cursor_installs
	row["events"] = events
	row["input_mean_us"] = _mean(inputs)
	row["input_med_us"] = _median(inputs)
	row["input_max_us"] = _max(inputs)
	row["pick_med_us"] = _median(picks)
	row["fit_med_us"] = _median(fits)
	row["visual_med_us"] = _median(visuals)
	row["hover_med_us"] = _median(hovers)
	row["rebuild_mean_us"] = _mean(_rebuild_rows)
	row["rebuild_med_us"] = _median(_rebuild_rows)
	row["rebuild_max_us"] = _max(_rebuild_rows)
	row["rebuild_frames"] = _rebuild_rows.size()
	row["gap_us"] = _longest_frame_us
	row["frames"] = _frames
	for key in extra:
		row[key] = extra[key]
	return row


func _print_row(spec: Dictionary, scenario: String, row: Dictionary) -> void:
	var mesh: Dictionary = row.get("mesh", {})
	print("MEASURE sculpt_preview %s %s_event: events=%d hit=%s input_mean_us=%d input_med_us=%d input_max_us=%d pick_med_us=%d fit_med_us=%d visual_med_us=%d hover_med_us=%d pick_calls=%d fit_calls=%d hover_hits=%d hover_misses=%d" % [
		spec["name"], scenario, row["events"], str(row.get("hit", VoxelPicking.NONE)),
		row["input_mean_us"], row["input_med_us"], row["input_max_us"],
		row["pick_med_us"], row["fit_med_us"], row["visual_med_us"], row["hover_med_us"],
		row["pick_calls"], row["fit_calls"], row["hover_hits"], row["hover_misses"],
	])
	print("MEASURE sculpt_preview %s %s_frame: rebuilds=%d rebuild_frames=%d rebuild_us=%d rebuild_mean_us=%d rebuild_med_us=%d rebuild_max_us=%d dirty_frames=%d deferred_frames=%d sample_maps=%d sample_us=%d cells_calls=%d cells_us=%d set_calls=%d set_us=%d submits=%d dedupe=%d debounced=%d cache_hits=%d fit_us=%d hover_us=%d visual_us=%d" % [
		spec["name"], scenario, row["rebuilds"], row["rebuild_frames"], row["rebuild_us"],
		row["rebuild_mean_us"], row["rebuild_med_us"], row["rebuild_max_us"],
		row["dirty_frames"], row["deferred_frames"], row["sample_maps"], row["sample_us"],
		row["cells_calls"], row["cells_us"], row["set_calls"], row["set_us"],
		row["submits"], row["dedupe"], row["debounced"], row["cache_hits"],
		row["fit_us"], row["hover_us"], row["visual_us"],
	])
	print("MEASURE sculpt_preview %s %s_mesh: installs=%d mesh_changed=%s visible_us=%d visible_frames=%d cells=%d digest=%d surfaces=%d vertices=%d aabb=%s gap_us=%d frames=%d span_us=%d" % [
		spec["name"], scenario, row.get("installs", 0), str(row.get("mesh_changed", false)),
		row.get("visible_us", 0), row.get("visible_frames", 0),
		row["cells"], row["digest"], mesh.get("surfaces", 0), mesh.get("vertices", 0),
		str(mesh.get("aabb", AABB())), row["gap_us"], row["frames"], row.get("span_us", 0),
	])


func _mean(values: Array) -> int:
	if values.is_empty():
		return 0
	var total := 0
	for value in values:
		total += value
	return total / values.size()


func _median(values: Array) -> int:
	if values.is_empty():
		return 0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _max(values: Array) -> int:
	var best := 0
	for value in values:
		best = maxi(best, value)
	return best
