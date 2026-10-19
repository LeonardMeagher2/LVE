extends "res://tests/test.gd"

# Differential parity and in-process benchmark for the planar cleanup.
#
# The production region must match the frozen reference on every nonempty
# three-by-three mask and on edge fixtures, with and without prepared loops. The
# benchmark compares a frozen whole-surface build with the production one on
# independent group copies. Run one process:
#
#   godot --headless --path . res://tests/planar_cleanup.tscn

const REGION := preload("res://Globals/Rendering/VoxelPlanarRegion.gd")
const REFERENCE := preload("res://tests/planar_cleanup_reference.gd")
const SURFACE := preload("res://Globals/Rendering/VoxelSurface.gd")
const SURFACE_REFERENCE := preload("res://tests/planar_cleanup_surface_reference.gd")
const ATLAS := preload("res://Globals/Rendering/VoxelAtlas.gd")
const BUILDER := preload("res://Globals/Rendering/VoxelMeshBuilder.gd")

const REPEATS := 9
const WARMUP := 2

var cases: Array[Dictionary] = []
var prepared_cases := 0
var parity_error := ""
var prepared_error := ""
var cancel_error := ""
var counts := {}


func _ready() -> void:
	timeout = 300.0
	test("planar cleanup parity and performance", _run)


func _run() -> void:
	step("Given every nonempty three-by-three mask and the edge fixtures", _build_cases)
	step("When the production and frozen region paths run on each case", _compare_all)
	step("Then every polygon point, index, and order matches the frozen reference", _report_parity)
	step("Then a perturbed polygon fails the differential check", _negative_control)
	step("Then cancellation at entry and during work returns no polygons", _cancellation)
	step("When the material-rich fixture is counted", _count_workload)
	step("Then the frozen and production whole-surface builds report their medians", _benchmark)


# --- Differential cases -------------------------------------------------------

func _build_cases() -> void:
	cases.clear()
	for mask in range(1, 512):
		var cells := {}
		for bit in 9:
			if mask & (1 << bit):
				cells[Vector2i(bit % 3, bit / 3)] = true
		_add_case(cells, {}, "mask %d" % mask)
	_add_case(_rectangle(Vector2i.ZERO, Vector2i(7, 4)), _protected_collinear(), "protected collinear rectangle")
	_add_case({Vector2i(-3, -3): true, Vector2i(4, 4): true}, {}, "disconnected cells")
	_add_case({Vector2i.ZERO: true, Vector2i.ONE: true, Vector2i(2, 0): true}, {}, "diagonal contacts")
	_add_case(_holes(), {}, "plate with two holes")
	_add_case(_notch(), {}, "corner notch")
	_add_case(_rectangle(Vector2i(-7, -5), Vector2i(9, 5)), {}, "negative coordinates")
	_add_case(_rectangle(Vector2i(4090, 4090), Vector2i(4, 4)), {}, "near 4096")
	_add_case({Vector2i(4096, 4096): true}, {}, "single cell at 4096")
	_add_case(_rectangle(Vector2i(3, -5), Vector2i(4, 80)), {}, "tall wall")
	_add_case({Vector2i(-4096, -4096): true, Vector2i(4096, 4096): true}, {}, "sparse pair")
	_add_case(_rectangle(Vector2i.ZERO, Vector2i(64, 2)), {}, "width limit sixty-four")
	_add_case(_rectangle(Vector2i.ZERO, Vector2i(65, 2)), {}, "width beyond sixty-four")
	_add_case(_isolated_cells(), {}, "isolated cells")
	_add_case(_isolated_cells(), {Vector2i(0, 0): true, Vector2i(8, 8): true}, "isolated cells with protected corners")
	_add_case(_rectangle(Vector2i.ZERO, Vector2i(16, 16)), {}, "solid sixteen by sixteen")
	_add_case({Vector2i.ZERO: true}, {}, "single cell")
	expect(cases.size() == 511 + 16, "the case list holds every mask and sixteen edge fixtures")


func _compare_all() -> void:
	parity_error = ""
	prepared_error = ""
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
		if not prepared_problem.is_empty() and prepared_error.is_empty():
			prepared_error = "%s prepared: %s" % [label, prepared_problem]
		var cross_problem := _same_output(plain, prepared)
		if not cross_problem.is_empty() and prepared_error.is_empty():
			prepared_error = "%s prepared versus plain: %s" % [label, cross_problem]


func _report_parity() -> void:
	expect(cases.size() >= 511, "every nonempty three-by-three mask is covered")
	expect(prepared_cases >= 511, "every mask also runs with prepared loops")
	expect(parity_error.is_empty(), "all %d cases match the frozen reference without prepared loops%s" % [cases.size(), _detail(parity_error)])
	expect(prepared_error.is_empty(), "every prepared case matches the frozen reference and the plain path%s" % _detail(prepared_error))


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


# --- Fixtures -----------------------------------------------------------------

func _add_case(cells: Dictionary, protected: Dictionary, label: String) -> void:
	cases.append({"cells": cells, "protected": protected, "label": label})


func _protected_collinear() -> Dictionary:
	return {Vector2i(1, 0): true, Vector2i(3, 0): true, Vector2i(6, 1): true, Vector2i(2, 3): true, Vector2i(0, 2): true}


func _rectangle(origin: Vector2i, size: Vector2i) -> Dictionary:
	var cells := {}
	for y in size.y:
		for x in size.x:
			cells[origin + Vector2i(x, y)] = true
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
