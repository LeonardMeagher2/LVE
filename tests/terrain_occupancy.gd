extends "res://tests/test.gd"

# Differential and performance test for the Smooth occupancy gather.
#
# `tests/terrain_occupancy_reference.gd` freezes the per-candidate gather that ran
# before the bounded local box scan. Every fixture is gathered by the live job
# and by the reference, then compared as an occupancy superset, the decisions,
# the materials, and the changed chunks. The A/B
# alternates the two paths in one warmed process and reports medians with their
# sample counts.
#
#   godot --path . res://tests/terrain_occupancy.tscn
#   godot --path . res://tests/terrain_occupancy.tscn -- occupancy_benchmark
#
# The benchmark is opt-in. It runs the maximum patch many times, so the suite
# never pays for it.

const REFERENCE := preload("res://tests/terrain_occupancy_reference.gd")
const VoxelFalloff := preload("res://Globals/State/Tools/VoxelFalloff.gd")
const TERRAIN := preload("res://plugins/Terrain/TerrainTool.gd")
const SmoothOperation := preload("res://plugins/Terrain/SmoothOperation.gd")
const TerrainGeometry := preload("res://plugins/Terrain/TerrainGeometry.gd")

## The measured samples per path. The median ignores one slow outlier.
const AB_SAMPLES := 5
## The warmed samples that run before the measured ones.
const AB_WARMUPS := 2
## The cells above and below a surface cell that a Smooth patch reaches. The
## value matches the tool.
const REACH := 2
## The benchmark names that opt in to the long measurement.
const BENCHMARK_NAMES := ["occupancy_benchmark"]
## The benchmark deadline. It runs the maximum patch many times.
const BENCHMARK_TIMEOUT := 900.0

var _fixtures := {}
var _order: Array[String] = []
var _materials := {}
var _sink := 0
# The parity counters. A step lambda captures a local by value, so state shared
# between steps lives on the instance.
var _superset_misses := 0
var _decision_misses := 0
var _published := 0
var _removals := 0
var _fills := 0
var _first_miss := ""


func _ready() -> void:
	timeout = 30.0
	test("the frozen gather reference keeps the old loop", _expect_frozen_reference, "occupancy_reference")
	test("every fixture keeps the occupancy and the decisions", _expect_parity, "occupancy_parity")
	test("the gather preserves normalized kernels and distant sparse cells", _expect_halo_bounds, "occupancy_halo")
	test("a cancelled gather stops before it scans the whole box", _expect_cancellation, "occupancy_cancel")
	if _benchmark_requested():
		timeout = BENCHMARK_TIMEOUT
		test("the warmed gather and job A/B over every fixture", _benchmark, "occupancy_benchmark")


func _benchmark_requested() -> bool:
	for argument in OS.get_cmdline_user_args():
		if BENCHMARK_NAMES.has(argument):
			return true
	return false


func _expect_frozen_reference() -> void:
	var source := FileAccess.get_file_as_string("res://tests/terrain_occupancy_reference.gd")
	# The frozen loop must not call a helper of the new path.
	for forbidden in ["_occupancy_box", "_occupancy_cells", "_box_volume", "gather_reads"]:
		expect(not source.contains(forbidden), "the frozen reference never calls %s" % forbidden)
	expect(source.contains("edited_frame.has(point)"), "the frozen reference keeps the per-candidate lookup")
	expect(source.contains("completed % 256 == 0"), "the frozen reference keeps its candidate checkpoint")
	# The reference job gathers the old way on a real patch.
	var fixture: Dictionary = _fixture("small_flat")
	var job: Variant = _job("reference", fixture["frame"], fixture)
	var cells: Array = fixture["cells"]
	var occupied = job._occupancy(cells)
	expect(occupied != null and not (occupied as Dictionary).is_empty(), "the reference job gathers the halo")
	expect(job.lookups == cells.size() * 27, "the reference job makes one kernel of lookups per candidate")


# --- Fixtures ---------------------------------------------------------------

# Builds the measured fixtures once. Each fixture holds a frame, the candidate
# cells of a real Smooth patch, their weights, and the tick inputs.
func _build_fixtures() -> void:
	if not _fixtures.is_empty():
		return
	_add_fixture("small_flat", _plate(Vector3i.ZERO, 16, 3, false), Vector3(0.0, -1.0, 0.0), 4, Vector3.UP, 2)
	_add_fixture("medium_flat", _plate(Vector3i.ZERO, 40, 3, false), Vector3(0.0, -1.0, 0.0), 16, Vector3.UP, 2)
	_add_fixture("medium_rough", _plate(Vector3i.ZERO, 40, 3, true), Vector3(0.0, -1.0, 0.0), 16, Vector3.UP, 2)
	_add_fixture("large_flat", _plate(Vector3i.ZERO, 40, 3, false), Vector3(0.0, -1.0, 0.0), 32, Vector3.UP, 0.2)
	_add_fixture("large_rough", _plate(Vector3i.ZERO, 40, 3, true), Vector3(0.0, -1.0, 0.0), 32, Vector3.UP, 0.2)
	_add_fixture("wall_oblique", _wall(Vector3i.ZERO, 40, 3), Vector3(0.0, 0.0, 0.0), 16, Vector3.RIGHT, 0.3)
	_add_fixture("negative_flat", _plate(Vector3i(-40, -40, -40), 40, 3, false), Vector3(-40.0, -41.0, -40.0), 16, Vector3.UP, 2)
	_add_fixture("sparse_columns", _columns(), Vector3(0.0, -1.0, 0.0), 16, Vector3.UP, 2)


func _add_fixture(label: String, frame: VoxelFrame, center: Vector3, radius: int, normal: Vector3, passes: int) -> void:
	var patch := _patch(frame, center, radius, 0.5, normal)
	_fixtures[label] = {
		"frame": frame,
		"cells": patch["cells"],
		"weights": patch["weights"],
		"radius": radius,
		"passes": passes,
	}
	_order.append(label)


func _fixture(label: String) -> Dictionary:
	_build_fixtures()
	return _fixtures[label]


# Returns a solid plate from -size to size in x and z. The plate is [param
# layers] cells thick and ends one cell below the origin. A rough plate lowers
# the top of one column in three, so a candidate set follows a stepped surface.
func _plate(center: Vector3i, size: int, layers: int, rough: bool) -> VoxelFrame:
	var cells := {}
	for x in range(center.x - size, center.x + size + 1):
		for z in range(center.z - size, center.z + size + 1):
			var top := center.y - 1
			if rough and (x + z) % 3 == 0:
				top -= 1
			for y in range(top - layers + 1, top + 1):
				cells[Vector3i(x, y, z)] = _material_for(x, z)
	return _frame_of(cells)


# Returns a solid half-space that ends at the origin plane in x, so the patch
# sits on a vertical wall and reads the surface along the x axis.
func _wall(center: Vector3i, size: int, layers: int) -> VoxelFrame:
	var cells := {}
	for x in range(center.x - layers + 1, center.x + 1):
		for y in range(center.y - size, center.y + size + 1):
			for z in range(center.z - size, center.z + size + 1):
				cells[Vector3i(x, y, z)] = _material_for(y, z)
	return _frame_of(cells)


# Returns nine isolated columns inside a radius-16 disc. The columns never touch
# a neighbor kernel, so the candidate set is scattered and the box between them
# holds many empty cells.
func _columns() -> VoxelFrame:
	var cells := {}
	for entry: Vector3i in [Vector3i(0, 0, 0), Vector3i(12, 0, 0), Vector3i(-12, 0, 0), Vector3i(0, 0, 12), Vector3i(0, 0, -12), Vector3i(9, 0, 9), Vector3i(-9, 0, -9), Vector3i(9, 0, -9), Vector3i(-9, 0, 9)]:
		for y in range(entry.y - 2, entry.y + 1):
			cells[Vector3i(entry.x, y, entry.z)] = _material_for(entry.x, entry.z)
	return _frame_of(cells)


func _frame_of(cells: Dictionary) -> VoxelFrame:
	var frame := VoxelFrame.new()
	frame.set_cells(cells, null, null)
	return frame


# A small set of distinct materials, so a filled cell inherits a real local
# material and the parity check covers the material lookup.
func _material_for(x: int, z: int) -> PackedFloat32Array:
	var key := Vector2i(x % 7, z % 5)
	if not _materials.has(key):
		_materials[key] = VoxelFrame.material(Color(float(key.x) / 7.0, float(key.y) / 5.0, 0.5, 1.0))
	return _materials[key]


# Returns the candidate cells and the weights of one Smooth patch. The rule is
# the tool's: a disc footprint, the top surface along the signed layer axis, and
# the two cells above and below each surface cell. The strongest weight wins when
# two columns reach one cell.
func _patch(frame: VoxelFrame, center: Vector3, radius: int, falloff: float, normal: Vector3) -> Dictionary:
	var axis := TerrainGeometry.dominant_axis(normal)
	var cardinal := Vector3.ZERO
	cardinal[axis] = 1.0 if normal[axis] >= 0.0 else -1.0
	var tangent_u := Vector3.ZERO
	var tangent_v := Vector3.ZERO
	tangent_u[(axis + 1) % 3] = 1.0
	tangent_v[(axis + 2) % 3] = 1.0
	var depth := mini(64, maxi(8, radius * 2))
	var region := {}
	for entry in TerrainGeometry.disk_offsets(radius):
		var weight := VoxelFalloff.weight_at(entry["distance"], float(radius), falloff, TerrainGeometry.disk_inner(radius))
		if weight <= 0.0:
			continue
		var point: Vector3 = center + float(entry["u"]) * tangent_u + float(entry["v"]) * tangent_v
		var surface := TerrainGeometry.surface_along(frame, point, cardinal, depth, {})
		if surface == VoxelPicking.NONE:
			continue
		for step in range(-REACH, REACH + 1):
			var cell := surface
			cell[axis] += step
			region[cell] = maxf(float(region.get(cell, 0.0)), weight)
	var cells := []
	var weights := {}
	for cell: Vector3i in region:
		cells.append(cell)
		weights[cell] = float(region[cell])
	cells.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return a.y < b.y if a.y != b.y else (a.z < b.z if a.z != b.z else a.x < b.x))
	return {"cells": cells, "weights": weights}


# --- Parity -----------------------------------------------------------------

func _expect_parity() -> void:
	_build_fixtures()
	expect(_fixtures.size() == 8, "the fixture set holds every measured shape")
	_superset_misses = 0
	_decision_misses = 0
	_published = 0
	_removals = 0
	_fills = 0
	_first_miss = ""
	step("Given every fixture gathered by both paths", func():
		for label: String in _order:
			var fixture: Dictionary = _fixtures[label]
			var reference_job: Variant = _job("reference", fixture["frame"], fixture)
			var production_job: Variant = _job("production", fixture["frame"], fixture)
			var cells: Array = fixture["cells"]
			var reference_occupied = reference_job._occupancy(cells)
			var production_occupied = production_job._occupancy(cells)
			expect(reference_occupied != null and production_occupied != null, "%s gathers an occupancy on both paths" % label)
			for point: Vector3i in reference_occupied:
				if not (production_occupied as Dictionary).has(point):
					_superset_misses += 1
			# Run both jobs on their own snapshot and compare the published work.
			reference_job.edited_frame = (fixture["frame"] as VoxelFrame).copy_frame()
			production_job.edited_frame = (fixture["frame"] as VoxelFrame).copy_frame()
			reference_job.run()
			production_job.run()
			fixture["changed"] = (reference_job.applied_cells as Dictionary).size()
			if not reference_job.changed_chunks.is_empty():
				_published += 1
			for cell: Vector3i in reference_job.applied_cells:
				if VoxelFrame.is_empty(reference_job.applied_cells[cell]):
					_removals += 1
				else:
					_fills += 1
			var mismatch := _job_mismatch(reference_job, production_job)
			if mismatch != "":
				_decision_misses += 1
				if _first_miss == "":
					_first_miss = "%s %s" % [label, mismatch]
	)
	step("Then the box scan holds every cell the rounding reads", func():
		expect(_superset_misses == 0, "every reference occupancy cell is in the gathered set")
	)
	step("Then both paths publish the same cells and materials", func():
		expect(_decision_misses == 0, "every fixture keeps its decisions%s" % ("" if _first_miss == "" else " (first: %s)" % _first_miss))
		expect(_published >= 2, "the rough fixtures publish their changed chunks")
		expect(_removals > 0 and _fills > 0, "the parity covers removed and filled cells")
		print("MEASURE terrain_occupancy parity: fixtures=%d published=%d removals=%d fills=%d changed=%s superset_misses=%d decision_misses=%d" % [
			_fixtures.size(), _published, _removals, _fills, str(_changed_counts()), _superset_misses, _decision_misses,
		])
	)


# The published cell count of every fixture, so the report shows that the
# decision parity covers a real change and not only a no-op.
func _changed_counts() -> Array:
	var counts := []
	for label: String in _order:
		counts.append("%s=%d" % [label, int(_fixtures[label]["changed"])])
	return counts


# Returns a description of the first difference between two finished jobs, or an
# empty string when they agree.
func _job_mismatch(reference_job: Variant, production_job: Variant) -> String:
	if reference_job.cancelled or production_job.cancelled:
		return "a job cancelled"
	if reference_job.changed_chunks != production_job.changed_chunks:
		return "changed chunks"
	if reference_job.applied_cells != production_job.applied_cells:
		return "applied cells"
	if reference_job.edited_frame.count() != production_job.edited_frame.count():
		return "voxel count"
	if reference_job.edited_frame.get_bounds() != production_job.edited_frame.get_bounds():
		return "frame bounds"
	if reference_job.edited_frame.chunks.keys() != production_job.edited_frame.chunks.keys():
		return "chunk set"
	if not VoxelEditTransaction._chunks_equal(reference_job.edited_frame.capture(), production_job.edited_frame.capture()):
		return "full frame materials"
	return ""


func _expect_halo_bounds() -> void:
	step("Given a kernel that crosses negative chunk boundaries", func():
		var center := Vector3i(-16, -16, -16)
		var changes := {}
		for x in range(-2, 3):
			for y in range(-2, 3):
				for z in range(-2, 3):
					changes[center + Vector3i(x, y, z)] = VoxelFrame.material(Color.RED)
		var source := _frame_of(changes)
		for radius in [0, 1, 2]:
			var reference := REFERENCE.new_job()
			var production := TERRAIN.SmoothJob.new()
			reference.edited_frame = source.copy_frame()
			production.edited_frame = source.copy_frame()
			reference.radius = radius
			production.radius = radius
			var expected: Dictionary = reference._occupancy([center])
			var actual: Dictionary = production._occupancy([center])
			expect(actual == expected, "radius %d preserves the normalized kernel halo" % radius)
	)
	step("When two candidates are very far apart", func():
		var distant := Vector3i(1 << 24, 0, 0)
		var source := _frame_of({Vector3i.ZERO: VoxelFrame.material(Color.RED), distant: VoxelFrame.material(Color.BLUE)})
		var reference := REFERENCE.new_job()
		var production := TERRAIN.SmoothJob.new()
		reference.edited_frame = source.copy_frame()
		production.edited_frame = source.copy_frame()
		var cells := [Vector3i.ZERO, distant]
		expect(production._occupancy(cells) == reference._occupancy(cells), "distant cells keep the exact sparse gather")
		expect(production.gather_reads == 54, "the sparse guard reads only two kernels")
	)
	step("When a rough sloped patch crosses several chunks", func():
		var changes := {}
		for x in range(-8, 9):
			for z in range(-8, 9):
				for y in range(-8, floori(float(x) * 0.5) + 1):
					changes[Vector3i(x, y, z)] = _material_for(x, z)
		changes[Vector3i(0, 1, 0)] = VoxelFrame.material(Color.BLUE)
		var source := _frame_of(changes)
		var before := source.capture()
		var patch := _patch(source, Vector3(0, 1, 0), 6, 0.5, Vector3(-0.5, 1, 0).normalized())
		patch["passes"] = 2
		var reference = _job("reference", source.copy_frame(), patch)
		var production = _job("production", source.copy_frame(), patch)
		reference.run()
		production.run()
		expect(not reference.applied_cells.is_empty(), "the sloped fixture changes real voxels")
		expect(_job_mismatch(reference, production).is_empty(), "the sloped patch preserves decisions and full materials")
		expect(VoxelEditTransaction._chunks_equal(before, source.capture()), "the gather and writes preserve the source snapshot")
	)


# --- Query counts -----------------------------------------------------------

func _ensure_stats() -> void:
	_build_fixtures()
	for label: String in _order:
		var fixture: Dictionary = _fixtures[label]
		if fixture.has("stats"):
			continue
		var cells: Array = fixture["cells"]
		var reference_job: Variant = _job("reference", fixture["frame"], fixture)
		var production_job: Variant = _job("production", fixture["frame"], fixture)
		var reference_occupied = reference_job._occupancy(cells)
		var production_occupied = production_job._occupancy(cells)
		var stats := _query_stats(fixture)
		stats["lookups"] = reference_job.lookups
		stats["reads"] = production_job.gather_reads
		stats["box"] = production_job.gather_reads != reference_job.lookups
		stats["occupied_old"] = (reference_occupied as Dictionary).size()
		stats["occupied_new"] = (production_occupied as Dictionary).size()
		fixture["stats"] = stats


# The unique read positions and the box volume of one fixture, both computed from
# the candidate set alone.
func _query_stats(fixture: Dictionary) -> Dictionary:
	var cells: Array = fixture["cells"]
	var offsets: Array = SmoothOperation.kernel_offsets(SmoothOperation.KERNEL_RADIUS)
	var unique := {}
	var low: Vector3i = cells[0]
	var high: Vector3i = cells[0]
	for cell: Vector3i in cells:
		low = low.min(cell)
		high = high.max(cell)
		for offset: Vector3i in offsets:
			unique[cell + offset] = true
	low -= Vector3i.ONE
	high += Vector3i.ONE
	var volume := (high.x - low.x + 1) * (high.y - low.y + 1) * (high.z - low.z + 1)
	return {"cells": cells.size(), "unique": unique.size(), "volume": volume}


# --- Cancellation -----------------------------------------------------------

# One production job that cancels itself at a named checkpoint.
class CancelJob extends TERRAIN.SmoothJob:
	var stops_after := 0
	var checks := 0

	func checkpoint(completed: int) -> bool:
		checks += 1
		if checks > stops_after:
			cancel()
		return super.checkpoint(completed)


func _expect_cancellation() -> void:
	_ensure_stats()
	var fixture: Dictionary = _fixture("large_rough")
	var cells: Array = fixture["cells"]
	var source: VoxelFrame = fixture["frame"]
	var before := source.count()
	# The candidate scan checks once per OCCUPANCY_READ_CHECKPOINT candidates and
	# the box scan checks once per chunk. The stop lands two chunk checks into the
	# box scan.
	var candidate_checks := cells.size() / TERRAIN.OCCUPANCY_READ_CHECKPOINT
	var stops_after := candidate_checks + 2
	var job := CancelJob.new()
	job.edited_frame = source.copy_frame()
	job.fields = _fields(fixture)
	job.passes = int(fixture["passes"])
	
	job.radius = SmoothOperation.KERNEL_RADIUS
	job.stops_after = stops_after
	var started := Time.get_ticks_usec()
	var gathered = job._occupancy(cells)
	var stopped_us := Time.get_ticks_usec() - started
	var full := CancelJob.new()
	full.edited_frame = source.copy_frame()
	full.fields = _fields(fixture)
	full.passes = int(fixture["passes"])
	
	full.radius = SmoothOperation.KERNEL_RADIUS
	full.stops_after = 100000
	started = Time.get_ticks_usec()
	full._occupancy(cells)
	var full_us := Time.get_ticks_usec() - started
	step("Given the maximum rough patch on the box path", func():
		expect(fixture["stats"]["box"], "the cancellation fixture takes the box scan")
	)
	step("When a job cancels two chunk checks into the box scan", func():
		expect(gathered == null, "the cancelled gather returns null")
		expect(job.checks == stops_after + 1, "the gather stops at the requested checkpoint")
		expect(job.checks > candidate_checks + 1, "the stop lands inside the box scan")
		expect(job.gather_reads > 0 and job.gather_reads < int(fixture["stats"]["reads"]), "the stopped scan made only part of the reads")
		print("MEASURE terrain_occupancy cancel: cells=%d stops_after=%d checks=%d reads=%d of %d stopped %d us of a full %d us gather" % [
			cells.size(), stops_after, job.checks, job.gather_reads, int(fixture["stats"]["reads"]), stopped_us, full_us,
		])
	)
	step("When the same job runs from its entry", func():
		var entry := CancelJob.new()
		entry.edited_frame = source.copy_frame()
		entry.fields = _fields(fixture)
		entry.passes = int(fixture["passes"])
		
		entry.radius = SmoothOperation.KERNEL_RADIUS
		entry.stops_after = 0
		entry.run()
		expect(entry.cancelled, "the pre-cancelled job reports its cancellation")
		expect(entry.changed_chunks.is_empty(), "the pre-cancelled job writes nothing")
		expect(entry.changed_chunks.is_empty(), "the pre-cancelled job publishes no chunk")
	)
	step("When a full job runs on the same fixture", func():
		var done := CancelJob.new()
		done.edited_frame = source.copy_frame()
		done.fields = _fields(fixture)
		done.passes = int(fixture["passes"])
		
		done.radius = SmoothOperation.KERNEL_RADIUS
		done.stops_after = 100000
		done.run()
		expect(not done.cancelled, "the uncancelled job completes")
	)
	step("Then the cancelled jobs left the source untouched", func():
		expect(source.count() == before, "a cancelled gather writes no cell")
	)


# --- Benchmark --------------------------------------------------------------

func _benchmark() -> void:
	_ensure_stats()
	var totals := {"gather_old": 0, "gather_new": 0, "job_old": 0, "job_new": 0}
	step("Given every fixture and a warmed process", func():
		expect(_fixtures.size() == 8, "the fixture set holds every measured shape")
	)
	step("When both paths alternate in one process", func():
		for label: String in _order:
			var medians := _measure_fixture(label)
			for key: String in totals:
				totals[key] += int(medians[key])
	)
	step("Then the measured medians are reported", func():
		print("MEASURE terrain_occupancy total: gather old %d us new %d us gain %.2fx, job old %d us new %d us gain %.2fx" % [
			totals["gather_old"], totals["gather_new"],
			float(totals["gather_old"]) / maxf(1.0, float(totals["gather_new"])),
			totals["job_old"], totals["job_new"],
			float(totals["job_old"]) / maxf(1.0, float(totals["job_new"])),
		])
	)
	step("Then the box scan is the measured win at every brush size", func():
		for label: String in _order:
			var stats: Dictionary = _fixtures[label]["stats"]
			var medians: Dictionary = _fixtures[label]["medians"]
			if not stats["box"]:
				continue
			expect(float(medians["job_gain"]) >= 1.2, "%s keeps a whole-job gain of at least 1.2x" % label)
	)


func _measure_fixture(label: String) -> Dictionary:
	var fixture: Dictionary = _fixture(label)
	var source: VoxelFrame = fixture["frame"]
	var cells: Array = fixture["cells"]
	var old_frames: Array[VoxelFrame] = []
	var new_frames: Array[VoxelFrame] = []
	for index in AB_SAMPLES + AB_WARMUPS:
		old_frames.append(source.copy_frame())
		new_frames.append(source.copy_frame())
	var reference_gather: Variant = _job("reference", source, fixture)
	var production_gather: Variant = _job("production", source, fixture)
	var gather_old: Array[int] = []
	var gather_new: Array[int] = []
	var job_old: Array[int] = []
	var job_new: Array[int] = []
	for warmup in AB_WARMUPS:
		_time_gather(reference_gather, cells)
		_time_gather(production_gather, cells)
		_time_run(_job("reference", old_frames[warmup], fixture))
		_time_run(_job("production", new_frames[warmup], fixture))
	for sample in AB_SAMPLES:
		var index := sample + AB_WARMUPS
		if sample % 2 == 0:
			gather_old.append(_time_gather(reference_gather, cells))
			gather_new.append(_time_gather(production_gather, cells))
			job_old.append(_time_run(_job("reference", old_frames[index], fixture)))
			job_new.append(_time_run(_job("production", new_frames[index], fixture)))
		else:
			job_new.append(_time_run(_job("production", new_frames[index], fixture)))
			job_old.append(_time_run(_job("reference", old_frames[index], fixture)))
			gather_new.append(_time_gather(production_gather, cells))
			gather_old.append(_time_gather(reference_gather, cells))
	var medians := {
		"gather_old": _median(gather_old),
		"gather_new": _median(gather_new),
		"job_old": _median(job_old),
		"job_new": _median(job_new),
	}
	medians["gather_gain"] = float(medians["gather_old"]) / maxf(1.0, float(medians["gather_new"]))
	medians["job_gain"] = float(medians["job_old"]) / maxf(1.0, float(medians["job_new"]))
	fixture["medians"] = medians
	var stats: Dictionary = fixture["stats"]
	print("MEASURE terrain_occupancy A/B %s: cells=%d radius=%d path=%s lookups=%d reads=%d | gather old %d us new %d us gain %.2fx | job old %d us new %d us gain %.2fx | occupied old %d new %d | samples %d/%d" % [
		label, cells.size(), int(fixture["radius"]), "box" if stats["box"] else "exact",
		int(stats["lookups"]), int(stats["reads"]),
		medians["gather_old"], medians["gather_new"], medians["gather_gain"],
		medians["job_old"], medians["job_new"], medians["job_gain"],
		int(stats["occupied_old"]), int(stats["occupied_new"]), gather_old.size(), gather_new.size(),
	])
	return medians


# --- Shared helpers ---------------------------------------------------------

func _fields(fixture: Dictionary) -> Array:
	return [{
		"cells": fixture["cells"],
		"weights": (fixture["weights"] as Dictionary).duplicate(),
	}]


func _job(path: String, frame: VoxelFrame, fixture: Dictionary) -> Variant:
	var job: Variant = REFERENCE.new_job() if path == "reference" else TERRAIN.SmoothJob.new()
	job.edited_frame = frame
	job.fields = _fields(fixture)
	job.passes = int(fixture["passes"])
	
	job.radius = SmoothOperation.KERNEL_RADIUS
	job.remove_threshold = SmoothOperation.REMOVE_THRESHOLD
	job.add_threshold = SmoothOperation.ADD_THRESHOLD
	return job


func _time_gather(job: Variant, cells: Array) -> int:
	var started := Time.get_ticks_usec()
	var occupied = job._occupancy(cells)
	_sink += (occupied as Dictionary).size() if occupied != null else -1
	return Time.get_ticks_usec() - started


func _time_run(job: Variant) -> int:
	var started := Time.get_ticks_usec()
	job.run()
	_sink += job.changed_chunks.size()
	return Time.get_ticks_usec() - started


func _median(samples: Array[int]) -> int:
	var sorted := samples.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]
