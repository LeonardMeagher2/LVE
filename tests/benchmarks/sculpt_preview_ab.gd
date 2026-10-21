extends "res://tests/benchmarks/sculpt_preview.gd"

# A warmed alternating same-process A/B for the sculpt hover preview.
#
# Run it directly. Keep it outside automatic suite discovery.
#
#   godot --path . --screen 1 res://tests/benchmarks/sculpt_preview_ab.tscn
#   godot --path . --screen 1 res://tests/benchmarks/sculpt_preview_ab.tscn -- changed_r4
#
# The two paths of every pair are the frozen old hover path (reference) and the
# current production hover path (candidate). The reference lives in
# `sculpt_preview_reference.gd` and stays old. The candidate follows production,
# so a production change moves the candidate and nothing else.
#
# A pair runs both paths back to back from the same settled start on the same
# cells. Two warmup pairs are discarded. Five measured pairs keep the median of
# each path. The order of a pair alternates, so neither path always runs second.
#
# The preview layer keeps one static mesh cache for the process, and a cached
# surface would serve the second path of a pair and hide its own build cost. The
# test clears that cache before each path run. The clear uses the same three
# fields the preview layer clears when its last node leaves the tree.
#
# The parity check compares the exact rebuild cells, the exact vertex array of
# the installed mesh, and its exact bounds. A digest or a count is not the proof.
#
# What this file does not do: it adds no candidate behavior. Until production
# changes, the reference and the candidate must report the same work within
# noise. A difference in the fit counters and a parity failure are the two
# signals to read.
#
# The baseline cases of `sculpt_preview.gd` stay untouched. This file overrides
# `_ready`, `_install_tool`, and `_caller_frame` only.

const ReferenceScript := preload("./sculpt_preview_reference.gd")
const SurfaceQuery := preload("./sculpt_preview_surface.gd")
const PreviewScript := preload("res://Globals/Rendering/VoxelPreview.gd")
# The pairs whose measurements are discarded.
const WARMUPS := 2
# The measured pairs per path.
const REPEATS := 5
# The changed cells of one changed-cell run.
const CHANGE_EVENTS := 6
# The generous per-case watchdog. The reference path is the slow one.
const AB_TIMEOUT := 150.0

var _reference_rows: Array = []
var _candidate_rows: Array = []
var _pairs := 0


func _ready() -> void:
	timeout = AB_TIMEOUT
	test("the two hover paths agree on a same-cell hover at radius 4", func(): await _ab_case("same_cell", 4), "same_r4")
	test("the two hover paths agree on a same-cell hover at radius 16", func(): await _ab_case("same_cell", 16), "same_r16")
	test("the two hover paths agree on a same-cell hover at radius 32", func(): await _ab_case("same_cell", 32), "same_r32")
	test("the two hover paths agree on a changed-cell hover at radius 4", func(): await _ab_case("changed_cell", 4), "changed_r4")
	test("the two hover paths agree on a changed-cell hover at radius 16", func(): await _ab_case("changed_cell", 16), "changed_r16")
	test("the two hover paths agree on a changed-cell hover at radius 32", func(): await _ab_case("changed_cell", 32), "changed_r32")
	test("the preview invalidation routes keep the exact result", func(): await _invalidation_case(4), "invalidation_r4")
	test("the radius change keeps the exact result and reports its stages", func(): await _resize_case(), "resize_r32")
	test("the frozen surface query matches production on every seeded and real query", func(): await _surface_case(), "surface_query")


# --- The A/B ------------------------------------------------------------------

func _ab_case(case_name: String, radius: int) -> void:
	var spec := {
		"name": "%s_r%d" % [case_name, radius], "radius": radius, "axes": 0,
		"selection": false, "mixed": false, "full": false,
	}
	await _prepare(spec)
	_reference_rows = []
	_candidate_rows = []
	_pairs = 0
	step("Given the ramp fixture at radius %d and %d measured pairs" % [radius, REPEATS], func():
		expect(_tool.is_processing(), "the tool processes its frames")
		expect(_tool.use_reference == false, "the shared probe starts on the production path")
		print("MEASURE sculpt_preview_ab %s env: radius=%d events=%d warmups=%d repeats=%d cells=%d chunks=%d headless=%s" % [
			spec["name"], radius, _event_cells(case_name).size(), WARMUPS, REPEATS,
			_fixture_cells, _fixture_chunks, str(DisplayServer.get_name() == "headless"),
		])
	)
	for pair in WARMUPS + REPEATS:
		var first_reference := pair % 2 == 0
		var a := await _path_run(case_name, first_reference)
		var b := await _path_run(case_name, not first_reference)
		var reference_row: Dictionary = a if first_reference else b
		var candidate_row: Dictionary = b if first_reference else a
		var parity := _exact_parity(reference_row["exact"], candidate_row["exact"])
		print("MEASURE sculpt_preview_ab %s pair=%d order=%s reference_fit_pair_us=%d candidate_fit_pair_us=%d reference_input_med_us=%d candidate_input_med_us=%d reference_rebuild_med_us=%d candidate_rebuild_med_us=%d cells_equal=%s vertices_equal=%s aabb_equal=%s cells=%d vertices=%d first_difference=%s" % [
			spec["name"], pair, "reference_first" if first_reference else "candidate_first",
			reference_row["fit_pair_us"], candidate_row["fit_pair_us"],
			reference_row["input_med_us"], candidate_row["input_med_us"],
			reference_row["rebuild_med_us"], candidate_row["rebuild_med_us"],
			str(parity["cells"]), str(parity["vertices"]), str(parity["aabb"]),
			parity["cells_first"], parity["vertices_first"], parity["first_difference"],
		])
		if pair >= WARMUPS:
			_pairs += 1
			_reference_rows.append(reference_row)
			_candidate_rows.append(candidate_row)
			step("Then pair %d keeps the exact preview result on both paths" % pair, func():
				expect(parity["cells"], "the rebuild cells match element by element")
				expect(parity["vertices"], "the installed vertex arrays match element by element")
				expect(parity["aabb"], "the installed bounds match")
			)
	_print_path(spec["name"], "reference", _reference_rows)
	_print_path(spec["name"], "candidate", _candidate_rows)
	var exact: Dictionary = _reference_rows[0]["exact"]
	print("MEASURE sculpt_preview_ab %s exact: pairs=%d cells=%d vertices=%d surfaces=%d aabb=%s" % [
		spec["name"], _pairs, (exact["cells"] as Array).size(),
		(exact["vertices"] as PackedVector3Array).size(), exact["surfaces"], str(exact["aabb"]),
	])


# Runs one path on one measured run. Both paths start settled on the same cell,
# with an empty preview mesh cache and a cleared probe.
func _path_run(case_name: String, use_reference: bool) -> Dictionary:
	_tool.use_reference = use_reference
	_hover(_screen_of(_start_cell(case_name)))
	await _settle_all()
	_tool._rebuild_preview()
	await _settle_all()
	_clear_preview_cache()
	_tool.reset_probe()
	_reset_frame_stats()
	var before_mesh := _cursor_mesh_id()
	_begin_measure()
	var cells := _event_cells(case_name)
	var inputs: Array[int] = []
	var picks: Array[int] = []
	var fits: Array[int] = []
	var visuals: Array[int] = []
	var hovers: Array[int] = []
	var started := Time.get_ticks_usec()
	for cell in cells:
		var pick_before: int = _tool.pick_total_us
		var fit_before: int = _tool.fit_us
		var visual_before: int = _tool.visual_total_us
		var hover_before: int = _tool.hover_frame_us
		var event_started := Time.get_ticks_usec()
		_hover(_screen_of(cell))
		inputs.append(Time.get_ticks_usec() - event_started)
		picks.append(_tool.pick_total_us - pick_before)
		fits.append(_tool.fit_us - fit_before)
		visuals.append(_tool.visual_total_us - visual_before)
		hovers.append(_tool.hover_frame_us - hover_before)
		await get_tree().process_frame
	var span_us := Time.get_ticks_usec() - started
	# The last set installs after the last event. A same-cell run keeps the same
	# set, so it installs no new mesh and skips the poll.
	var install_frames := 0
	var visible_us := 0
	if case_name == "changed_cell":
		for index in INSTALL_FRAMES:
			await get_tree().process_frame
			if _cursor_mesh_id() != before_mesh and _cursor.is_settled():
				install_frames = index + 1
				visible_us = Time.get_ticks_usec() - started
				break
	else:
		await get_tree().process_frame
		visible_us = Time.get_ticks_usec() - started
	_end_measure()
	var row := _row(cells.size(), inputs, picks, fits, visuals, hovers, {
		"span_us": span_us, "install_frames": install_frames,
		"visible_us": visible_us, "visible_frames": install_frames,
	})
	# The two exclusive fit timers of one run. The pick fit and the hover fit do
	# not overlap, so their sum is the whole fit cost of the run.
	row["fit_pair_us"] = int(row["fit_us"]) + int(row["hover_us"])
	row["exact"] = _tool.exact_snapshot()
	return row


# The settled start cell of a run. It is never one of the measured cells, so
# every measured event starts from a changed pick.
func _start_cell(case_name: String) -> Vector3i:
	if case_name == "same_cell":
		return _mid_cell()
	return _path[_path.size() - 1]


func _event_cells(case_name: String) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	if case_name == "same_cell":
		for index in SAME_EVENTS:
			cells.append(_mid_cell())
		return cells
	for index in mini(CHANGE_EVENTS, _path.size()):
		cells.append(_path[index])
	return cells


# --- Invalidation routes ------------------------------------------------------
#
# Every route here must keep the exact result, and every route is checked on both
# paths. The color and the strength routes change no cell, so a later candidate
# may skip their work, but it must keep the same cells, vertices, and bounds. The
# frame route changes geometry in another frame, so the current frame must keep
# its result. The raw-write route proves that a rebuilt preview reads the live
# frame, and that no rebuild happens without a dirty event.

func _invalidation_case(radius: int) -> void:
	var spec := {"name": "invalidation_r%d" % radius, "radius": radius, "axes": 0, "selection": false, "mixed": false, "full": false}
	await _prepare(spec)
	for mode in [false, true]:
		_tool.use_reference = mode
		var label := "reference" if mode else "candidate"
		await _invalidation_routes(label)
		print("MEASURE sculpt_preview_ab invalidation_r%d %s: routes=6" % [radius, label])


func _invalidation_routes(label: String) -> void:
	# A settled hover on the middle cell.
	_hover(_screen_of(_mid_cell()))
	await _settle_all()
	_tool._rebuild_preview()
	var base: Dictionary = _tool.exact_snapshot()
	step("Then the %s path keeps the exact preview through every route" % label, func():
		expect((base["cells"] as Array).size() > 0, "the settled hover outlines support voxels")
	)

	# 1. A color-only change.
	State.current_color = COLOR_B if State.current_color != COLOR_B else COLOR_A
	State.color_changed.emit(State.current_color)
	await _settle_all()
	_tool._rebuild_preview()
	var color: Dictionary = _tool.exact_snapshot()
	expect(_same_exact(color, base), "%s: a color-only change keeps the exact cells, vertices, and bounds" % label)

	# 2. A strength-only change.
	_settings.strength = 8.0 if _settings.strength != 8.0 else 1.0
	await _settle_all()
	_tool._rebuild_preview()
	expect(_same_exact(_tool.exact_snapshot(), base), "%s: a strength-only change keeps the exact cells, vertices, and bounds" % label)

	# 3. A geometry change in another frame.
	var other := State.document.add_frame(0)
	var other_cell := Vector3i(_mid_cell().x, _mid_cell().y + 3, _mid_cell().z)
	other.set_cell(other_cell, VoxelFrame.material(Color.WHITE))
	State.document._bounds_dirty = true
	# The signals carry a typed cell array, so their listeners receive the type
	# the declaration promises.
	var other_cells: Array[Vector3i] = [other_cell]
	var other_chunks: Array[Vector3i] = [VoxelFrame.chunk_position(other_cell)]
	State.cells_changed.emit(1, other_cells)
	State.chunks_changed.emit(1, other_chunks)
	await _settle_all()
	_tool._rebuild_preview()
	expect(State.document.frames.size() == 2 and State.get_current_voxel_frame() == _frame, "%s: the edited frame is not the editor frame" % label)
	expect(_same_exact(_tool.exact_snapshot(), base), "%s: a geometry change in another frame keeps the exact cells, vertices, and bounds" % label)
	State.document.remove_frame(1)

	# 4. A geometry change in the current frame. The new voxel sits above a
	#    support cell, so the surface must move.
	var support: Array = base["cells"]
	var moved := (support[support.size() / 2] as Vector3i) + Vector3i(0, 1, 0)
	_frame.set_cell(moved, VoxelFrame.material(Color.WHITE))
	sync_viewport()
	await _settle_all()
	_tool._rebuild_preview()
	var current: Dictionary = _tool.exact_snapshot()
	expect(not _same_exact(current, base), "%s: a current-frame geometry change moves the preview" % label)
	_tool._mark_preview_dirty()
	_tool._rebuild_preview()
	expect(_same_exact(_tool.exact_snapshot(), current), "%s: the rebuilt preview matches the forced recompute" % label)

	# 5. A raw cell write with no signal. The preview must not rebuild on its own,
	#    and the next hover must pick the write up from the live frame.
	var raw := (support[0] as Vector3i) + Vector3i(0, 1, 0)
	var rebuilds_before: int = _tool.rebuild_calls
	_frame.set_cell(raw, VoxelFrame.material(Color.WHITE))
	await get_tree().process_frame
	await get_tree().process_frame
	expect(_tool.rebuild_calls == rebuilds_before, "%s: a raw cell write alone starts no preview rebuild" % label)
	_hover(_screen_of(_mid_cell()))
	await _settle_all()
	_tool._rebuild_preview()
	var raw_result: Dictionary = _tool.exact_snapshot()
	expect(not _same_exact(raw_result, current), "%s: the next hover reads the raw write from the live frame" % label)
	sync_viewport()
	await _settle_all()
	_tool._rebuild_preview()
	expect(_same_exact(_tool.exact_snapshot(), raw_result), "%s: the signal route matches the raw write route" % label)

	# 6. Two selections of the same size with different content.
	var before_selection: Dictionary = raw_result
	var mid := _mid_cell()
	State.selection.from_box(mid + Vector3i(-2, -1, -4), mid + Vector3i(2, 1, 4))
	State.selection_changed.emit()
	await _settle_all()
	_tool._rebuild_preview()
	var first: Dictionary = _tool.exact_snapshot()
	var first_size := State.selection.count()
	State.selection.from_box(mid + Vector3i(-1, -1, -4), mid + Vector3i(3, 1, 4))
	State.selection_changed.emit()
	await _settle_all()
	_tool._rebuild_preview()
	var second: Dictionary = _tool.exact_snapshot()
	expect(State.selection.count() == first_size, "%s: the two selections hold the same cell count" % label)
	expect((first["cells"] as Array) != (second["cells"] as Array), "%s: two selections of one size filter different cells" % label)
	expect((first["cells"] as Array).size() < (before_selection["cells"] as Array).size(), "%s: a partial selection narrows the preview" % label)
	expect((second["cells"] as Array).size() < (before_selection["cells"] as Array).size(), "%s: the shifted selection narrows the preview" % label)
	State.clear_selection()
	State.selection_changed.emit()
	await _settle_all()
	_tool._rebuild_preview()
	expect(_same_exact(_tool.exact_snapshot(), before_selection), "%s: clearing the selection restores the exact preview" % label)


# --- Radius change ------------------------------------------------------------
#
# A radius change with a stationary pointer calls no `_pick_start`. The preview
# rebuild pays one hover refit and one full footprint map at the new radius, so
# this case isolates the surface query cost from the fit count. The fit switch is
# reported as a control: the fit cleanup must not move a radius change.

func _resize_case() -> void:
	var spec := {"name": "resize_r32", "radius": 4, "axes": 0, "selection": false, "mixed": false, "full": false}
	await _prepare(spec)
	var grow_reference: Array = []
	var grow_candidate: Array = []
	var grow_control: Array = []
	var shrink_reference: Array = []
	var shrink_candidate: Array = []
	step("Given a settled radius 4 hover and a stationary pointer", func():
		expect(_tool.is_processing(), "the tool processes its frames")
		print("MEASURE sculpt_preview_ab resize env: cells=%d chunks=%d headless=%s" % [
			_fixture_cells, _fixture_chunks, str(DisplayServer.get_name() == "headless"),
		])
	)
	for pair in WARMUPS + REPEATS:
		var grow := await _resize_pair(32, pair)
		var shrink := await _resize_pair(4, pair)
		var grow_parity := _exact_parity(grow["reference"]["exact"], grow["candidate"]["exact"])
		var shrink_parity := _exact_parity(shrink["reference"]["exact"], shrink["candidate"]["exact"])
		print("MEASURE sculpt_preview_ab resize pair=%d reference_fit_us=%d candidate_fit_us=%d reference_sample_us=%d candidate_sample_us=%d reference_rebuild_us=%d candidate_rebuild_us=%d reference_gap_us=%d candidate_gap_us=%d shrink_reference_sample_us=%d shrink_candidate_sample_us=%d cells_equal=%s vertices_equal=%s aabb_equal=%s first_difference=%s" % [
			pair,
			grow["reference"]["hover_us"], grow["candidate"]["hover_us"],
			grow["reference"]["sample_us"], grow["candidate"]["sample_us"],
			grow["reference"]["rebuild_us"], grow["candidate"]["rebuild_us"],
			grow["reference"]["gap_us"], grow["candidate"]["gap_us"],
			shrink["reference"]["sample_us"], shrink["candidate"]["sample_us"],
			str(grow_parity["cells"] and shrink_parity["cells"]),
			str(grow_parity["vertices"] and shrink_parity["vertices"]),
			str(grow_parity["aabb"] and shrink_parity["aabb"]),
			grow_parity["first_difference"],
		])
		if pair >= WARMUPS:
			grow_reference.append(grow["reference"])
			grow_candidate.append(grow["candidate"])
			shrink_reference.append(shrink["reference"])
			shrink_candidate.append(shrink["candidate"])
			grow_control.append(await _resize_run(32, false, true))
			step("Then the radius change keeps the exact preview result", func():
				expect(grow_parity["cells"], "the radius 32 rebuild cells match element by element")
				expect(grow_parity["vertices"], "the radius 32 installed vertex arrays match")
				expect(grow_parity["aabb"], "the radius 32 installed bounds match")
				expect(shrink_parity["cells"], "the radius 4 rebuild cells match element by element")
				expect(shrink_parity["vertices"], "the radius 4 installed vertex arrays match")
				expect(shrink_parity["aabb"], "the radius 4 installed bounds match")
			)
	_print_path("resize_grow_4_32", "reference_surface", grow_reference)
	_print_path("resize_grow_4_32", "candidate", grow_candidate)
	_print_path("resize_grow_4_32", "fit_control", grow_control)
	_print_path("resize_shrink_32_4", "reference_surface", shrink_reference)
	_print_path("resize_shrink_32_4", "candidate", shrink_candidate)


func _resize_pair(target_radius: int, pair: int) -> Dictionary:
	var first_reference := pair % 2 == 0
	var a := await _resize_run(target_radius, first_reference, false)
	var b := await _resize_run(target_radius, not first_reference, false)
	return {
		"reference": a if first_reference else b,
		"candidate": b if first_reference else a,
	}


# Runs one radius change from the opposite radius. The change is a settings change
# with a stationary pointer, so no pick and no motion is involved. The event row
# carries the settle window, and the counters carry the stages.
func _resize_run(target_radius: int, use_reference_surface: bool, use_reference_fit: bool) -> Dictionary:
	_tool.use_reference_surface = use_reference_surface
	_tool.use_reference = use_reference_fit
	_settings.radius = 4 if target_radius == 32 else 32
	_hover(_screen_of(_mid_cell()))
	await _settle_all()
	_tool._rebuild_preview()
	await _settle_all()
	_clear_preview_cache()
	_tool.reset_probe()
	_reset_frame_stats()
	_begin_measure()
	var started := Time.get_ticks_usec()
	_settings.radius = target_radius
	var settle_frames := 0
	for index in 240:
		await get_tree().process_frame
		if _tool.rebuild_calls > 0 and not _tool._preview_dirty and _cursor.is_settled():
			settle_frames = index + 1
			break
	var settle_us := Time.get_ticks_usec() - started
	_end_measure()
	var row := _row(1, [settle_us], [], [], [], [], {
		"span_us": settle_us, "install_frames": settle_frames,
		"visible_us": settle_us, "visible_frames": settle_frames,
	})
	row["exact"] = _tool.exact_snapshot()
	return row


# --- Surface query parity and timing -----------------------------------------
#
# The frozen query must return the same cell as production for every query. The
# enumeration is deterministic and covers the cardinal and oblique normals, exact
# ties in both signs, the negative half of the first cell test, an empty frame, a
# solid run past the depth cap, and pending writes. The timing uses the real query
# stream of a real hover at each radius and of a real radius change.

func _surface_case() -> void:
	var spec := {"name": "surface_query", "radius": 4, "axes": 0, "selection": false, "mixed": false, "full": false}
	await _prepare(spec)
	var support := _path[0]
	var pending_add := {}
	var pending_remove := {}
	pending_add[Vector3i(support.x, support.y + 1, support.z)] = VoxelFrame.material(Color.WHITE)
	pending_remove[Vector3i(support.x + 1, support.y, support.z)] = VoxelFrame.material(Color.TRANSPARENT)
	var changes_list: Array = [{}, pending_add, pending_remove]
	var box := AABB(Vector3(support) - Vector3.ONE, Vector3.ONE * 2.0)
	var ramp_queries := SurfaceQuery.enumeration(box, changes_list, 1)
	var ramp_parity := SurfaceQuery.parity(_frame, ramp_queries)
	var empty := VoxelFrame.new()
	var empty_queries := SurfaceQuery.enumeration(AABB(Vector3(-1.5, -1.5, -1.5), Vector3.ONE * 3.0), changes_list, 1)
	var empty_parity := SurfaceQuery.parity(empty, empty_queries)
	var slab := _make_slab()
	var slab_queries := SurfaceQuery.enumeration(slab.get_bounds(), [{}, pending_add], 4)
	var slab_parity := SurfaceQuery.parity(slab, slab_queries)
	var real := await _capture_real_queries()
	var edge_queries := SurfaceQuery.edge_queries(Vector3(support), changes_list)
	var edge_parity := SurfaceQuery.parity(_frame, edge_queries)
	var far := _far_frame()
	var far_queries := SurfaceQuery.far_queries()
	var far_parity := SurfaceQuery.parity(far, far_queries)
	var island := _island_frame()
	var island_queries := SurfaceQuery.enumeration(AABB(Vector3(-1, -1, -1), Vector3.ONE * 2.0), [{}, pending_add], 1)
	var island_parity := SurfaceQuery.parity(island, island_queries)
	var real_parity := SurfaceQuery.parity(_frame, real["all"])
	var fit_prefix := _prefix_hits(_frame, real["fit"])
	var map_prefix := _prefix_hits(_frame, real["map"])
	for warmup in WARMUPS:
		SurfaceQuery.time_queries(_frame, real["all"], true)
		SurfaceQuery.time_queries(_frame, real["all"], false)
	var frozen_times: Array = []
	var production_times: Array = []
	for repeat in REPEATS:
		if repeat % 2 == 0:
			frozen_times.append(SurfaceQuery.time_queries(_frame, real["all"], true))
			production_times.append(SurfaceQuery.time_queries(_frame, real["all"], false))
		else:
			production_times.append(SurfaceQuery.time_queries(_frame, real["all"], false))
			frozen_times.append(SurfaceQuery.time_queries(_frame, real["all"], true))
	var fit_frozen := SurfaceQuery.time_queries(_frame, real["fit"], true)
	var fit_production := SurfaceQuery.time_queries(_frame, real["fit"], false)
	var map_frozen := SurfaceQuery.time_queries(_frame, real["map"], true)
	var map_production := SurfaceQuery.time_queries(_frame, real["map"], false)
	var mismatches: int = ramp_parity["mismatches"].size() + empty_parity["mismatches"].size() + slab_parity["mismatches"].size() + real_parity["mismatches"].size() + edge_parity["mismatches"].size() + far_parity["mismatches"].size() + island_parity["mismatches"].size()
	print("MEASURE sculpt_preview_ab surface_query parity: ramp=%d empty=%d slab=%d edge=%d far=%d island=%d real=%d queries=%d mismatches=%d first=%s" % [
		ramp_parity["count"], empty_parity["count"], slab_parity["count"],
		edge_parity["count"], far_parity["count"], island_parity["count"], real_parity["count"],
		int(ramp_parity["count"]) + int(empty_parity["count"]) + int(slab_parity["count"]) + int(edge_parity["count"]) + int(far_parity["count"]) + int(island_parity["count"]) + int(real_parity["count"]),
		mismatches, _first_mismatch([ramp_parity, empty_parity, slab_parity, edge_parity, far_parity, island_parity, real_parity]),
	])
	print("MEASURE sculpt_preview_ab surface_query worst: empty_frozen_us=%d empty_production_us=%d island_queries=%d island_frozen_us=%d island_production_us=%d far_queries=%d far_frozen_us=%d far_production_us=%d edge_frozen_us=%d edge_production_us=%d" % [
		SurfaceQuery.time_queries(empty, empty_queries, true), SurfaceQuery.time_queries(empty, empty_queries, false),
		island_queries.size(), SurfaceQuery.time_queries(island, island_queries, true), SurfaceQuery.time_queries(island, island_queries, false),
		far_queries.size(), SurfaceQuery.time_queries(far, far_queries, true), SurfaceQuery.time_queries(far, far_queries, false),
		SurfaceQuery.time_queries(_frame, edge_queries, true), SurfaceQuery.time_queries(_frame, edge_queries, false),
	])
	print("MEASURE sculpt_preview_ab surface_query prefix: fit=%d/%d map=%d/%d" % [
		fit_prefix, (real["fit"] as Array).size(), map_prefix, (real["map"] as Array).size(),
	])
	print("MEASURE sculpt_preview_ab surface_query split: fit_queries=%d fit_frozen_us=%d fit_production_us=%d map_queries=%d map_frozen_us=%d map_production_us=%d" % [
		(real["fit"] as Array).size(), fit_frozen, fit_production,
		(real["map"] as Array).size(), map_frozen, map_production,
	])
	print("MEASURE sculpt_preview_ab surface_query timing: queries=%d warmups=%d repeats=%d frozen_med_us=%d production_med_us=%d frozen_min_us=%d production_min_us=%d frozen_per_query_us=%.3f production_per_query_us=%.3f" % [
		(real["all"] as Array).size(), WARMUPS, REPEATS, _median(frozen_times), _median(production_times),
		_min(frozen_times), _min(production_times),
		float(_min(frozen_times)) / maxf(1.0, float((real["all"] as Array).size())),
		float(_min(production_times)) / maxf(1.0, float((real["all"] as Array).size())),
	])
	step("Then the frozen surface query matches production on every query", func():
		expect(ramp_parity["mismatches"].is_empty(), "the ramp enumeration matches (%d queries)" % ramp_parity["count"])
		expect(empty_parity["mismatches"].is_empty(), "the empty frame matches (%d queries)" % empty_parity["count"])
		expect(slab_parity["mismatches"].is_empty(), "the solid run past the cap matches (%d queries)" % slab_parity["count"])
		expect(edge_parity["mismatches"].is_empty(), "the boundary fractions match (%d queries)" % edge_parity["count"])
		expect(far_parity["mismatches"].is_empty(), "the large coordinates match (%d queries)" % far_parity["count"])
		expect(island_parity["mismatches"].is_empty(), "the tiny island under a wide query matches (%d queries)" % island_parity["count"])
		expect(real_parity["mismatches"].is_empty(), "the real hover and resize stream matches (%d queries)" % real_parity["count"])
	)


# Captures the real query stream. The frozen surface path records every map query
# it runs, and the fit queries come from the production fit formulas of the same
# hit, so the stream is what a real hover at each radius and a real radius change
# ask for. It is not a synthetic set alone. The two parts stay apart, so a report
# can state the cost of each.
func _capture_real_queries() -> Dictionary:
	var fit_queries: Array = []
	var map_queries: Array = []
	_tool.use_reference = false
	_tool.use_reference_surface = true
	for radius in [4, 16, 32]:
		_settings.radius = radius
		_hover(_screen_of(_mid_cell()))
		await _settle_all()
		SurfaceQuery.begin_capture()
		_tool._mark_preview_dirty()
		_tool._rebuild_preview()
		SurfaceQuery.end_capture()
		map_queries.append_array(SurfaceQuery.captured)
		fit_queries.append_array(_fit_queries(_tool._last_pick.hit, _tool._last_pick.entry, radius))
	# A radius change with a stationary pointer, at the maximum radius.
	_settings.radius = 4
	await _settle_all()
	SurfaceQuery.begin_capture()
	_settings.radius = 32
	await _settle_all()
	SurfaceQuery.end_capture()
	map_queries.append_array(SurfaceQuery.captured)
	fit_queries.append_array(_fit_queries(_tool._last_pick.hit, _tool._last_pick.entry, 32))
	_tool.use_reference_surface = false
	return {"fit": fit_queries, "map": map_queries, "all": fit_queries + map_queries}


# The fit queries of one hit. The formulas match the production fit: the disc of
# the fit and its depth.
static func _fit_queries(hit: Vector3i, entry: Vector3i, radius: int) -> Array:
	var queries: Array = []
	if entry == Vector3i.ZERO or hit == VoxelPicking.NONE:
		return queries
	var normal := Vector3(entry).normalized()
	var axis := SculptGeometry.axis_of(entry)
	var u_axis := (axis + 1) % 3
	var v_axis := (axis + 2) % 3
	var depth := mini(64, maxi(8, radius * 2))
	for offset in SculptGeometry.disk_offsets(maxi(radius, 1)):
		var point := Vector3(hit)
		point[u_axis] += float(offset["u"])
		point[v_axis] += float(offset["v"])
		queries.append({"point": point, "normal": normal, "depth": depth, "changes": {}})
	return queries


# A deterministic solid slab deeper than the query cap, so the interior guard and
# an occupied run past the cap are both covered.
func _make_slab() -> VoxelFrame:
	var frame := VoxelFrame.new()
	var changes := {}
	var material := VoxelFrame.material(Color.WHITE)
	for x in range(-3, 4):
		for z in range(-3, 4):
			for y in range(-12, 1):
				changes[Vector3i(x, y, z)] = material
	frame.set_cells(changes)
	return frame


# A sparse frame at large coordinates. The chunks stay few, and a half cell there
# is no longer representable on every lattice point.
func _far_frame() -> VoxelFrame:
	var frame := VoxelFrame.new()
	var changes := {}
	var material := VoxelFrame.material(Color.WHITE)
	for cell in [Vector3i(8388608, 0, 0), Vector3i(8388611, 1, 2), Vector3i(-8388608, 0, 0), Vector3i(-8388611, -1, 2)]:
		changes[cell] = material
	frame.set_cells(changes)
	return frame


# One isolated cell. A wide query around it is a long miss in almost every
# direction, which is the worst case of the bounded scan.
func _island_frame() -> VoxelFrame:
	var frame := VoxelFrame.new()
	frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.WHITE))
	return frame


func _first_mismatch(parts: Array) -> String:
	for part in parts:
		var found: Array = part["mismatches"]
		if not found.is_empty():
			var entry: Dictionary = found[0]
			return "point=%s normal=%s depth=%d frozen=%s production=%s" % [
				str(entry["point"]), str(entry["normal"]), entry["depth"],
				str(entry["frozen"]), str(entry["production"]),
			]
	return "-"


func _min(values: Array) -> int:
	if values.is_empty():
		return 0
	var best: int = values[0]
	for value in values:
		best = mini(best, int(value))
	return best


# Counts the queries the production fast path can serve in its three-cell prefix.
func _prefix_hits(frame: VoxelFrame, queries: Array) -> int:
	var hits := 0
	for query in queries:
		if SurfaceQuery.fast_prefix_hit(frame, query["point"], query["normal"], query["depth"], query.get("changes", {})):
			hits += 1
	return hits


# --- Helpers ------------------------------------------------------------------

func _install_tool() -> void:
	var sculpt := plugin("SculptPlugin")
	# The plugin's own tool must not receive input, so it stays out of the tree.
	activate_tool("sculpt")
	sculpt.activate_tool()
	sculpt.deactivate_tool()
	_tool = preload("res://plugins/Sculpt/SculptTool.tscn").instantiate()
	_tool.set_script(ReferenceScript)
	# `set_script` replaces the script instance. Reassign the shared settings when
	# the replacement did not run the tool initializer.
	if _tool._settings == null:
		_tool._settings = _settings
	sculpt.add_editor_node(_tool)
	_tool.bind_cursor()
	_cursor = _tool.get_node("Cursor")
	_viewport = editor_viewport()
	_renderer = viewport_scene().get_node("VoxelRenderer")


# The base script of this file is `sculpt_preview.gd`, so the harness helper in
# `test.gd` would otherwise become the reported caller of an expect.
func _caller_frame(stack: Array) -> Dictionary:
	for frame in stack:
		var entry := frame as Dictionary
		if str(entry["source"]).ends_with("test.gd"):
			continue
		return entry
	return {}


# Clears the static preview mesh cache, so both paths of a pair pay their own
# mesh build. The three fields are the ones the preview layer clears when its
# last node leaves the tree. The probe's own seen-key set is cleared with it, so
# `cache_hits` reports the current cache state and not an older run.
func _clear_preview_cache() -> void:
	PreviewScript._mesh_cache.clear()
	PreviewScript._cache_order.clear()
	PreviewScript._cache_bytes = 0
	ProbeScript._seen_keys.clear()


func _same_exact(first: Dictionary, second: Dictionary) -> bool:
	return (
		(first["cells"] as Array) == (second["cells"] as Array)
		and (first["vertices"] as PackedVector3Array) == (second["vertices"] as PackedVector3Array)
		and first["aabb"] == second["aabb"]
	)


# Compares two exact snapshots element by element and names the first difference.
func _exact_parity(first: Dictionary, second: Dictionary) -> Dictionary:
	var first_cells: Array = first["cells"]
	var second_cells: Array = second["cells"]
	var first_vertices: PackedVector3Array = first["vertices"]
	var second_vertices: PackedVector3Array = second["vertices"]
	return {
		"cells": first_cells == second_cells,
		"vertices": first_vertices == second_vertices,
		"aabb": first["aabb"] == second["aabb"],
		"cells_first": first_cells.size(),
		"cells_second": second_cells.size(),
		"vertices_first": first_vertices.size(),
		"vertices_second": second_vertices.size(),
		"first_difference": _first_difference(first_cells, second_cells, first_vertices, second_vertices, first["aabb"], second["aabb"]),
	}


func _first_difference(first_cells: Array, second_cells: Array, first_vertices: PackedVector3Array, second_vertices: PackedVector3Array, first_aabb: AABB, second_aabb: AABB) -> String:
	if first_cells != second_cells:
		for index in mini(first_cells.size(), second_cells.size()):
			if first_cells[index] != second_cells[index]:
				return "cell %d: %s vs %s" % [index, str(first_cells[index]), str(second_cells[index])]
		return "cell count"
	if first_vertices != second_vertices:
		for index in mini(first_vertices.size(), second_vertices.size()):
			if first_vertices[index] != second_vertices[index]:
				return "vertex %d: %s vs %s" % [index, str(first_vertices[index]), str(second_vertices[index])]
		return "vertex count"
	if first_aabb != second_aabb:
		return "aabb %s vs %s" % [str(first_aabb), str(second_aabb)]
	return "-"


# The median over the measured runs of one path.
func _path_median(rows: Array, key: String) -> int:
	var values: Array = []
	for row in rows:
		values.append(int(row.get(key, 0)))
	return _median(values)


func _print_path(case_name: String, path_name: String, rows: Array) -> void:
	# The mesh request layer is printed apart from the CPU stages. `submits` and
	# `dedupe` are the request layer, `sample_us`, `cells_us`, and `set_us` are
	# the rebuild stages, and `fit_us` and `hover_us` are the input stages.
	print("MEASURE sculpt_preview_ab %s %s_event: runs=%d input_med_us=%d input_max_us=%d pick_med_us=%d fit_med_us=%d hover_med_us=%d visual_med_us=%d fit_us=%d hover_us=%d fit_pair_us=%d" % [
		case_name, path_name, rows.size(),
		_path_median(rows, "input_med_us"), _path_median(rows, "input_max_us"),
		_path_median(rows, "pick_med_us"), _path_median(rows, "fit_med_us"),
		_path_median(rows, "hover_med_us"), _path_median(rows, "visual_med_us"),
		_path_median(rows, "fit_us"), _path_median(rows, "hover_us"),
		_path_median(rows, "fit_pair_us"),
	])
	print("MEASURE sculpt_preview_ab %s %s_frame: runs=%d rebuilds=%d rebuild_med_us=%d rebuild_us=%d sample_maps=%d sample_us=%d cells_calls=%d cells_us=%d set_calls=%d set_us=%d submits=%d dedupe=%d cache_hits=%d debounced=%d dirty_frames=%d deferred_frames=%d" % [
		case_name, path_name, rows.size(),
		_path_median(rows, "rebuilds"), _path_median(rows, "rebuild_med_us"),
		_path_median(rows, "rebuild_us"), _path_median(rows, "sample_maps"),
		_path_median(rows, "sample_us"), _path_median(rows, "cells_calls"),
		_path_median(rows, "cells_us"), _path_median(rows, "set_calls"),
		_path_median(rows, "set_us"), _path_median(rows, "submits"),
		_path_median(rows, "dedupe"), _path_median(rows, "cache_hits"),
		_path_median(rows, "debounced"), _path_median(rows, "dirty_frames"),
		_path_median(rows, "deferred_frames"),
	])
	print("MEASURE sculpt_preview_ab %s %s_mesh: runs=%d installs=%d install_frames=%d visible_us=%d visible_frames=%d span_us=%d gap_us=%d frames=%d" % [
		case_name, path_name, rows.size(),
		_path_median(rows, "installs"), _path_median(rows, "install_frames"),
		_path_median(rows, "visible_us"), _path_median(rows, "visible_frames"),
		_path_median(rows, "span_us"), _path_median(rows, "gap_us"),
		_path_median(rows, "frames"),
	])
