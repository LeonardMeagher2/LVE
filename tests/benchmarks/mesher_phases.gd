extends "res://tests/test.gd"


const REF := preload("res://tests/mesher_read_reference.gd")
const AB_CONFIGS := [
	{"fixture": "uniform", "smooth": false, "atlas": false},
	{"fixture": "uniform", "smooth": false, "atlas": true},
	{"fixture": "uniform", "smooth": true, "atlas": true},
	{"fixture": "mixed", "smooth": false, "atlas": false},
]

const CHUNK := VoxelFrame.CHUNK_SIZE
const SPAN := 3
const CHUNKS := SPAN * SPAN * SPAN
const FULL_SCAN_QUERIES := 3 * 2 * CHUNK * CHUNK * CHUNK
const WARMUP_PASSES := 2
const MEASURE_PASSES := 5

var _fixtures := {}
var _rows := {}
var _order: Array = []


func _ready() -> void:
	timeout = 600.0
	test("the mesher phases attribute one surface build", _attribute, "mesher_phases")


func _attribute() -> void:
	step("Given a uniform and a mixed 48-cube block", func():
		_fixtures["uniform"] = _build_fixture(false)
		_fixtures["mixed"] = _build_fixture(true)
		for fixture in ["uniform", "mixed"]:
			var frame: VoxelFrame = _fixtures[fixture]
			expect(frame.chunks.size() == CHUNKS, "%s holds %d chunks" % [fixture, CHUNKS])
	)
	step("When the batches run warmed and alternating", func():
		for fixture in ["uniform", "mixed"]:
			for smooth in [false, true]:
				for atlas in [true, false]:
					var name := _config_name(fixture, smooth, atlas)
					_order.append(name)
					_rows[name] = {"fixture": fixture, "smooth": smooth, "atlas": atlas, "passes": []}
		for pass_index in WARMUP_PASSES + MEASURE_PASSES:
			for name in _order:
				_run_pass(name, _rows[name])
	)
	step("Then each phase is attributed and every batch builds geometry", func():
		for name in _order:
			_check(name, _rows[name])
	)
	step("Then the production read path beats the frozen body in one warm process", func():
		for config in AB_CONFIGS:
			_check_ab(config)
	)


func _check_ab(config: Dictionary) -> void:
	var frame: VoxelFrame = _fixtures[config["fixture"]]
	var smooth: bool = config["smooth"]
	var atlas: bool = config["atlas"]
	var frozen_times: Array[int] = []
	var production_times: Array[int] = []
	for pass_index in WARMUP_PASSES + MEASURE_PASSES:
		frozen_times.append(_time_frozen(frame, smooth, atlas))
		production_times.append(_time_production(frame, smooth, atlas))
	var frozen_median := _median(frozen_times.slice(WARMUP_PASSES))
	var production_median := _median(production_times.slice(WARMUP_PASSES))
	var name := _config_name(config["fixture"], smooth, atlas)
	print("MEASURE mesher_phases_ab %s: frozen_us=%d production_us=%d ratio=%.3f" % [
		name, frozen_median, production_median, float(production_median) / float(maxi(1, frozen_median)),
	])
	expect(production_median < frozen_median, "%s: the production read path beats the frozen body" % name)


func _time_frozen(frame: VoxelFrame, smooth: bool, atlas: bool) -> int:
	var started := Time.get_ticks_usec()
	for location: Vector3i in frame.chunks:
		REF.build(frame, location, smooth, atlas)
	return Time.get_ticks_usec() - started


func _time_production(frame: VoxelFrame, smooth: bool, atlas: bool) -> int:
	var started := Time.get_ticks_usec()
	for location: Vector3i in frame.chunks:
		var builder := VoxelMeshBuilder.new()
		builder.enclosed_shortcut = false
		builder.source_frame = frame
		builder.chunk_location = location
		builder.smooth_normals = smooth
		builder.texture_materials = atlas
		builder.run()
	return Time.get_ticks_usec() - started


func _run_pass(name: String, row: Dictionary) -> void:
	var frame: VoxelFrame = _fixtures[row["fixture"]]
	var smooth: bool = row["smooth"]
	var atlas: bool = row["atlas"]
	var totals := {
		"us": 0, "snapshot": 0, "scan": 0, "finish": 0, "chunks": 0, "culled": 0, "empty": 0,
		"vertices": 0, "triangles": 0, "chunks_read": 0, "cells_read": 0, "decodes": 0,
		"queries": 0, "groups": 0, "atlas_bytes": 0,
		"protect": 0, "triangulate": 0, "vertices_surf": 0, "atlas_ph": 0, "uvs": 0,
		"loops": 0, "simplify": 0, "protect_inner": 0, "normal": 0,
	}
	var started_us := Time.get_ticks_usec()
	for location: Vector3i in frame.chunks:
		var builder := VoxelMeshBuilder.new()
		builder.source_frame = frame
		builder.chunk_location = location
		builder.smooth_normals = smooth
		builder.texture_materials = atlas
		builder.profile = true
		builder.run()
		totals["snapshot"] += builder.snapshot_us
		totals["scan"] += builder.scan_us
		totals["finish"] += builder.finish_us
		totals["chunks"] += 1
		if builder.enclosed_culled:
			totals["culled"] += 1
		totals["vertices"] += builder.surface_arrays[Mesh.ARRAY_VERTEX].size()
		totals["triangles"] += builder.surface_arrays[Mesh.ARRAY_INDEX].size() / 3
		totals["protect"] += builder.protect_us
		totals["triangulate"] += builder.triangulate_us
		totals["vertices_surf"] += builder.vertices_surf_us
		totals["atlas_ph"] += builder.atlas_ph_us
		totals["uvs"] += builder.uvs_us
		totals["loops"] += builder.loops_us
		totals["simplify"] += builder.simplify_us
		totals["protect_inner"] += builder.protect_inner_us
		totals["normal"] += builder.normal_us
		totals["chunks_read"] += builder.snapshot_chunks
		totals["cells_read"] += builder.snapshot_cells
		totals["decodes"] += builder.snapshot_decodes
		totals["queries"] += builder.scan_queries
		totals["groups"] += builder.group_count
		totals["atlas_bytes"] += builder.atlas_albedo.size() + builder.atlas_orm.size() + builder.atlas_emission.size()
		if builder.surface_arrays[Mesh.ARRAY_VERTEX].is_empty():
			totals["empty"] += 1
	totals["us"] = Time.get_ticks_usec() - started_us
	row["passes"].append(totals)


func _check(name: String, row: Dictionary) -> void:
	var medians := {}
	for key in row["passes"][0]:
		var values: Array[int] = []
		for index in range(WARMUP_PASSES, row["passes"].size()):
			values.append(int(row["passes"][index][key]))
		medians[key] = _median(values)
	var total: int = medians["us"]
	var phases: int = medians["snapshot"] + medians["scan"] + medians["finish"]
	print("MEASURE mesher_phases %s: chunks=%d culled=%d empty=%d vertices=%d triangles=%d groups=%d" % [
		name, medians["chunks"], medians["culled"], medians["empty"], medians["vertices"],
		medians["triangles"], medians["groups"],
	])
	print("MEASURE mesher_phases %s phases: total_us=%d snapshot_us=%d scan_us=%d finish_us=%d phases_us=%d cover_pct=%.1f" % [
		name, total, medians["snapshot"], medians["scan"], medians["finish"], phases,
		100.0 * float(phases) / float(maxi(1, total)),
	])
	print("MEASURE mesher_phases %s surface: protect=%d triangulate=%d vertices=%d atlas=%d uvs=%d loops=%d simplify=%d protect_inner=%d normal=%d" % [name, medians["protect"], medians["triangulate"], medians["vertices_surf"], medians["atlas_ph"], medians["uvs"], medians["loops"], medians["simplify"], medians["protect_inner"], medians["normal"]])
	print("MEASURE mesher_phases %s reads: snapshot_chunks=%d snapshot_cells=%d decodes=%d queries=%d atlas_bytes=%d" % [
		name, medians["chunks_read"], medians["cells_read"], medians["decodes"],
		medians["queries"], medians["atlas_bytes"],
	])
	expect(medians["triangles"] > 0, "%s builds triangles" % name)
	expect(phases <= total + maxi(1000, total / 20), "%s attributes every phase inside the measured pass" % name)
	if name == "uniform_flat_atlas":
		expect(medians["culled"] == 1, "the uniform block culls only its center chunk")
		expect(medians["queries"] == (CHUNKS - 1) * FULL_SCAN_QUERIES, "every built full chunk tests every padded sample pair")
		expect(medians["chunks_read"] == 26 + 102, "the flat snapshot reads one grid per built chunk and face neighbor")
		expect(medians["cells_read"] == 26 * CHUNK * CHUNK * CHUNK + 102 * CHUNK * CHUNK, "the flat snapshot copies only each neighbor's overlap")
	if name == "mixed_flat_atlas":
		expect(medians["culled"] == 0, "a translucent own row disables the enclosed shortcut")
		expect(medians["chunks_read"] == 27 + 108, "the mixed flat snapshot reads every chunk and face neighbor")


func _build_fixture(mixed: bool) -> VoxelFrame:
	var frame := VoxelFrame.new()
	var flat := VoxelFrame.material(Color.from_rgba8(90, 160, 220))
	var metal := VoxelFrame.material(Color.from_rgba8(220, 120, 70), Color(0.2, 0.1, 0.0), 0.8, 0.2)
	var rough := VoxelFrame.material(Color(0.1, 0.4, 0.9), Color.BLACK, 0.0, 1.0)
	var translucent := VoxelFrame.material(Color(1.0, 0.0, 0.0, 0.5))
	for cz in SPAN:
		for cy in SPAN:
			for cx in SPAN:
				var location := Vector3i(cx, cy, cz)
				var chunk := VoxelFrame.Chunk.new()
				chunk.location = location
				chunk.occupied_count = CHUNK * CHUNK * CHUNK
				chunk.shared_materials = true
				chunk.bounds_dirty = false
				chunk.occupied_bounds = AABB(Vector3(location * CHUNK) - Vector3.ONE * 0.5, Vector3.ONE * CHUNK)
				if mixed:
					for lz in CHUNK:
						for ly in CHUNK:
							for lx in CHUNK:
								chunk.grid[VoxelFrame.Chunk.cell_slot(Vector3i(lx, ly, lz))] = 1 + ((lx + ly + lz) % 4)
					chunk.materials = rough.duplicate()
					chunk.materials.append_array(metal)
					chunk.materials.append_array(flat)
					chunk.materials.append_array(translucent)
				else:
					chunk.grid.fill(1)
					chunk.materials = flat.duplicate()
				frame.chunks[location] = chunk
	frame.restore(frame.chunks)
	return frame


func _config_name(fixture: String, smooth: bool, atlas: bool) -> String:
	return "%s_%s_%s" % [fixture, "smooth" if smooth else "flat", "atlas" if atlas else "color"]


func _median(values: Array) -> int:
	if values.is_empty():
		return 0
	var sorted := values.duplicate()
	sorted.sort()
	return int(sorted[sorted.size() / 2])
