extends "res://tests/test.gd"

# A rendered-latency benchmark for the spray can.
#
# The benchmark drives the real Main scene viewport with real mouse events and a
# real windowed Vulkan renderer. The fixture construction and the first renderer
# settle stay outside every timed region.
#
#   godot --path . --screen 1 res://tests/benchmarks/spray_latency.tscn
#   godot --path . --screen 1 res://tests/benchmarks/spray_latency.tscn -- dense32 plate128
#
# The benchmark measures four things a warmed sampler A/B cannot see:
#
#   * the full input event through the viewport, not a warmed private helper,
#   * the fresh sample that every changed brush center pays,
#   * the visible model surface installs and the visible preview installs that
#     land while the pointer still moves,
#   * the frame gap, the frame count, and the pending surface backlog.
#
# A failing drag check is the reproduction: while the pointer keeps moving, the
# model surface and the spray preview do not install, so the artist sees only the
# Rendering job until the release.

const ProbeScript := preload("./spray_latency_tool.gd")
const PreviewProbeScript := preload("./spray_latency_preview.gd")
## The production spray tool scene. Its authored exported values are the
## configuration every measured event must use.
const SPRAY_SCENE := "res://plugins/paint/SprayTool.tscn"
const SEED := 20261021
const VIEWPORT_SIZE := Vector2i(800, 500)
# The number of held motions in one drag.
const DRAG_MOTIONS := 48
# The number of still frames in the middle of a drag. The button stays down.
const HOLD_FRAMES := 20
# The number of repeated same-cell hover events.
const SAME_EVENTS := 16
# The number of no-button hover events over changing cells.
const SWEEP_EVENTS := 32
# The number of quick press and release pairs.
const RAPID_CLICKS := 6
# The number of frames between two events of the coarse-cadence scenarios.
const SPACED_FRAMES := 4
# The number of sparse voxels of the wide-bounds fixture.
const SPARSE_VOXELS := 48

# The fixture and settings of one measured scenario. The default settings are the
# spray can defaults: spot diameter 1, radius 4, speed 8.
const SPECS := [
	{"name": "dense16", "kind": "block", "size": 16, "spot": 1, "radius": 4, "speed": 8},
	{"name": "dense32", "kind": "block", "size": 32, "spot": 1, "radius": 4, "speed": 8},
	{"name": "dense64", "kind": "block", "size": 64, "spot": 1, "radius": 4, "speed": 8},
	{"name": "plate32", "kind": "plate", "size": 32, "spot": 1, "radius": 4, "speed": 8},
	{"name": "plate128", "kind": "plate", "size": 128, "spot": 1, "radius": 4, "speed": 8},
	{"name": "plate256", "kind": "plate", "size": 256, "spot": 1, "radius": 4, "speed": 8},
	{"name": "sparse_wide", "kind": "sparse", "size": 128, "spot": 1, "radius": 4, "speed": 8},
	{"name": "moderate_block", "kind": "block", "size": 32, "spot": 4, "radius": 8, "speed": 16},
	{"name": "moderate_plate", "kind": "plate", "size": 128, "spot": 4, "radius": 8, "speed": 16},
	{"name": "wide_block", "kind": "block", "size": 32, "spot": 8, "radius": 8, "speed": 16},
]

var _settings := preload("res://plugins/paint/settings.tres")

var _tool
var _cursor
var _frame: VoxelFrame
var _renderer: VoxelRenderer
var _viewport: SubViewport
var _path_pool: Array[Vector3i] = []
var _watch_chunks := {}
var _fixture_us := 0
var _settle_us := 0
var _paint_index := 0

# The frame and install counters. `_process` fills them while `_measuring`.
var _measuring := false
var _last_frame_us := 0
var _longest_frame_us := 0
var _frames := 0
var _backlog := 0
var _displayed := {}
var _installed_locations := {}
var _model_installs := 0
var _built_keys := {}
var _built_base := 0
var _labels := {}
var _activity := ""
# The number of motions that really changed a watched chunk's surface identity,
# measured from its own key before and after the input event. It is the honest
# denominator: a repeated write of the same material changes nothing, and a
# coalesced rebuild removes a build that a per-motion count would have shown.
var _dirty_motions := 0
var _frames_since_install := 0
var _max_install_gap := 0
var _frames_with_install := 0
var _dirty_since_install := false


func _ready() -> void:
	timeout = 120.0
	for spec in SPECS:
		test("the spray drag stays visible at %s" % spec["name"], func(): await _run(spec), spec["name"])


func _process(_delta: float) -> void:
	if not _measuring:
		return
	var now := Time.get_ticks_usec()
	_longest_frame_us = maxi(_longest_frame_us, now - _last_frame_us)
	_last_frame_us = now
	_frames += 1
	var installed := _sample_renderer()
	if installed:
		_frames_with_install += 1
		# The gap is measured only while the model stayed dirty, so a still hold
		# after the last motion never counts as a stall.
		if _dirty_since_install:
			_max_install_gap = maxi(_max_install_gap, _frames_since_install)
		_frames_since_install = 0
		_dirty_since_install = false
	else:
		_frames_since_install += 1
	_sample_operations()


# --- Scenario driver ---------------------------------------------------------

func _run(spec: Dictionary) -> void:
	await _prepare(spec)
	step("Given the %s fixture at spot %d, radius %d, speed %d" % [
		spec["name"], spec["spot"], spec["radius"], spec["speed"],
	], func():
		expect(_frame.count() > 0, "the fixture holds voxels")
		expect(_path_pool.size() >= DRAG_MOTIONS, "the fixture offers a movement path")
		# The cursor runs the values the production scene authors. A probe script
		# replacement resets exported properties, so this fails if the benchmark
		# silently measures a script default instead of the authored setup.
		var authored_coalesce = _scene_export("Cursor", "coalesce_requests")
		var authored_symmetry = _scene_export("Cursor", "apply_edit_symmetry")
		expect(_cursor.coalesce_requests == authored_coalesce, "the cursor keeps the request coalescing the production scene authors")
		expect(_cursor.apply_edit_symmetry == authored_symmetry, "the cursor keeps the edit symmetry the production scene authors")
		print("MEASURE spray_latency %s probe_setup: coalesce_requests=%s authored=%s apply_edit_symmetry=%s authored=%s" % [
			spec["name"], str(_cursor.coalesce_requests), str(authored_coalesce),
			str(_cursor.apply_edit_symmetry), str(authored_symmetry),
		])
		print("MEASURE spray_latency %s fixture: cells=%d chunks=%d bounds=%s build_us=%d settle_us=%d" % [
			spec["name"], _frame.count(), _frame.chunks.size(), str(_frame.get_bounds()), _fixture_us, _settle_us,
		])
	)
	var cold := await _scenario_cold_hover()
	_print_cold(spec, cold)
	var same := await _scenario_same_hover()
	_print_same(spec, same)
	var sweep := await _scenario_hover_sweep()
	_print_sweep(spec, sweep)
	var drag := await _scenario_drag(spec)
	_print_drag(spec, drag)
	var click := await _scenario_click()
	_print_click(spec, click)
	var rapid := await _scenario_rapid_click()
	_print_rapid(spec, rapid)
	var sweep_spaced := await _scenario_sweep_spaced()
	_print_sweep_spaced(spec, sweep_spaced)
	var drag_spaced := await _scenario_drag_spaced(spec)
	_print_drag_spaced(spec, drag_spaced)
	step("Then the held drag shows the spray while the pointer still moves", func():
		# The denominator is measured from the model, not inferred from builds: a
		# repeated write of the same material changes nothing, and a coalesced
		# rebuild removes a build that a build count would have shown.
		expect(int(drag["dirty_motions"]) > 0, "the drag really changes the watched chunks")
		expect(int(drag["model_installs"]) >= int(drag["dirty_motions"]) / 4, "a visible surface installs at least every fourth changed motion")
		expect(int(drag["install_gap_frames"]) > 0 and int(drag["install_gap_frames"]) <= 12, "a visible surface lands within twelve frames while the model stays dirty")
		expect(int(drag["preview_installs"]) > 0, "the held drag installs an intermediate visible spray preview")
		expect(int(drag["samples"]) >= DRAG_MOTIONS / 2, "every changed brush center pays a fresh sample")
	)


# --- Scenarios ---------------------------------------------------------------

# The first hover after a tool entry and an empty shape cache. It shows the cold
# sample, the cold request, and the first visible preview install.
func _scenario_cold_hover() -> Dictionary:
	var pos := _screen_of(_middle_cell())
	_tool.clear_shape_caches()
	_tool._invalidate_batch()
	_tool.reset_probe()
	_reset_frame_stats()
	var before_mesh: int = _cursor.mesh_id()
	_begin_measure()
	var started := Time.get_ticks_usec()
	_hover(pos)
	var input_us := Time.get_ticks_usec() - started
	var pick_us: int = _tool.pick_us
	var sample_us: int = _tool.sample_us
	var request_us: int = _tool.show_us
	var preview_request_us: int = _cursor.request_us
	var visible_us := 0
	var visible_frames := 0
	for index in 240:
		await get_tree().process_frame
		if _cursor.mesh_id() != before_mesh and _cursor.is_settled():
			visible_us = Time.get_ticks_usec() - started
			visible_frames = index + 1
			break
	_end_measure()
	return {
		"input_us": input_us, "pick_us": pick_us, "sample_us": sample_us,
		"request_us": request_us, "preview_request_us": preview_request_us,
		"preview_material_us": _cursor.material_us, "preview_show_us": _cursor.show_us,
		"visible_us": visible_us, "visible_frames": visible_frames,
		"cells": _tool.sample_cells, "installs": 1 if _cursor.mesh_id() != before_mesh else 0,
		"discards": _cursor.discards, "install_us": _cursor.install_max_us,
		"gap_us": _longest_frame_us,
	}


# Repeated hover events on one cell. The batch holds, so no sample runs.
func _scenario_same_hover() -> Dictionary:
	var pos := _screen_of(_middle_cell())
	_hover(pos)
	await _settle_all()
	_tool.reset_probe()
	_reset_frame_stats()
	_begin_measure()
	var inputs: Array[int] = []
	for index in SAME_EVENTS:
		var started := Time.get_ticks_usec()
		_hover(pos)
		inputs.append(Time.get_ticks_usec() - started)
		await get_tree().process_frame
	_end_measure()
	return {
		"events": SAME_EVENTS, "input_us": _median(inputs), "input_max_us": _max(inputs),
		"samples": _tool.sample_calls, "requests": _cursor.request_calls,
		"installs": _cursor.installs, "discards": _cursor.discards,
		"gap_us": _longest_frame_us, "frames": _frames,
	}


# A no-button hover over changing cells. The batch changes every event, but the
# model does not change. This separates the preview path from the renderer path.
func _scenario_hover_sweep() -> Dictionary:
	var cells := _path_cells(SWEEP_EVENTS)
	_watch_chunks = _watch_around(cells, 5)
	_tool.reset_probe()
	_reset_frame_stats()
	_begin_measure()
	var inputs: Array[int] = []
	var samples: Array[int] = []
	var started := Time.get_ticks_usec()
	for cell in cells:
		var event_started := Time.get_ticks_usec()
		_hover(_screen_of(cell))
		inputs.append(Time.get_ticks_usec() - event_started)
		samples.append(_tool.sample_us)
		await get_tree().process_frame
	var span_us := Time.get_ticks_usec() - started
	_end_measure()
	return {
		"events": cells.size(), "input_us": _median(inputs), "input_max_us": _max(inputs),
		"sample_us": _median(samples), "samples": _tool.sample_calls,
		"requests": _cursor.request_calls, "installs": _cursor.installs, "discards": _cursor.discards,
		"model_installs": _model_installs, "chunks_installed": _installed_locations.size(),
		"builds": _builds(), "backlog": _backlog,
		"gap_us": _longest_frame_us, "frames": _frames, "span_us": span_us,
	}


# A held drag: press, held motions, a still hold with the button down, held
# motions, release, settle. The install counters of each phase are separate.
func _scenario_drag(spec: Dictionary) -> Dictionary:
	var cells := _path_cells(DRAG_MOTIONS)
	var reach := int(spec["radius"]) + int(spec["spot"])
	_watch_chunks = _watch_around(cells, reach)
	await _fresh_paint()
	_press(_screen_of(cells[0]))
	await _settle_all()
	_tool.reset_probe()
	_reset_frame_stats()
	_begin_measure()
	var started := Time.get_ticks_usec()
	var half := DRAG_MOTIONS / 2
	var inputs: Array[int] = []
	var samples: Array[int] = []
	for index in half:
		var before := _watch_key_snapshot()
		var event_started := Time.get_ticks_usec()
		_motion(_screen_of(cells[index]))
		inputs.append(Time.get_ticks_usec() - event_started)
		if _snapshot_changed(before):
			_dirty_motions += 1
			_dirty_since_install = true
		samples.append(_tool.sample_us)
		await get_tree().process_frame
	var phase_a := _phase_counts()
	# The pointer holds still while the button stays down. No new batch and no new
	# revision arrives, so this phase isolates the backlog from the motion churn.
	for index in HOLD_FRAMES:
		await get_tree().process_frame
	var phase_b := _phase_counts()
	# The still hold is a deliberate pause, not a responsiveness window, so the
	# dirty install gap restarts with the second motion phase.
	_frames_since_install = 0
	_dirty_since_install = false
	for index in range(half, DRAG_MOTIONS):
		var before := _watch_key_snapshot()
		var event_started := Time.get_ticks_usec()
		_motion(_screen_of(cells[index]))
		inputs.append(Time.get_ticks_usec() - event_started)
		if _snapshot_changed(before):
			_dirty_motions += 1
			_dirty_since_install = true
		samples.append(_tool.sample_us)
		await get_tree().process_frame
	var phase_c := _phase_counts()
	var installed_at_release := _installed_locations.size()
	var backlog_at_release := _renderer._pending_surface_keys.size()
	var labels_at_release := _operation_labels()
	var activity_at_release := _activity
	var release_started := Time.get_ticks_usec()
	_release(_screen_of(cells[DRAG_MOTIONS - 1]))
	await _settle_all()
	var release_us := Time.get_ticks_usec() - release_started
	_end_measure()
	return {
		"motions": DRAG_MOTIONS, "hold_frames": HOLD_FRAMES,
		"dirty_motions": _dirty_motions, "install_gap_frames": _max_install_gap,
		"frames_with_install": _frames_with_install,
		"input_us": _median(inputs), "input_max_us": _max(inputs),
		"sample_us": _median(samples), "sample_max_us": _max(samples),
		"samples": _tool.sample_calls,
		"requests": _cursor.request_calls, "preview_request_us": _cursor.request_us,
		"preview_material_us": _cursor.material_us, "preview_show_us": _cursor.show_us,
		"preview_install_us": _cursor.install_max_us,
		"model_installs": phase_a["model"] + (phase_c["model"] - phase_b["model"]),
		"preview_installs": phase_a["preview"] + (phase_c["preview"] - phase_b["preview"]),
		"preview_discards": phase_a["discards"] + (phase_c["discards"] - phase_b["discards"]),
		"hold_model": phase_b["model"] - phase_a["model"],
		"hold_preview": phase_b["preview"] - phase_a["preview"],
		"hold_discards": phase_b["discards"] - phase_a["discards"],
		"chunks_watched": _watch_chunks.size(), "chunks_installed": _installed_locations.size(),
		"chunks_installed_at_release": installed_at_release,
		"builds": _builds(), "backlog": _backlog, "backlog_at_release": backlog_at_release,
		"labels": labels_at_release, "activity": activity_at_release,
		"gap_us": _longest_frame_us, "frames": _frames, "span_us": Time.get_ticks_usec() - started,
		"release_us": release_us,
	}


# One press and one release with a settle between. The ordinary one-off click.
func _scenario_click() -> Dictionary:
	var cell := _middle_cell()
	var one: Array[Vector3i] = [cell]
	_watch_chunks = _watch_around(one, 5)
	await _fresh_paint()
	_tool.reset_probe()
	_reset_frame_stats()
	_begin_measure()
	var started := Time.get_ticks_usec()
	_press(_screen_of(cell))
	var input_us := Time.get_ticks_usec() - started
	await _settle_tool()
	var edit_us := Time.get_ticks_usec() - started
	await _settle_renderer()
	var visible_us := Time.get_ticks_usec() - started
	var release_started := Time.get_ticks_usec()
	_release(_screen_of(cell))
	await _settle_all()
	var release_us := Time.get_ticks_usec() - release_started
	_end_measure()
	return {
		"input_us": input_us, "edit_us": edit_us, "visible_us": visible_us, "release_us": release_us,
		"model_installs": _model_installs, "preview_installs": _cursor.installs,
		"preview_discards": _cursor.discards, "builds": _builds(),
		"gap_us": _longest_frame_us, "frames": _frames,
	}


# Repeated quick press and release pairs. The next preview samples while the
# previous preview worker may still run. The last pair settles after the loop.
func _scenario_rapid_click() -> Dictionary:
	var cell := _middle_cell()
	var one: Array[Vector3i] = [cell]
	_watch_chunks = _watch_around(one, 5)
	await _fresh_paint()
	_tool.reset_probe()
	_reset_frame_stats()
	_begin_measure()
	var started := Time.get_ticks_usec()
	for index in RAPID_CLICKS:
		_press(_screen_of(cell))
		await get_tree().process_frame
		_release(_screen_of(cell))
		await get_tree().process_frame
	var loop_us := Time.get_ticks_usec() - started
	await _settle_all()
	var total_us := Time.get_ticks_usec() - started
	_end_measure()
	return {
		"clicks": RAPID_CLICKS, "loop_us": loop_us, "total_us": total_us,
		"samples": _tool.sample_calls, "requests": _cursor.request_calls,
		"installs": _cursor.installs, "discards": _cursor.discards,
		"model_installs": _model_installs, "builds": _builds(), "backlog": _backlog,
		"gap_us": _longest_frame_us, "frames": _frames,
	}


# --- Cadence experiments -----------------------------------------------------
#
# The same code path as the sweep and the drag, with one event every
# SPACED_FRAMES frames. The request rate is the only change. A visible install
# here and none at one event per frame proves the starvation is a request-rate
# race, not a work-volume problem.

func _scenario_sweep_spaced() -> Dictionary:
	var cells := _path_cells(SWEEP_EVENTS)
	_watch_chunks = _watch_around(cells, 5)
	_tool.reset_probe()
	_reset_frame_stats()
	_begin_measure()
	var started := Time.get_ticks_usec()
	for cell in cells:
		_hover(_screen_of(cell))
		for wait in SPACED_FRAMES:
			await get_tree().process_frame
	_end_measure()
	return {
		"events": cells.size(), "requests": _cursor.request_calls, "installs": _cursor.installs,
		"discards": _cursor.discards, "model_installs": _model_installs,
		"frames": _frames, "span_us": Time.get_ticks_usec() - started, "gap_us": _longest_frame_us,
	}


func _scenario_drag_spaced(spec: Dictionary) -> Dictionary:
	var cells := _path_cells(DRAG_MOTIONS)
	var reach := int(spec["radius"]) + int(spec["spot"])
	_watch_chunks = _watch_around(cells, reach)
	await _fresh_paint()
	_press(_screen_of(cells[0]))
	await _settle_all()
	_tool.reset_probe()
	_reset_frame_stats()
	_begin_measure()
	var started := Time.get_ticks_usec()
	for cell in cells:
		_motion(_screen_of(cell))
		for wait in SPACED_FRAMES:
			await get_tree().process_frame
	var model_during := _model_installs
	var chunks_during := _installed_locations.size()
	var preview_during: int = _cursor.installs
	var discards_during: int = _cursor.discards
	var backlog_during := _backlog
	_release(_screen_of(cells[DRAG_MOTIONS - 1]))
	await _settle_all()
	_end_measure()
	return {
		"motions": cells.size(), "model_installs": model_during, "chunks_installed": chunks_during,
		"preview_installs": preview_during, "preview_discards": discards_during,
		"builds": _builds(), "backlog": backlog_during, "frames": _frames,
		"span_us": Time.get_ticks_usec() - started, "gap_us": _longest_frame_us,
	}


# --- Fixture and setup -------------------------------------------------------

func _prepare(spec: Dictionary) -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.current_color = Color.RED
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	State.is_playing = false
	_frame = State.get_current_voxel_frame()
	var fixture_started := Time.get_ticks_usec()
	_build_fixture(spec)
	_fixture_us = Time.get_ticks_usec() - fixture_started
	_settings.spot_diameter = spec["spot"]
	_settings.spray_radius = spec["radius"]
	_settings.speed = spec["speed"]
	_path_pool = _build_path_pool(spec, DRAG_MOTIONS)
	_install_tool()
	_viewport.size = VIEWPORT_SIZE
	_viewport.get_parent().stretch = false
	sync_viewport()
	camera_rig().is_orthogonal = true
	camera_rig().center_on(_frame.get_bounds())
	camera_rig().set_view("top")
	var settle_started := Time.get_ticks_usec()
	await _settle_all()
	_settle_us = Time.get_ticks_usec() - settle_started


func _install_tool() -> void:
	var paint := plugin("PaintPlugin")
	select_toolbar_item("paint", "Spray Can")
	paint.deactivate_tool()
	_viewport = editor_viewport()
	_renderer = viewport_scene().get_node("VoxelRenderer")
	_tool = preload(SPRAY_SCENE).instantiate()
	_cursor = _tool.get_node("Cursor")
	# Replacing a node's script resets every exported property of the new script
	# instance to its script default. That would drop the values the production
	# scene authors, so the authored values are saved from the real scene and
	# restored after each replacement. The cursor coalescing is one of them, and it
	# decides the behavior this benchmark measures.
	var authored := _authored_exports(_tool)
	_tool.set_script(ProbeScript)
	_cursor.set_script(PreviewProbeScript)
	_restore_exports(authored)
	# `set_script` replaces the script instance. Reassign the shared settings when
	# the replacement did not run the tool initializer.
	if _tool._settings == null:
		_tool._paint_settings = _settings
		_tool._settings = _settings
	paint.add_editor_node(_tool)
	_tool.seed_spray(SEED)


# The Inspector-authored exported values of a node and its children, keyed by
# node then property name.
func _authored_exports(root: Node) -> Dictionary:
	var saved := {}
	for node in _subtree(root):
		var values := {}
		for property in node.get_property_list():
			var usage: int = property["usage"]
			if usage & PROPERTY_USAGE_SCRIPT_VARIABLE and usage & PROPERTY_USAGE_EDITOR:
				values[property["name"]] = node.get(property["name"])
		saved[node] = values
	return saved


func _restore_exports(saved: Dictionary) -> void:
	for node in saved:
		if not is_instance_valid(node):
			continue
		var values: Dictionary = saved[node]
		for name in values:
			node.set(name, values[name])


func _subtree(root: Node) -> Array[Node]:
	var nodes: Array[Node] = [root]
	for child in root.get_children():
		nodes.append_array(_subtree(child))
	return nodes


# The value one exported property holds in a fresh instance of the production
# scene. The benchmark compares its own cursor against this, so a refactor that
# silently resets the authored value fails instead of passing on a default.
func _scene_export(node_path: String, property: String):
	var production: Node = load(SPRAY_SCENE).instantiate()
	var value = production.get_node(node_path).get(property)
	production.free()
	return value


func _cleanup_test() -> void:
	_measuring = false
	if is_instance_valid(_tool):
		if _tool._edit != null:
			_tool.finish_on_switch()
		while _tool._job != null or not _tool._pending_centers.is_empty():
			await get_tree().process_frame
		plugin("PaintPlugin").remove_editor_node(_tool)
		_tool.free()
	_tool = null
	_cursor = null
	_frame = null
	_path_pool = []
	_watch_chunks = {}
	_displayed = {}
	_installed_locations = {}
	_labels = {}


# Build the fixture through the chunk storage. The per-cell preparation of a
# dictionary input is far too slow for a 64-cube block and is excluded from every
# timed region.
func _build_fixture(spec: Dictionary) -> void:
	var kind: String = spec["kind"]
	var size: int = spec["size"]
	var cell_material := VoxelFrame.material(Color.from_rgba8(90, 160, 220))
	if kind == "block":
		_fill_box(Vector3i.ZERO, Vector3i.ONE * (size - 1), cell_material)
	elif kind == "plate":
		_fill_box(Vector3i.ZERO, Vector3i(size - 1, 0, size - 1), cell_material)
	else:
		for index in SPARSE_VOXELS:
			var cell := _sparse_cell(size, index)
			_fill_box(cell, cell, cell_material)
	_frame.restore(_frame.chunks)


func _sparse_cell(size: int, index: int) -> Vector3i:
	var x := -size + (index * 2 * size) / SPARSE_VOXELS
	var z := -size + ((index * 13) % SPARSE_VOXELS) * (2 * size) / SPARSE_VOXELS
	return Vector3i(x, 0, z)


# Fill one world box. A chunk the box covers whole uses one bulk grid fill.
func _fill_box(min_cell: Vector3i, max_cell: Vector3i, cell_material: PackedFloat32Array) -> void:
	var chunks := _frame.chunks
	var min_chunk := VoxelFrame.chunk_position(min_cell)
	var max_chunk := VoxelFrame.chunk_position(max_cell)
	for cz in range(min_chunk.z, max_chunk.z + 1):
		for cy in range(min_chunk.y, max_chunk.y + 1):
			for cx in range(min_chunk.x, max_chunk.x + 1):
				var location := Vector3i(cx, cy, cz)
				var chunk: VoxelFrame.Chunk = chunks.get(location)
				if chunk == null:
					chunk = VoxelFrame.Chunk.new()
					chunk.location = location
					chunks[location] = chunk
				var origin := location * VoxelFrame.CHUNK_SIZE
				var lo := Vector3i(maxi(min_cell.x, origin.x), maxi(min_cell.y, origin.y), maxi(min_cell.z, origin.z)) - origin
				var hi := Vector3i(mini(max_cell.x, origin.x + 15), mini(max_cell.y, origin.y + 15), mini(max_cell.z, origin.z + 15)) - origin
				if lo.x > hi.x or lo.y > hi.y or lo.z > hi.z:
					continue
				if lo == Vector3i.ZERO and hi == Vector3i.ONE * 15:
					chunk.grid.fill(1)
					chunk.occupied_count = VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE
				else:
					var count := 0
					for lz in range(lo.z, hi.z + 1):
						for ly in range(lo.y, hi.y + 1):
							for lx in range(lo.x, hi.x + 1):
								chunk.grid[VoxelFrame.Chunk.cell_slot(Vector3i(lx, ly, lz))] = 1
								count += 1
					chunk.occupied_count = count
				chunk.materials = cell_material.duplicate()
				# Every cell of the box points at one material row, so the chunk must
				# declare its shared rows before the first single-cell write.
				chunk.shared_materials = true
				chunk.voxel_revision = 1
				chunk.bounds_dirty = false
				chunk.occupied_bounds = AABB(Vector3(origin + lo) - Vector3.ONE * 0.5, Vector3(hi - lo + Vector3i.ONE))


# The movement path: a serpentine over the fixture surface, or the sparse voxels.
func _build_path_pool(spec: Dictionary, count: int) -> Array[Vector3i]:
	var pool: Array[Vector3i] = []
	var kind: String = spec["kind"]
	var size: int = spec["size"]
	if kind == "sparse":
		for index in SPARSE_VOXELS:
			pool.append(_sparse_cell(size, index))
		return pool
	var columns := mini(size, count)
	var rows := int(ceil(float(count) / float(columns)))
	var y := size - 1 if kind == "block" else 0
	var x0 := (size - columns) / 2
	var z0 := (size - rows) / 2
	for row in rows:
		for column in columns:
			var x := x0 + (columns - 1 - column if row % 2 == 1 else column)
			pool.append(Vector3i(x, y, z0 + row))
	return pool


func _path_cells(count: int) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	if _path_pool.is_empty():
		return cells
	var start := maxi(0, (_path_pool.size() - count) / 2)
	for index in mini(count, _path_pool.size()):
		cells.append(_path_pool[(start + index) % _path_pool.size()])
	return cells


func _middle_cell() -> Vector3i:
	return _path_pool[_path_pool.size() / 2]


# Sets a fresh paint color and settles the idle work it starts. A repaint of a
# cell with the material it already holds changes nothing, so it requests no
# surface build. Every painting scenario needs a real change.
func _fresh_paint() -> void:
	_paint_index += 1
	State.current_color = Color.from_hsv(fmod(_paint_index * 0.137, 1.0), 0.8, 0.9)
	await _settle_all()


func _watch_around(cells: Array[Vector3i], reach: int) -> Dictionary:
	var watch := {}
	var offsets: Array[Vector3i] = [Vector3i.ZERO]
	offsets.append_array(VoxelFrame.DIRECTIONS)
	for cell in cells:
		for offset in offsets:
			watch[VoxelFrame.chunk_position(cell + offset * reach)] = true
	return watch


# The surface key of every watched chunk in the frame the stroke writes. A motion
# that changes one of these keys really changed the model, so it needs a rebuild.
func _watch_key_snapshot() -> Dictionary:
	var keys := {}
	var active := State.get_current_voxel_frame()
	if active == null:
		return keys
	var smooth := State.document.smooth_normals
	for location in _watch_chunks:
		keys[location] = VoxelRenderer._signature(active, location, smooth)
	return keys


func _snapshot_changed(before: Dictionary) -> bool:
	var active := State.get_current_voxel_frame()
	if active == null:
		return false
	var smooth := State.document.smooth_normals
	for location in before:
		var after := VoxelRenderer._signature(active, location, smooth)
		if not _same_key(before[location], after):
			return true
	return false


func _same_key(first: PackedInt64Array, second: PackedInt64Array) -> bool:
	return first.size() == second.size() and first == second


# --- Frame sampling ----------------------------------------------------------

func _begin_measure() -> void:
	_last_frame_us = Time.get_ticks_usec()
	_longest_frame_us = 0
	_frames = 0
	_backlog = 0
	_model_installs = 0
	_dirty_motions = 0
	_frames_since_install = 0
	_max_install_gap = 0
	_frames_with_install = 0
	_dirty_since_install = false
	_labels = {}
	_activity = ""
	# Prefill the displayed surfaces, the cursor mesh, and the built surface
	# keys, so the first sample of a scenario never reports pre-existing state
	# as new work.
	_displayed = {}
	_installed_locations = {}
	for location in _watch_chunks:
		var instance: MeshInstance3D = _renderer._chunk_instances.get(location)
		var id := 0
		if instance != null and instance.mesh != null:
			id = instance.mesh.get_instance_id()
		_displayed[location] = id
	_built_keys = {}
	for key in _renderer._surface_cache:
		_built_keys[key] = true
	for key in _renderer._surface_jobs:
		_built_keys[key] = true
	_built_base = _built_keys.size()
	_cursor.reset_probe()
	_tool.reset_probe()
	_measuring = true


func _end_measure() -> void:
	_measuring = false


func _reset_frame_stats() -> void:
	_last_frame_us = Time.get_ticks_usec()
	_longest_frame_us = 0
	_frames = 0
	_backlog = 0


func _sample_renderer() -> bool:
	_backlog = maxi(_backlog, _renderer._pending_surface_keys.size())
	for key in _renderer._surface_jobs:
		_built_keys[key] = true
	var installed := false
	for location in _watch_chunks:
		var instance: MeshInstance3D = _renderer._chunk_instances.get(location)
		var id := 0
		if instance != null and instance.mesh != null:
			id = instance.mesh.get_instance_id()
		if _displayed.get(location, 0) != id:
			_displayed[location] = id
			if id != 0:
				_model_installs += 1
				_installed_locations[location] = true
				installed = true
	return installed


func _sample_operations() -> void:
	for operation in State._operations.values():
		_labels[operation.label] = true
	_activity = _current_activity_label()


# The number of distinct chunk surface keys that a build produced since the
# measure started. A new edit bumps the chunk revision, so it also makes a new
# key. The count includes every build, even the ones no viewport ever installs.
# The use-order length is not usable here: a full surface cache evicts one entry
# per new build, so its length stops moving.
func _builds() -> int:
	for key in _renderer._surface_cache:
		_built_keys[key] = true
	for key in _renderer._surface_jobs:
		_built_keys[key] = true
	return _built_keys.size() - _built_base


func _phase_counts() -> Dictionary:
	return {"model": _model_installs, "preview": _cursor.installs, "discards": _cursor.discards, "backlog": _backlog}


func _current_activity_label() -> String:
	var operation = State.get_activity()
	if operation == null:
		return "-"
	return operation.label


func _operation_labels() -> String:
	var names: Array[String] = []
	for label in _labels:
		names.append(str(label))
	names.sort()
	return ", ".join(names) if not names.is_empty() else "-"


# --- Input and settling ------------------------------------------------------

func _press(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	_viewport.push_input(event)


func _release(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = pos
	_viewport.push_input(event)


func _motion(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	_viewport.push_input(event)


func _hover(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	_viewport.push_input(event)


func _screen_of(cell: Vector3i) -> Vector2:
	return camera_rig().unproject_position(Vector3(cell))


func _settle_tool() -> void:
	while _tool._job != null or not _tool._pending_centers.is_empty():
		await get_tree().process_frame


func _settle_renderer() -> void:
	while not _renderer.is_settled():
		await get_tree().process_frame


func _settle_cursor() -> void:
	while not _cursor.is_settled():
		await get_tree().process_frame


func _settle_all() -> void:
	await _settle_tool()
	await _settle_cursor()
	await _settle_renderer()
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw


# --- Reporting ---------------------------------------------------------------

func _print_cold(spec: Dictionary, row: Dictionary) -> void:
	print("MEASURE spray_latency %s cold_hover: input_us=%d pick_us=%d sample_us=%d tool_request_us=%d cursor_show_us=%d cursor_material_us=%d cursor_request_us=%d visible_us=%d visible_frames=%d cells=%d installs=%d discards=%d install_us=%d gap_us=%d" % [
		spec["name"], row["input_us"], row["pick_us"], row["sample_us"], row["request_us"],
		row["preview_show_us"], row["preview_material_us"], row["preview_request_us"],
		row["visible_us"], row["visible_frames"], row["cells"], row["installs"],
		row["discards"], row["install_us"], row["gap_us"],
	])


func _print_same(spec: Dictionary, row: Dictionary) -> void:
	print("MEASURE spray_latency %s same_hover: events=%d input_us=%d input_max_us=%d samples=%d requests=%d installs=%d discards=%d frames=%d gap_us=%d" % [
		spec["name"], row["events"], row["input_us"], row["input_max_us"], row["samples"],
		row["requests"], row["installs"], row["discards"], row["frames"], row["gap_us"],
	])


func _print_sweep(spec: Dictionary, row: Dictionary) -> void:
	print("MEASURE spray_latency %s hover_sweep: events=%d input_us=%d input_max_us=%d sample_us=%d samples=%d requests=%d preview_installs=%d preview_discards=%d model_installs=%d chunks_installed=%d builds=%d backlog=%d frames=%d span_us=%d gap_us=%d" % [
		spec["name"], row["events"], row["input_us"], row["input_max_us"], row["sample_us"],
		row["samples"], row["requests"], row["installs"], row["discards"], row["model_installs"],
		row["chunks_installed"], row["builds"], row["backlog"], row["frames"], row["span_us"], row["gap_us"],
	])


func _print_drag(spec: Dictionary, row: Dictionary) -> void:
	print("MEASURE spray_latency %s drag_input: motions=%d dirty_motions=%d input_us=%d input_max_us=%d sample_us=%d sample_max_us=%d samples=%d requests=%d cursor_show_us=%d cursor_material_us=%d" % [
		spec["name"], row["motions"], row["dirty_motions"], row["input_us"], row["input_max_us"],
		row["sample_us"], row["sample_max_us"], row["samples"], row["requests"],
		row["preview_show_us"], row["preview_material_us"],
	])
	print("MEASURE spray_latency %s drag_visible: model_installs=%d preview_installs=%d preview_discards=%d preview_install_us=%d chunks_installed=%d chunks_installed_at_release=%d chunks_watched=%d builds=%d backlog_max=%d backlog_at_release=%d" % [
		spec["name"], row["model_installs"], row["preview_installs"], row["preview_discards"],
		row["preview_install_us"], row["chunks_installed"], row["chunks_installed_at_release"],
		row["chunks_watched"], row["builds"], row["backlog"], row["backlog_at_release"],
	])
	print("MEASURE spray_latency %s drag_progress: dirty_motions=%d model_installs=%d frames_with_install=%d install_gap_frames=%d frames=%d" % [
		spec["name"], row["dirty_motions"], row["model_installs"], row["frames_with_install"],
		row["install_gap_frames"], row["frames"],
	])
	print("MEASURE spray_latency %s drag_hold: hold_model=%d hold_preview=%d hold_discards=%d" % [
		spec["name"], row["hold_model"], row["hold_preview"], row["hold_discards"],
	])
	print("MEASURE spray_latency %s drag_frames: frames=%d span_us=%d gap_us=%d release_us=%d labels=[%s] activity=%s" % [
		spec["name"], row["frames"], row["span_us"], row["gap_us"], row["release_us"],
		row["labels"], row["activity"],
	])


func _print_click(spec: Dictionary, row: Dictionary) -> void:
	print("MEASURE spray_latency %s click: input_us=%d edit_us=%d visible_us=%d release_us=%d model_installs=%d preview_installs=%d preview_discards=%d builds=%d frames=%d gap_us=%d" % [
		spec["name"], row["input_us"], row["edit_us"], row["visible_us"], row["release_us"],
		row["model_installs"], row["preview_installs"], row["preview_discards"], row["builds"],
		row["frames"], row["gap_us"],
	])


func _print_rapid(spec: Dictionary, row: Dictionary) -> void:
	print("MEASURE spray_latency %s rapid_click: clicks=%d loop_us=%d total_us=%d samples=%d requests=%d installs=%d discards=%d model_installs=%d builds=%d backlog=%d frames=%d gap_us=%d" % [
		spec["name"], row["clicks"], row["loop_us"], row["total_us"], row["samples"],
		row["requests"], row["installs"], row["discards"], row["model_installs"], row["builds"],
		row["backlog"], row["frames"], row["gap_us"],
	])


func _print_sweep_spaced(spec: Dictionary, row: Dictionary) -> void:
	print("MEASURE spray_latency %s sweep_spaced: events=%d requests=%d installs=%d discards=%d model_installs=%d frames=%d span_us=%d gap_us=%d" % [
		spec["name"], row["events"], row["requests"], row["installs"], row["discards"],
		row["model_installs"], row["frames"], row["span_us"], row["gap_us"],
	])


func _print_drag_spaced(spec: Dictionary, row: Dictionary) -> void:
	print("MEASURE spray_latency %s drag_spaced: motions=%d model_installs=%d chunks_installed=%d preview_installs=%d preview_discards=%d builds=%d backlog=%d frames=%d span_us=%d gap_us=%d" % [
		spec["name"], row["motions"], row["model_installs"], row["chunks_installed"],
		row["preview_installs"], row["preview_discards"], row["builds"], row["backlog"],
		row["frames"], row["span_us"], row["gap_us"],
	])


func _median(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var sorted := values.duplicate()
	sorted.sort()
	return int(sorted[sorted.size() / 2])


func _max(values: Array[int]) -> int:
	var best := 0
	for value in values:
		best = maxi(best, value)
	return best
