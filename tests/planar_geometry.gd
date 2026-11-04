extends "res://tests/test.gd"

# Planar region geometry in one process: the cleanup differential and benchmark,
# the compact box path parity, and the region coverage checks.
#
# The production region must match the frozen reference on every nonempty
# three-by-three mask and on edge fixtures, with and without prepared loops. The
# benchmark compares a frozen whole-surface build with the production one on
# independent group copies. Run one process:
#
#   godot --path . res://tests/planar_geometry.tscn
#
# Each test keeps the steps and checks of its original scene. The user arguments
# after `--` name the tests to run, so an old scene name still selects its own
# test.

const REGION := preload("res://Globals/Rendering/VoxelPlanarRegion.gd")
const REFERENCE := preload("res://tests/planar_cleanup_reference.gd")
const SURFACE := preload("res://Globals/Rendering/VoxelSurface.gd")
const SURFACE_REFERENCE := preload("res://tests/planar_cleanup_surface_reference.gd")
const ATLAS := preload("res://Globals/Rendering/VoxelAtlas.gd")
const BUILDER := preload("res://Globals/Rendering/VoxelMeshBuilder.gd")

const REPEATS := 9
const WARMUP := 2

# planar_cleanup state.
var cases: Array[Dictionary] = []
var prepared_cases := 0
var parity_error := ""
var cleanup_prepared_error := ""
var cancel_error := ""
var counts := {}

# planar_paths state.
var paths_cases: Array[Dictionary] = []
var paths_labels: PackedStringArray = []
var ring7 := {}
var plate := {}
var solid16 := {}
var diagonal_line := {}
var sparse_pair := {}
var wall80 := {}
var paths_protected := {}
var box_error := ""
var limit_error := ""
var square_error := ""
var paths_prepared_error := ""
var simplify_error := ""

# planar_regions state.
var region_cases: Array[Dictionary] = []
var region_meshes: Array[Array] = []
var mask_error := ""
var region_protected := {}


func _ready() -> void:
	timeout = 300.0
	test("planar cleanup parity and performance", _planar_cleanup, "planar_cleanup")
	timeout = 120.0
	test("compact box paths match the dictionary paths", _planar_paths, "planar_paths")
	timeout = 30.0
	test("planar regions preserve occupied cells, holes, and boundary vertices", _planar_regions, "planar_regions")


# Each test starts from fresh group state, so a test runs alone or in any order.
func _setup_test() -> void:
	cases = []
	prepared_cases = 0
	parity_error = ""
	cleanup_prepared_error = ""
	cancel_error = ""
	counts = {}
	paths_cases = []
	paths_labels = PackedStringArray()
	ring7 = {}
	plate = {}
	solid16 = {}
	diagonal_line = {}
	sparse_pair = {}
	wall80 = {}
	paths_protected = _protected_collinear()
	box_error = ""
	limit_error = ""
	square_error = ""
	paths_prepared_error = ""
	simplify_error = ""
	region_cases = []
	region_meshes = []
	mask_error = ""
	region_protected = _protected_collinear()


# --- planar_cleanup -----------------------------------------------------------

func _planar_cleanup() -> void:
	step("Given every nonempty three-by-three mask and the edge fixtures", _build_cases)
	step("When the production and frozen region paths run on each case", _compare_all)
	step("Then every polygon point, index, and order matches the frozen reference", _report_parity)
	step("Then a perturbed polygon fails the differential check", _negative_control)
	step("Then cancellation at entry and during work returns no polygons", _cancellation)
	step("When the material-rich fixture is counted", _count_workload)
	step("Then the frozen and production whole-surface builds report their medians", _benchmark)


func _build_cases() -> void:
	cases.clear()
	for mask in range(1, 512):
		_add_case(_mask_cells(mask), {}, "mask %d" % mask)
	_add_case(_rectangle(Vector2i.ZERO, Vector2i(7, 4)), _protected_collinear(), "protected collinear rectangle")
	_add_case({Vector2i(-3, -3): true, Vector2i(4, 4): true}, {}, "disconnected cells")
	_add_case(_diagonal_contacts(), {}, "diagonal contacts")
	_add_case(_holes(), {}, "plate with two holes")
	_add_case(_notch(), {}, "corner notch")
	_add_case(_rectangle(Vector2i(-7, -5), Vector2i(9, 5)), {}, "negative coordinates")
	_add_case(_rectangle(Vector2i(4090, 4090), Vector2i(4, 4)), {}, "near 4096")
	_add_case({Vector2i(4096, 4096): true}, {}, "single cell at 4096")
	_add_case(_wall80(), {}, "tall wall")
	_add_case(_sparse_pair(), {}, "sparse pair")
	_add_case(_rectangle(Vector2i.ZERO, Vector2i(64, 2)), {}, "width limit sixty-four")
	_add_case(_rectangle(Vector2i.ZERO, Vector2i(65, 2)), {}, "width beyond sixty-four")
	_add_case(_isolated_cells(), {}, "isolated cells")
	_add_case(_isolated_cells(), {Vector2i(0, 0): true, Vector2i(8, 8): true}, "isolated cells with protected corners")
	_add_case(_rectangle(Vector2i.ZERO, Vector2i(16, 16)), {}, "solid sixteen by sixteen")
	_add_case({Vector2i.ZERO: true}, {}, "single cell")
	expect(cases.size() == 511 + 16, "the case list holds every mask and sixteen edge fixtures")


func _compare_all() -> void:
	parity_error = ""
	cleanup_prepared_error = ""
	prepared_cases = 0
	for entry: Dictionary in cases:
		var cells: Dictionary = entry["cells"]
		var protected: Dictionary = entry["protected"]
		var label: String = entry["label"]
		var plain: Array = REGION.triangulate(cells, protected)
		var reference: Array = REFERENCE.triangulate(cells, protected)
		var error := _same_output(plain, reference)
		if not error.is_empty() and parity_error.is_empty():
			parity_error = "%s: %s" % [label, error]
		var loops: Array[PackedVector2Array] = REGION.raw_loops(cells)
		if loops.is_empty():
			continue
		prepared_cases += 1
		var prepared: Array = REGION.triangulate(cells, protected, Callable(), loops)
		var prepared_reference: Array = REFERENCE.triangulate(cells, protected, Callable(), loops)
		var prepared_problem := _same_output(prepared, prepared_reference)
		if not prepared_problem.is_empty() and cleanup_prepared_error.is_empty():
			cleanup_prepared_error = "%s prepared: %s" % [label, prepared_problem]
		var cross_problem := _same_output(plain, prepared)
		if not cross_problem.is_empty() and cleanup_prepared_error.is_empty():
			cleanup_prepared_error = "%s prepared versus plain: %s" % [label, cross_problem]


func _report_parity() -> void:
	expect(cases.size() >= 511, "every nonempty three-by-three mask is covered")
	expect(prepared_cases >= 511, "every mask also runs with prepared loops")
	expect(parity_error.is_empty(), "all %d cases match the frozen reference without prepared loops%s" % [cases.size(), _detail(parity_error)])
	expect(cleanup_prepared_error.is_empty(), "every prepared case matches the frozen reference and the plain path%s" % _detail(cleanup_prepared_error))


func _negative_control() -> void:
	var cells := _rectangle(Vector2i.ZERO, Vector2i(6, 3))
	var output: Array = REGION.triangulate(cells)
	var point_error := ""
	var index_error := ""
	var count_error := ""
	if output.size() > 0:
		var points: PackedVector2Array = output[0]["points"]
		var swapped: PackedVector2Array = points.duplicate()
		var first := swapped[0]
		swapped[0] = swapped[1]
		swapped[1] = first
		var changed_points: Array = _copy_output(output)
		changed_points[0] = {"points": swapped, "indices": output[0]["indices"]}
		point_error = _same_output(output, changed_points)
		var indices: PackedInt32Array = output[0]["indices"]
		var swapped_indices: PackedInt32Array = indices.duplicate()
		swapped_indices[0] = (swapped_indices[0] + 1) % points.size()
		var changed_indices: Array = _copy_output(output)
		changed_indices[0] = {"points": points, "indices": swapped_indices}
		index_error = _same_output(output, changed_indices)
		var shorter: Array = _copy_output(output)
		shorter.resize(output.size() - 1)
		count_error = _same_output(output, shorter)
	expect(not point_error.is_empty(), "the differential check detects a changed polygon point")
	expect(not index_error.is_empty(), "the differential check detects a changed triangle index")
	expect(not count_error.is_empty(), "the differential check detects a changed polygon count")


func _cancellation() -> void:
	cancel_error = ""
	var cells := _rectangle(Vector2i.ZERO, Vector2i(11, 9))
	var loops: Array[PackedVector2Array] = REGION.raw_loops(cells)
	var reject := func(_progress: int) -> bool: return false
	var entry_plain: Array = REGION.triangulate(cells, {}, reject)
	var entry_prepared: Array = REGION.triangulate(cells, {}, reject, loops)
	var entry_reference: Array = REFERENCE.triangulate(cells, {}, reject)
	if not entry_plain.is_empty() or not entry_prepared.is_empty() or not entry_reference.is_empty():
		cancel_error = "a checkpoint rejected at entry returned polygons"
	var isolated := _isolated_cells()
	var isolated_loops: Array[PackedVector2Array] = REGION.raw_loops(isolated)
	if not REGION._all_unit_squares(isolated_loops):
		cancel_error = "the isolated-cell fixture did not use the unit-square shortcut"
	var during_ok := true
	for stop in [1, 2, 3, 5, 9, 25]:
		var calls := [0]
		var cancel := func(_progress: int) -> bool:
			calls[0] += 1
			return calls[0] != stop
		var output: Array = REGION.triangulate(isolated, {}, cancel, isolated_loops)
		if calls[0] >= stop and not output.is_empty():
			during_ok = false
		calls[0] = 0
		var general: Array = REGION.triangulate(cells, {}, cancel, loops)
		if calls[0] >= stop and not general.is_empty():
			during_ok = false
	var latch_calls := [0]
	var reject_after_first := func(_progress: int) -> bool:
		latch_calls[0] += 1
		return latch_calls[0] < 2
	var latched: Array = REGION.triangulate(isolated, {}, reject_after_first, isolated_loops)
	expect(cancel_error.is_empty(), "a checkpoint rejected at entry returns no polygons in either path")
	expect(during_ok, "a checkpoint rejected during the shortcut or the general path returns no polygons")
	expect(latched.is_empty(), "the shortcut does not restart after a mid-work rejection")


# --- Workload counts ----------------------------------------------------------

func _count_workload() -> void:
	var frame := _material_rich()
	var chunk := Vector3i(1, 1, 1)
	var snapshot := BUILDER._snapshot(frame, chunk, false)
	var colors: PackedColorArray = snapshot[0]
	var occupancy: PackedInt32Array = snapshot[1]
	var materials: PackedFloat32Array = snapshot[2]
	var planes: PackedInt32Array = snapshot[3]
	var builder: VoxelMeshBuilder = BUILDER.new()
	var groups: Dictionary = builder._collect_groups(colors, occupancy, materials, planes)
	var raw_loops := 0
	var squares := 0
	var holes := 0
	var shortcut_groups := 0
	var cell_total := 0
	for group_value in groups.values():
		var group: Dictionary = group_value
		var group_cells: Dictionary = group.cells
		cell_total += group_cells.size()
		var loops: Array[PackedVector2Array] = REGION.raw_loops(group_cells)
		raw_loops += loops.size()
		if not loops.is_empty() and REGION._all_unit_squares(loops):
			shortcut_groups += 1
		for loop: PackedVector2Array in loops:
			if REGION._unit_square(loop):
				squares += 1
			if REGION._twice_area(loop) < 0.0:
				holes += 1
	var always := func(_progress: int) -> bool: return true
	var protected: Dictionary = SURFACE._protect_groups(groups, always)
	var rounds := _mirror_rounds(groups, protected)
	counts = {
		"groups": groups.size(),
		"cells": cell_total,
		"loops": raw_loops,
		"squares": squares,
		"holes": holes,
		"shortcut_groups": shortcut_groups,
		"rounds": rounds,
	}
	print("MEASURE planar_cleanup workload: %d groups, %d cells, %d raw loops, %d unit squares, %d holes, %d shortcut groups, %d rounds" % [
		counts.groups, counts.cells, counts.loops, counts.squares, counts.holes, counts.shortcut_groups, counts.rounds,
	])
	expect(int(counts.squares) > 0, "the material-rich fixture holds unit-square loops")


# Mirrors VoxelSurface._triangulate_groups to count its passes. The result feeds
# the report only. Production still owns the real triangulation.
func _mirror_rounds(groups: Dictionary, protected: Dictionary) -> int:
	var protected_positions: Dictionary = protected.positions
	var protected_planes: Dictionary = protected.planes
	var rounds := 0
	while true:
		rounds += 1
		var added := {}
		for group_value in groups.values():
			var group: Dictionary = group_value
			var plane_protected: Dictionary = protected_planes[group.plane]
			group.polygons = REGION.triangulate(group.cells, plane_protected, Callable(), group.raw_loops)
			if group.polygons.is_empty():
				return rounds
			for polygon_value in group.polygons:
				var polygon: Dictionary = polygon_value
				for point: Vector2 in polygon.points:
					var corner := Vector3i((SURFACE._position(group.plane, point) * 2).round())
					if not protected_positions.has(corner):
						protected_positions[corner] = true
						added[corner] = true
		if added.is_empty():
			break
		SURFACE._protect(added, protected_planes)
	return rounds


# --- Whole-surface benchmark --------------------------------------------------

func _benchmark() -> void:
	_bench_finish("material-rich flat", _material_rich(), Vector3i(1, 1, 1), false)
	_bench_finish("material-rich smooth", _material_rich(), Vector3i(1, 1, 1), true)
	_bench_finish("uniform", _uniform(), Vector3i(1, 1, 1), false)
	_bench_finish("one-layer plate", _plate(), Vector3i(1, 0, 1), false)
	_bench_finish("hole-heavy plate", _hole_plate(), Vector3i(1, 0, 1), false)
	_bench_finish("sparse isolated chunk", _sparse(), Vector3i.ZERO, false)
	_bench_complete("material-rich flat", _material_rich(), Vector3i(1, 1, 1), false)
	_bench_complete("material-rich smooth", _material_rich(), Vector3i(1, 1, 1), true)


# The cleanup only: protection, triangulation, and emission.
func _bench_finish(name: String, frame: VoxelFrame, chunk: Vector3i, smooth: bool) -> void:
	var base: Array = _prepare_groups(frame, chunk, smooth)
	if base.is_empty():
		return
	var groups: Dictionary = base[0]
	var origin: Vector3 = base[1]
	var corner: Variant = base[2]
	for index in WARMUP:
		_time_finish(true, _copy_groups(groups), frame, origin, smooth, corner)
		_time_finish(false, _copy_groups(groups), frame, origin, smooth, corner)
	var old_times := PackedInt64Array()
	var new_times := PackedInt64Array()
	var parity := true
	var vertices := 0
	for repeat in REPEATS:
		var old_first := repeat % 2 == 0
		var old_result: Array = []
		var new_result: Array = []
		var old_us := 0
		var new_us := 0
		if old_first:
			old_result = _time_finish(true, _copy_groups(groups), frame, origin, smooth, corner)
			new_result = _time_finish(false, _copy_groups(groups), frame, origin, smooth, corner)
		else:
			new_result = _time_finish(false, _copy_groups(groups), frame, origin, smooth, corner)
			old_result = _time_finish(true, _copy_groups(groups), frame, origin, smooth, corner)
		old_us = int(old_result[0])
		new_us = int(new_result[0])
		old_times.append(old_us)
		new_times.append(new_us)
		if not _same_arrays(old_result[1], new_result[1]):
			parity = false
		vertices = new_result[1][Mesh.ARRAY_VERTEX].size()
	var old_median := _median(old_times)
	var new_median := _median(new_times)
	print("MEASURE planar_cleanup %s finish: old %d us, new %d us, gain %.1f%%, vertices %d" % [
		name, old_median, new_median, _gain(old_median, new_median), vertices,
	])
	expect(parity, "%s: the frozen and production cleanup emit identical arrays" % name)


# The complete surface build: cleanup, atlas bake, and UV finish.
func _bench_complete(name: String, frame: VoxelFrame, chunk: Vector3i, smooth: bool) -> void:
	var base: Array = _prepare_groups(frame, chunk, smooth)
	if base.is_empty():
		return
	var groups: Dictionary = base[0]
	var origin: Vector3 = base[1]
	var corner: Variant = base[2]
	for index in WARMUP:
		_time_complete(true, _copy_groups(groups), frame, origin, smooth, corner)
		_time_complete(false, _copy_groups(groups), frame, origin, smooth, corner)
	var old_times := PackedInt64Array()
	var new_times := PackedInt64Array()
	for repeat in REPEATS:
		if repeat % 2 == 0:
			old_times.append(_time_complete(true, _copy_groups(groups), frame, origin, smooth, corner))
			new_times.append(_time_complete(false, _copy_groups(groups), frame, origin, smooth, corner))
		else:
			new_times.append(_time_complete(false, _copy_groups(groups), frame, origin, smooth, corner))
			old_times.append(_time_complete(true, _copy_groups(groups), frame, origin, smooth, corner))
	var old_median := _median(old_times)
	var new_median := _median(new_times)
	print("MEASURE planar_cleanup %s run_groups: old %d us, new %d us, gain %.1f%%" % [
		name, old_median, new_median, _gain(old_median, new_median),
	])


# Build the groups once. Returns [groups, origin, corner_occupancy], or [] when
# the chunk has no exposed faces.
func _prepare_groups(frame: VoxelFrame, chunk: Vector3i, smooth: bool) -> Array:
	var snapshot := BUILDER._snapshot(frame, chunk, smooth)
	var colors: PackedColorArray = snapshot[0]
	var occupancy: PackedInt32Array = snapshot[1]
	var materials: PackedFloat32Array = snapshot[2]
	var planes: PackedInt32Array = snapshot[3]
	var builder: VoxelMeshBuilder = BUILDER.new()
	var groups: Dictionary = builder._collect_groups(colors, occupancy, materials, planes)
	if groups.is_empty():
		return []
	var origin := Vector3(chunk * VoxelFrame.CHUNK_SIZE)
	var corner: Variant = occupancy if smooth else null
	return [groups, origin, corner]


func _time_finish(reference: bool, groups: Dictionary, frame: VoxelFrame, origin: Vector3, smooth: bool, corner: Variant) -> Array:
	var always := func(_progress: int) -> bool: return true
	var bake: RefCounted = ATLAS.new()
	var started_us := Time.get_ticks_usec()
	var result: Array
	if reference:
		result = SURFACE_REFERENCE._finish(groups, frame, origin, bake, always, smooth, corner)
	else:
		result = SURFACE._finish(groups, frame, origin, bake, always, smooth, corner)
	return [Time.get_ticks_usec() - started_us, result]


func _time_complete(reference: bool, groups: Dictionary, frame: VoxelFrame, origin: Vector3, smooth: bool, corner: Variant) -> int:
	var started_us := Time.get_ticks_usec()
	if reference:
		var surface: RefCounted = SURFACE_REFERENCE.new()
		surface.run_groups(groups, frame, origin, Callable(), smooth, corner)
	else:
		var surface: RefCounted = SURFACE.new()
		surface.run_groups(groups, frame, origin, Callable(), smooth, corner)
	return Time.get_ticks_usec() - started_us


# A deep copy of the mutable groups, so each timed path owns its input.
func _copy_groups(groups: Dictionary) -> Dictionary:
	var out := {}
	for key in groups:
		var group: Dictionary = groups[key]
		out[key] = {
			"plane": group.plane,
			"material": group.material,
			"cells": group.cells.duplicate(),
			"normals": group.normals.duplicate(),
		}
	return out


func _copy_output(output: Array) -> Array:
	var out: Array = []
	for mesh: Dictionary in output:
		out.append({"points": mesh.points.duplicate(), "indices": mesh.indices.duplicate()})
	return out


# --- Comparison helpers -------------------------------------------------------

func _same_output(a: Array, b: Array) -> String:
	if a.size() != b.size():
		return "polygon count %d versus %d" % [a.size(), b.size()]
	for index in a.size():
		var a_points: PackedVector2Array = a[index]["points"]
		var b_points: PackedVector2Array = b[index]["points"]
		if a_points != b_points:
			return "polygon %d points differ" % index
		var a_indices: PackedInt32Array = a[index]["indices"]
		var b_indices: PackedInt32Array = b[index]["indices"]
		if a_indices != b_indices:
			return "polygon %d indices differ" % index
	return ""


func _same_arrays(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for array_type in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_INDEX, Mesh.ARRAY_TEX_UV]:
		if a[array_type] != b[array_type]:
			return false
	return true


func _median(values: PackedInt64Array) -> int:
	var sorted := values.duplicate()
	sorted.sort()
	if sorted.is_empty():
		return 0
	return sorted[sorted.size() / 2]


func _gain(old_us: int, new_us: int) -> float:
	if old_us <= 0:
		return 0.0
	return (old_us - new_us) * 100.0 / old_us


func _detail(error: String) -> String:
	return "" if error.is_empty() else " (%s)" % error


# --- planar_paths -------------------------------------------------------------

func _planar_paths() -> void:
	step("Given every nonempty three-by-three mask and the named regions", _build)
	step("When both paths run on each fixture", _compare)
	step("Then the paths agree and the compact limits hold", _report)


func _build() -> void:
	for mask in range(1, 512):
		_add(_mask_cells(mask), "mask %d" % mask)
	ring7 = _ring7()
	_add(ring7, "seven-by-seven ring with a three-by-three hole")
	plate = _holes()
	_add(plate, "eleven-by-nine plate with two holes")
	_add(_diagonal_contacts(), "three-cell diagonal")
	_add(_rectangle(Vector2i.ZERO, Vector2i(6, 4)), "six-by-four rectangle")
	solid16 = _rectangle(Vector2i.ZERO, Vector2i(16, 16))
	_add(solid16, "sixteen-by-sixteen rectangle")
	_add(_rectangle(Vector2i(40, -7), Vector2i(9, 5)), "nine-by-five rectangle at forty, minus seven")
	_add({Vector2i.ZERO: true}, "single cell")
	diagonal_line = {}
	for index in 16:
		diagonal_line[Vector2i(index, index)] = true
	_add(diagonal_line, "sixteen-cell diagonal line")
	sparse_pair = _sparse_pair()
	_add(sparse_pair, "sparse pair")
	# Taller than the row-mask width. Only the width is a mask, so a dense wall this
	# tall still belongs on the compact path.
	wall80 = _wall80()
	_add(wall80, "four-by-eighty wall")


func _compare() -> void:
	box_error = ""
	limit_error = ""
	square_error = ""
	paths_prepared_error = ""
	simplify_error = ""
	var compacted := 0
	for index in paths_cases.size():
		var cells := paths_cases[index]
		var box := REGION._compact(cells)
		if box == null:
			continue
		compacted += 1
		if REGION._box_loops(box, Callable()) != REGION._contours(cells, {}, Callable(), true):
			box_error = "%s differs" % paths_labels[index]
			break
	# Every fixture except the sparse pair and the diagonal line must use the
	# compact path. A limit that silently rejected them would make the compare
	# above vacuous.
	if box_error.is_empty() and compacted != paths_cases.size() - 2:
		box_error = "only %d of %d fixtures used the compact path" % [compacted, paths_cases.size()]
	_compare_limits()
	_compare_squares()
	for index in paths_cases.size():
		var cells := paths_cases[index]
		var plain := REGION.triangulate(cells, paths_protected, Callable())
		var prepared := REGION.triangulate(cells, paths_protected, Callable(), REGION.raw_loops(cells, Callable()))
		if plain != prepared:
			paths_prepared_error = "%s differs" % paths_labels[index]
			break
	for index in paths_cases.size():
		var cells := paths_cases[index]
		var simplified: Array[PackedVector2Array] = []
		for loop in REGION.raw_loops(cells):
			simplified.append(REGION._simplify(loop, {}))
		if simplified != REGION.contours(cells):
			simplify_error = "%s differs" % paths_labels[index]
			break


func _compare_limits() -> void:
	limit_error = ""
	if REGION._compact({}) != null:
		limit_error = "the empty region compacted"
		return
	for entry in [["the sparse pair", sparse_pair], ["the diagonal line", diagonal_line]]:
		if REGION._compact(entry[1]) != null:
			limit_error = "%s compacted" % entry[0]
			return
	var solid := REGION._compact(solid16)
	if solid == null:
		limit_error = "the sixteen-by-sixteen rectangle did not compact"
	elif solid.width != 16 or solid.height != 16:
		limit_error = "the sixteen-by-sixteen box is %d by %d" % [solid.width, solid.height]
	var ring := REGION._compact(ring7)
	if ring == null:
		limit_error = "the seven-by-seven ring did not compact"
	elif ring.width != 7 or ring.height != 7:
		limit_error = "the seven-by-seven box is %d by %d" % [ring.width, ring.height]
	var wall := REGION._compact(wall80)
	if wall == null:
		limit_error = "the four-by-eighty wall did not compact"
	elif wall.width != 4 or wall.height != 80:
		limit_error = "the four-by-eighty box is %d by %d" % [wall.width, wall.height]


func _compare_squares() -> void:
	square_error = ""
	var ccw := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	for rotation in 4:
		var loop := PackedVector2Array()
		for offset in 4:
			loop.append(ccw[(rotation + offset) % 4])
		if not REGION._unit_square(loop):
			square_error = "rotation %d of a counterclockwise unit square was rejected" % rotation
			return
	if REGION._unit_square(PackedVector2Array([Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)])):
		square_error = "a clockwise unit square was accepted"
	elif REGION._unit_square(PackedVector2Array([Vector2(0, 0), Vector2(2, 0), Vector2(2, 1), Vector2(0, 1)])):
		square_error = "a two-by-one rectangle was accepted"
	elif REGION._unit_square(PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)])):
		square_error = "a three-point loop was accepted"


func _report() -> void:
	expect(box_error.is_empty(), "the compact boundary walk matches the dictionary walk on every compacted fixture" + _detail(box_error))
	expect(limit_error.is_empty(), "the compact limit rejects the empty, sparse, and diagonal-line regions and sizes the dense boxes exactly" + _detail(limit_error))
	expect(square_error.is_empty(), "the unit square test accepts all four counterclockwise rotations and rejects clockwise, rectangular, and three-point loops" + _detail(square_error))
	expect(paths_prepared_error.is_empty(), "prepared raw loops triangulate the same as the dictionary path on every fixture" + _detail(paths_prepared_error))
	expect(simplify_error.is_empty(), "simplifying the raw loops gives the same contours on every fixture" + _detail(simplify_error))


func _add(cells: Dictionary, label: String) -> void:
	paths_cases.append(cells)
	paths_labels.append(label)


# --- planar_regions -----------------------------------------------------------

func _planar_regions() -> void:
	step("Given rings, separate contacts, sparse cells, and a protected rectangle", func():
		var ring := _ring7()
		var holes := _holes()
		var diagonal := _diagonal_contacts()
		var sparse := _sparse_pair()
		region_cases = [ring, holes, diagonal, sparse, _rectangle(Vector2i.ZERO, Vector2i(6, 3))]
	)
	step("When every nonempty three-by-three mask and each fixture is triangulated", func():
		var samples := _rectangle(Vector2i(-1, -1), Vector2i(5, 5))
		for mask in range(1, 512):
			var cells := _mask_cells(mask)
			var error := _check_mesh(cells, REGION.triangulate(cells), samples)
			if not error.is_empty() and mask_error.is_empty():
				mask_error = "mask %d: %s" % [mask, error]
		for index in region_cases.size():
			region_meshes.append(REGION.triangulate(region_cases[index], region_protected if index == 4 else {}))
	)
	step("Then all masks and fixtures have positive CCW triangles and exact cell coverage", func():
		expect(mask_error.is_empty(), "all 511 masks preserve area and occupied and empty cell centers" + _detail(mask_error))
		var ring_error := _check_mesh(region_cases[0], region_meshes[0], _rectangle(Vector2i(-1, -1), Vector2i(9, 9)))
		expect(ring_error.is_empty() and _conforming(region_meshes[0]), "the seven-by-seven ring retains its three-by-three hole and conforming cuts" + _detail(ring_error))
		var holes_error := _check_mesh(region_cases[1], region_meshes[1], _rectangle(Vector2i(-1, -1), Vector2i(13, 11)))
		expect(holes_error.is_empty() and _conforming(region_meshes[1]), "multiple holes retain exact coverage and conforming cut boundaries" + _detail(holes_error))
		var diagonal_error := _check_mesh(region_cases[2], region_meshes[2], _rectangle(Vector2i(-1, -1), Vector2i(5, 4)))
		expect(diagonal_error.is_empty() and REGION.contours(region_cases[2]).size() == 3, "diagonal contacts retain three separate contours and exact coverage" + _detail(diagonal_error))
		var sparse_samples := {Vector2i.ZERO: true}
		for cell: Vector2i in region_cases[3]:
			sparse_samples.merge(_rectangle(cell - Vector2i.ONE, Vector2i(3, 3)))
		var sparse_error := _check_mesh(region_cases[3], region_meshes[3], sparse_samples)
		expect(sparse_error.is_empty(), "cells at negative and positive 4096 retain exact sparse coverage" + _detail(sparse_error))
	)
	step("Then protected collinear points remain indexed without triangle edges crossing them", func():
		var used := {}
		for mesh: Dictionary in region_meshes[4]:
			for index: int in mesh.indices:
				used[Vector2i(mesh.points[index])] = true
		var retained := true
		for point in region_protected:
			retained = retained and used.has(point)
		var error := _check_mesh(region_cases[4], region_meshes[4], _rectangle(Vector2i(-1, -1), Vector2i(8, 5)))
		expect(retained and error.is_empty() and _conforming(region_meshes[4]), "all protected boundary points belong to positive triangles without skipped vertices" + _detail(error))
		var reverse := {}
		var keys := region_cases[0].keys()
		keys.reverse()
		for cell in keys:
			reverse[cell] = true
		var turns := REGION.contours(region_cases[4])
		expect(turns.size() == 1 and turns[0].size() == 4 and REGION.contours(reverse) == REGION.contours(region_cases[0]) and REGION.triangulate(reverse) == region_meshes[0], "contours contain only turns and outputs are independent of cell insertion order")
	)
	step("Then internal diagonal flips improve an uneven concave outline without adding geometry", func():
		var cells := _rectangle(Vector2i.ZERO, Vector2i(12, 8))
		for cell in _rectangle(Vector2i(3, 3), Vector2i(9, 5)):
			cells.erase(cell)
		var points: PackedVector2Array = REGION.contours(cells)[0]
		var initial := Geometry2D.triangulate_polygon(points)
		var output := REGION.triangulate(cells)
		var same_counts := output.size() == 1
		var before := _minimum_angle(points, initial)
		var after := 0.0
		if same_counts:
			same_counts = output[0].points == points and output[0].indices.size() == initial.size()
			after = _minimum_angle(output[0].points, output[0].indices)
		var error := _check_mesh(cells, output, _rectangle(Vector2i(-1, -1), Vector2i(14, 10)))
		var rectangle: PackedVector2Array = REGION.contours(region_cases[4])[0]
		var ties := Geometry2D.triangulate_polygon(rectangle)
		var stable := REGION._improve(rectangle, ties.duplicate(), Callable()) == ties
		var translated := PackedVector2Array()
		for point in points:
			translated.append(point + Vector2(4096, -4096))
		stable = stable and output.size() == 1 and REGION._improve(translated, initial.duplicate(), Callable()) == output[0].indices
		var calls := [0]
		var stop: int = initial.size() / 3 + 2
		var cancel := func(_progress):
			calls[0] += 1
			return calls[0] != stop
		var cancelled: bool = REGION._improve(points, initial.duplicate(), cancel).is_empty() and calls[0] == stop
		expect(same_counts and after > before + 0.000001 and error.is_empty() and _conforming(output) and output == REGION.triangulate(cells) and stable and cancelled, "internal flips improve angles and preserve counts, boundaries, ties, determinism, and cancellation" + _detail(error) + " (angles %.6f to %.6f)" % [before, after])
	)
	step("Then cancellation discards contours and partial triangulations", func():
		var contour_cancelled := true
		var mesh_cancelled := true
		for stop in [1, 10, 45, 80, 130, 200]:
			var calls := [0]
			var cancel := func(_progress):
				calls[0] += 1
				return calls[0] != stop
			var loops := REGION.contours(region_cases[0], cancel)
			if calls[0] >= stop:
				contour_cancelled = contour_cancelled and loops.is_empty()
			calls[0] = 0
			var output := REGION.triangulate(region_cases[0], {}, cancel)
			if calls[0] >= stop:
				mesh_cancelled = mesh_cancelled and output.is_empty()
		expect(contour_cancelled, "cancelled contour extraction returns no partial loops")
		expect(mesh_cancelled, "cancelled triangulation returns no partial polygons")
	)


func _check_mesh(cells: Dictionary, output: Array, samples: Dictionary) -> String:
	var triangles: Array[PackedVector2Array] = []
	var area := 0.0
	for mesh: Dictionary in output:
		var points: PackedVector2Array = mesh.points
		var indices: PackedInt32Array = mesh.indices
		if indices.size() % 3 != 0:
			return "incomplete triangle indices"
		for index in indices:
			if index < 0 or index >= points.size():
				return "triangle index outside the points"
		for offset in range(0, indices.size(), 3):
			var a := points[indices[offset]]
			var b := points[indices[offset + 1]]
			var c := points[indices[offset + 2]]
			var cross := (b - a).cross(c - a)
			if cross <= 0.0:
				return "nonpositive or clockwise triangle"
			area += cross * 0.5
			triangles.append(PackedVector2Array([a, b, c]))
	if area != cells.size():
		return "triangle area %s differs from cell count %s" % [area, cells.size()]
	if _boundary_units(output) != _cell_boundary(cells):
		return "triangle boundary differs from the occupied cell boundary"
	for cell: Vector2i in samples:
		var point := Vector2(cell) + Vector2(0.5, 0.5)
		var covered := false
		for triangle in triangles:
			if (triangle[1] - triangle[0]).cross(point - triangle[0]) >= 0.0 and (triangle[2] - triangle[1]).cross(point - triangle[1]) >= 0.0 and (triangle[0] - triangle[2]).cross(point - triangle[2]) >= 0.0:
				covered = true
				break
		if covered != cells.has(cell):
			return "incorrect coverage at cell %s" % cell
	return ""


func _boundary_units(output: Array) -> Dictionary:
	var boundary := {}
	for mesh: Dictionary in output:
		var points: PackedVector2Array = mesh.points
		var indices: PackedInt32Array = mesh.indices
		for offset in range(0, indices.size(), 3):
			for side in 3:
				var a := Vector2i(points[indices[offset + side]])
				var b := Vector2i(points[indices[offset + (side + 1) % 3]])
				var edge := Vector4i(a.x, a.y, b.x, b.y)
				var reverse := Vector4i(b.x, b.y, a.x, a.y)
				if boundary.has(reverse):
					boundary.erase(reverse)
				elif boundary.has(edge):
					return {"duplicate": true}
				else:
					boundary[edge] = true
	var units := {}
	for edge: Vector4i in boundary:
		var start := Vector2i(edge.x, edge.y)
		var delta := Vector2i(edge.z, edge.w) - start
		if delta.x != 0 and delta.y != 0:
			return {"diagonal": true}
		var direction := Vector2i(signi(delta.x), signi(delta.y))
		for offset in absi(delta.x) + absi(delta.y):
			var a := start + direction * offset
			var b := a + direction
			units[Vector4i(a.x, a.y, b.x, b.y)] = true
	return units


func _cell_boundary(cells: Dictionary) -> Dictionary:
	var boundary := {}
	for cell: Vector2i in cells:
		var corners := [cell, cell + Vector2i.RIGHT, cell + Vector2i.ONE, cell + Vector2i.DOWN]
		var neighbors := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
		for side in 4:
			if not cells.has(cell + neighbors[side]):
				var a: Vector2i = corners[side]
				var b: Vector2i = corners[(side + 1) % 4]
				boundary[Vector4i(a.x, a.y, b.x, b.y)] = true
	return boundary


func _minimum_angle(points: PackedVector2Array, indices: PackedInt32Array) -> float:
	var minimum := PI
	for offset in range(0, indices.size(), 3):
		for side in 3:
			var a := points[indices[offset + side]]
			var b := points[indices[offset + (side + 1) % 3]] - a
			var c := points[indices[offset + (side + 2) % 3]] - a
			minimum = minf(minimum, atan2(absf(b.cross(c)), b.dot(c)))
	return minimum


func _conforming(output: Array) -> bool:
	var vertices := {}
	var edges := []
	for mesh: Dictionary in output:
		var points: PackedVector2Array = mesh.points
		var indices: PackedInt32Array = mesh.indices
		for offset in range(0, indices.size(), 3):
			for side in 3:
				var a := points[indices[offset + side]]
				var b := points[indices[offset + (side + 1) % 3]]
				vertices[a] = true
				edges.append(PackedVector2Array([a, b]))
	for point: Vector2 in vertices:
		for edge: PackedVector2Array in edges:
			var delta := point - edge[0]
			var direction := edge[1] - edge[0]
			if delta.cross(direction) == 0.0 and delta.dot(direction) > 0.0 and delta.dot(direction) < direction.length_squared():
				return false
	return true


# --- Shared fixtures ----------------------------------------------------------

func _add_case(cells: Dictionary, protected: Dictionary, label: String) -> void:
	cases.append({"cells": cells, "protected": protected, "label": label})


# Every nonempty three-by-three mask, in the order the bit walk emits it.
func _mask_cells(mask: int) -> Dictionary:
	var cells := {}
	for bit in 9:
		if mask & (1 << bit):
			cells[Vector2i(bit % 3, bit / 3)] = true
	return cells


func _protected_collinear() -> Dictionary:
	return {Vector2i(1, 0): true, Vector2i(3, 0): true, Vector2i(6, 1): true, Vector2i(2, 3): true, Vector2i(0, 2): true}


func _rectangle(origin: Vector2i, size: Vector2i) -> Dictionary:
	var cells := {}
	for y in size.y:
		for x in size.x:
			cells[origin + Vector2i(x, y)] = true
	return cells


func _ring7() -> Dictionary:
	var cells := _rectangle(Vector2i.ZERO, Vector2i(7, 7))
	for cell in _rectangle(Vector2i(2, 2), Vector2i(3, 3)):
		cells.erase(cell)
	return cells


func _holes() -> Dictionary:
	var cells := _rectangle(Vector2i.ZERO, Vector2i(11, 9))
	for hole in [_rectangle(Vector2i(2, 2), Vector2i(2, 4)), _rectangle(Vector2i(6, 3), Vector2i(3, 3))]:
		for cell in hole:
			cells.erase(cell)
	return cells


func _notch() -> Dictionary:
	var cells := _rectangle(Vector2i.ZERO, Vector2i(6, 6))
	for cell in _rectangle(Vector2i(0, 0), Vector2i(2, 2)):
		cells.erase(cell)
	return cells


func _diagonal_contacts() -> Dictionary:
	return {Vector2i.ZERO: true, Vector2i.ONE: true, Vector2i(2, 0): true}


func _sparse_pair() -> Dictionary:
	return {Vector2i(-4096, -4096): true, Vector2i(4096, 4096): true}


func _wall80() -> Dictionary:
	return _rectangle(Vector2i(3, -5), Vector2i(4, 80))


func _isolated_cells() -> Dictionary:
	var cells := {}
	for y in 5:
		for x in 5:
			cells[Vector2i(x * 2, y * 2)] = true
	return cells


func _material_rich() -> VoxelFrame:
	var frame := VoxelFrame.new()
	var palette: Array[PackedFloat32Array] = []
	for index in 64:
		palette.append(VoxelFrame.material(Color.from_rgba8(index * 3, 255 - index * 3, index * 2), Color.BLACK, 0.2, 0.4))
	for z in 32:
		for y in 32:
			for x in 32:
				frame.set_cell(Vector3i(x, y, z), palette[(x + y + z) % 64])
	return frame


func _uniform() -> VoxelFrame:
	var frame := VoxelFrame.new()
	var cell_material := VoxelFrame.material(Color.RED)
	for z in 32:
		for y in 32:
			for x in 32:
				frame.set_cell(Vector3i(x, y, z), cell_material)
	return frame


func _plate() -> VoxelFrame:
	var frame := VoxelFrame.new()
	var cell_material := VoxelFrame.material(Color.RED)
	for z in 32:
		for x in 32:
			frame.set_cell(Vector3i(x, 0, z), cell_material)
	return frame


func _hole_plate() -> VoxelFrame:
	var frame := VoxelFrame.new()
	var cell_material := VoxelFrame.material(Color.RED)
	for z in 32:
		for x in 32:
			if x % 3 == 1 and z % 3 == 1:
				continue
			frame.set_cell(Vector3i(x, 0, z), cell_material)
	return frame


func _sparse() -> VoxelFrame:
	var frame := VoxelFrame.new()
	var cell_material := VoxelFrame.material(Color.RED)
	for z in 8:
		for x in 8:
			frame.set_cell(Vector3i(x * 2, 0, z * 2), cell_material)
	return frame
