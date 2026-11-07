extends "res://tests/test.gd"

# Differential and performance test for the selection outline builder.
#
# `tests/outline_reference.gd` freezes the original builder and calls no
# production code. Every shape here is built with both builders and compared as a
# canonical segment set. The live builder emits lines in mask order, so the vertex
# order is not the reference order; a repeated live build must be identical. The
# A/B measurement alternates the implementations in one process and reports
# medians with their sample counts, so no result rests on a single minimum.
#
#   godot --path . res://tests/outline_parity.tscn

const REFERENCE := preload("res://tests/outline_reference.gd")
const PREVIEW_SCRIPT := preload("res://Globals/Rendering/VoxelPreview.gd")
const SELECTION_PREVIEW := preload("res://plugins/selection/SelectionPreview.tscn")

const AB_SAMPLES := 9
const AB_WARMUPS := 2
const RANDOM_SHAPES := 24
const RANDOM_SEED := 20261018
const MASK_ORIGINS := [Vector3i.ZERO, Vector3i(-1, -1, -1), Vector3i(15, 15, 15)]

# A job that cancels itself after a fixed number of checkpoints, so the build is
# stopped in the middle rather than before it starts.
class CancelAfterJob extends VoxelFrame.EditJob:
	var checks := 0
	var cancel_after := 1

	func checkpoint(completed: int) -> bool:
		checks += 1
		if checks > cancel_after:
			cancel()
		return super.checkpoint(completed)


# Test-only candidate that isolates the emission and merge choice. It keeps the
# shared neighbor scan, but writes the original five-element record list and
# merges it with the original comparator. Only the emission and the merge differ
# from the live builder, so an A/B row against it separates the two changes.
class SharedMaskVariant extends RefCounted:
	static func outline_vertices(selection: VoxelSelection) -> PackedVector3Array:
		var records := PackedInt32Array()
		for cell_position in selection.all_cells():
			collect(records, cell_position, selection)
		return merge(records)

	static func collect(records: PackedInt32Array, cell_position: Vector3i, selection: VoxelSelection) -> void:
		var x := cell_position.x
		var y := cell_position.y
		var z := cell_position.z
		var x_before := selection.contains(Vector3i(x - 1, y, z))
		var x_after := selection.contains(Vector3i(x + 1, y, z))
		var y_before := selection.contains(Vector3i(x, y - 1, z))
		var y_after := selection.contains(Vector3i(x, y + 1, z))
		var z_before := selection.contains(Vector3i(x, y, z - 1))
		var z_after := selection.contains(Vector3i(x, y, z + 1))
		edge(records, 0, cell_position, 1, -1, 2, -1, y_before, z_before, selection)
		edge(records, 0, cell_position, 1, -1, 2, 1, y_before, z_after, selection)
		edge(records, 0, cell_position, 1, 1, 2, -1, y_after, z_before, selection)
		edge(records, 0, cell_position, 1, 1, 2, 1, y_after, z_after, selection)
		edge(records, 1, cell_position, 2, -1, 0, -1, z_before, x_before, selection)
		edge(records, 1, cell_position, 2, -1, 0, 1, z_before, x_after, selection)
		edge(records, 1, cell_position, 2, 1, 0, -1, z_after, x_before, selection)
		edge(records, 1, cell_position, 2, 1, 0, 1, z_after, x_after, selection)
		edge(records, 2, cell_position, 0, -1, 1, -1, x_before, y_before, selection)
		edge(records, 2, cell_position, 0, -1, 1, 1, x_before, y_after, selection)
		edge(records, 2, cell_position, 0, 1, 1, -1, x_after, y_before, selection)
		edge(records, 2, cell_position, 0, 1, 1, 1, x_after, y_after, selection)

	static func edge(records: PackedInt32Array, edge_axis: int, cell_position: Vector3i, first_side_axis: int, first_side_sign: int, second_side_axis: int, second_side_sign: int, first_side: bool, second_side: bool, selection: VoxelSelection) -> void:
		if first_side and second_side:
			return
		if first_side != second_side:
			var diagonal_neighbor := REFERENCE.shifted(REFERENCE.shifted(cell_position, first_side_axis, first_side_sign), second_side_axis, second_side_sign)
			if not selection.contains(diagonal_neighbor):
				return
		records.append(edge_axis)
		records.append(cell_position[first_side_axis] * 2 + first_side_sign)
		records.append(cell_position[second_side_axis] * 2 + second_side_sign)
		records.append(cell_position[edge_axis] * 2 - 1)
		records.append(cell_position[edge_axis] * 2 + 1)

	static func merge(records: PackedInt32Array) -> PackedVector3Array:
		var runs_by_line := {}
		var index := 0
		while index < records.size():
			var line_key := Vector3i(records[index], records[index + 1], records[index + 2])
			if not runs_by_line.has(line_key):
				runs_by_line[line_key] = []
			runs_by_line[line_key].append(Vector2i(records[index + 3], records[index + 4]))
			index += 5
		var outline_vertices := PackedVector3Array()
		for line_key in runs_by_line:
			var line_runs: Array = runs_by_line[line_key]
			line_runs.sort_custom(func(first_run, second_run): return first_run.x < second_run.x)
			var merged_run: Vector2i = line_runs[0]
			for run_index in range(1, line_runs.size()):
				var next_run: Vector2i = line_runs[run_index]
				if next_run.x <= merged_run.y:
					merged_run.y = maxi(merged_run.y, next_run.y)
				else:
					REFERENCE.emit_run(outline_vertices, line_key.x, line_key.y, line_key.z, merged_run)
					merged_run = next_run
			REFERENCE.emit_run(outline_vertices, line_key.x, line_key.y, line_key.z, merged_run)
		return outline_vertices


var preview: MeshInstance3D
var leaving: MeshInstance3D
var _sink := 0
var _compared := 0
var _geometry_mismatches := 0
var _determinism_mismatches := 0
var _first_mismatch := ""
var _ab_fixtures := {}
var _ab_order: Array[String] = []
var _reference_times := {}
var _variant_times := {}
var _production_times := {}
var _inline_selection: VoxelSelection
var _mid_selection: VoxelSelection
var _large_selection: VoxelSelection
var _leaving_selection: VoxelSelection
var _mask_selection: VoxelSelection
var _large_mesh: Mesh
var _large_revision := 0


func _ready() -> void:
	timeout = 60.0
	test("the outline builder matches its frozen reference and costs less", _run, "outline_parity")
	test("the selection masks follow add, erase, and a restore", _mask_cache_run, "outline_masks")


func _mask_cache_run() -> void:
	step("Given a selection with one built chunk mask", func():
		_mask_selection = VoxelSelection.new()
		_mask_selection.add(Vector3i(0, 0, 0))
		var chunk: Array = _mask_selection.mask_chunks()[Vector3i.ZERO]
		var x_grid: PackedInt32Array = chunk[0]
		var y_grid: PackedInt32Array = chunk[1]
		var z_grid: PackedInt32Array = chunk[2]
		expect(x_grid[0] & 1, "the x row holds the cell")
		expect(y_grid[0] & 1, "the y row holds the cell")
		expect(z_grid[0] & 1, "the z row holds the cell")
	)
	step("When a cell is added and another is erased", func():
		_mask_selection.add(Vector3i(1, 0, 0))
		var chunk: Array = _mask_selection.mask_chunks()[Vector3i.ZERO]
		var x_grid: PackedInt32Array = chunk[0]
		expect(x_grid[0] & 2, "the x row holds the new bit")
		_mask_selection.erase(Vector3i(0, 0, 0))
		expect(not (x_grid[0] & 1), "the erased bit is clear")
	)
	step("When the selection is replaced from a box", func():
		_mask_selection.from_box(Vector3i(2, 2, 2), Vector3i(3, 3, 3))
		var chunk: Array = _mask_selection.mask_chunks()[Vector3i.ZERO]
		var x_grid: PackedInt32Array = chunk[0]
		expect(x_grid[2 * 16 + 2] & 0b1100, "the box bits replace the old selection")
		expect(not (x_grid[0] & 1), "the old bit is gone")
	)
	step("When a captured selection is restored", func():
		var snapshot := _mask_selection.capture()
		var masks := _mask_selection.mask_snapshot()
		_mask_selection.clear()
		expect(_mask_selection.mask_chunks().is_empty(), "a clear leaves no masks")
		_mask_selection.restore(snapshot)
		var chunk: Array = _mask_selection.mask_chunks()[Vector3i.ZERO]
		var x_grid: PackedInt32Array = chunk[0]
		expect(x_grid[2 * 16 + 2] & 0b1100, "the restored selection rebuilds its masks")
		_mask_selection.clear()
		_mask_selection.restore(snapshot, masks)
		var adopted: Array = _mask_selection.mask_chunks()[Vector3i.ZERO]
		expect(adopted[0] == chunk[0] and adopted[1] == chunk[1] and adopted[2] == chunk[2], "the adopted masks equal the rebuilt masks")
	)
	step("Then a one-bit mask difference is detected", func():
		var reference := VoxelSelection.new()
		reference.from_box(Vector3i(2, 2, 2), Vector3i(3, 3, 3))
		var changed := VoxelSelection.new()
		changed.from_box(Vector3i(2, 2, 2), Vector3i(3, 3, 3))
		changed.add(Vector3i(4, 2, 2))
		expect(VoxelEditTransaction._masks_equal(reference.mask_chunks(), reference.mask_chunks()), "equal masks compare equal")
		expect(not VoxelEditTransaction._masks_equal(reference.mask_chunks(), changed.mask_chunks()), "a one-bit difference compares different")
	)
	expect(_mask_selection.count() == 8, "the box holds eight cells")


func _run() -> void:
	step("Given the frozen outline reference", func():
		_expect_frozen_reference()
	)
	step("When every nonempty two-by-two-by-two mask is built twice", func():
		_compare_all(_mask_selections())
		expect(_compared == 255 * MASK_ORIGINS.size(), "the exhaustive set holds every nonempty mask at every origin")
	)
	step("Then the mask geometry matches the reference", func():
		_expect_no_mismatches("the exhaustive masks")
	)
	step("When representative and random shapes are built twice", func():
		_compare_all(_representative_selections())
		_compare_all(_random_selections())
	)
	step("Then the representative geometry matches the reference", func():
		_expect_no_mismatches("the representative and random shapes")
	)
	step("Then the candidate variant also matches the reference", func():
		_expect_variant_matches()
	)
	step("Then the warmed A/B medians are reported", func():
		_measure_ab()
	)
	step("When a cancelled job stops the outline build", func():
		_expect_cancellation()
	)
	step("Given a selection preview", func():
		_build_preview()
	)
	step("When the user requests a large outline", func():
		preview.show_selection(_large_selection)
	)
	await _settle(preview)
	step("Then the large outline completes", func():
		_large_mesh = preview.mesh
		expect(preview.visible, "the large outline is visible")
		expect(_large_mesh.surface_get_array_len(0) == 24, "the box outline holds twelve merged segments")
	)
	step("When the user requests the same outline again", func():
		_large_revision = preview._request_revision
		preview.show_selection(_large_selection)
	)
	step("Then the cache returns the outline at once", func():
		expect(preview.mesh == _large_mesh and preview.is_settled(), "the repeated outline returns from the cache")
		expect(preview._request_revision == _large_revision, "the cache hit starts no new request")
	)
	step("When the user replaces the outline twice and clears it", func():
		preview.show_selection(_mid_selection)
		preview.show_selection(_inline_selection)
		preview.show_selection(VoxelSelection.new())
	)
	await _settle(preview)
	step("Then the cleared outline stays hidden", func():
		expect(not preview.visible, "the cleared outline stays hidden")
		expect(State.get_activity() == null, "the cleared outline releases its activity")
	)
	step("Then the single-cell cursor is immediate", func():
		preview.show_cell(Vector3i(3, 0, 5))
		expect(preview.is_settled() and preview.visible, "the single-cell cursor shows at once")
		expect(preview.mesh.surface_get_array_len(0) == 24, "the single-cell cursor holds twelve segments")
		expect(preview.position == Vector3(3, 0, 5), "the cursor sits on its cell")
	)
	step("Then a small outline completes inside the request", func():
		var small := _box_selection(Vector3i(100, 0, 0), Vector3i(105, 5, 5))
		preview.show_selection(small)
		expect(preview.is_settled(), "a small outline completes inline")
		expect(preview.visible, "the small outline is visible")
	)
	step("Then a mid-size outline leaves a pending request", func():
		preview.show_selection(_mid_selection)
		expect(not preview.is_settled(), "a mid-size outline leaves the request pending")
	)
	await _settle(preview)
	step("Then the mid-size outline completes asynchronously", func():
		expect(preview.is_settled() and preview.visible, "the mid-size outline completes asynchronously")
	)
	step("When a preview leaves the tree with a running job", func():
		leaving = SELECTION_PREVIEW.instantiate()
		main.add_child(leaving)
		leaving.show_selection(_leaving_selection)
	)
	await get_tree().create_timer(0.12).timeout
	step("When the preview is freed mid-build", func():
		leaving.free()
		expect(not is_instance_valid(leaving), "the preview frees while its job runs")
	)
	step("Then the outline builder still returns geometry", func():
		expect(PREVIEW_SCRIPT._outline_vertices(_inline_selection).size() > 0, "the outline builder still works")
		expect(not State.edit_busy(), "the freed preview leaves no foreground work")
	)


func _expect_frozen_reference() -> void:
	var source := FileAccess.get_file_as_string("res://tests/outline_reference.gd")
	for forbidden in ["VoxelPreview.", "_collect_boundary_runs", "_append_boundary_edge", "_outline_vertices", "_merged_outline", "_emit_run"]:
		expect(not source.contains(forbidden), "the frozen reference never names %s" % forbidden)
	var single := VoxelSelection.new()
	single.add(Vector3i.ZERO)
	expect(REFERENCE.outline_vertices(single).size() == 24, "the frozen reference gives a single cell twelve segments")
	expect(_canonical_counts(REFERENCE.outline_vertices(single)) == _canonical_counts(PREVIEW_SCRIPT._outline_vertices(single)), "both builders agree on one cell")


func _compare_all(selections: Array) -> void:
	for selection: VoxelSelection in selections:
		_compare(selection)


func _compare(selection: VoxelSelection) -> void:
	var reference := REFERENCE.outline_vertices(selection)
	var production := PREVIEW_SCRIPT._outline_vertices(selection)
	var repeated := PREVIEW_SCRIPT._outline_vertices(selection)
	_compared += 1
	if production != repeated:
		_determinism_mismatches += 1
		if _first_mismatch == "":
			_first_mismatch = "nondeterministic %d vs %d vertices" % [production.size(), repeated.size()]
	if _canonical_counts(reference) != _canonical_counts(production):
		_geometry_mismatches += 1
		if _first_mismatch == "":
			_first_mismatch = "geometry"


func _expect_no_mismatches(label: String) -> void:
	expect(_geometry_mismatches == 0, "%s keep the exact segment set%s" % [label, "" if _first_mismatch == "" else " (first: %s)" % _first_mismatch])
	expect(_determinism_mismatches == 0, "%s build the same output twice" % label)
	expect(_compared > 0, "%s compare at least one shape" % label)


# A canonical segment is one endpoint pair with the lexicographic first endpoint
# in front. Counting them compares coverage without depending on the output order.
func _canonical_counts(vertices: PackedVector3Array) -> Dictionary:
	var counts := {}
	for index in range(0, vertices.size(), 2):
		var key := _segment_key(vertices[index], vertices[index + 1])
		counts[key] = counts.get(key, 0) + 1
	return counts


func _segment_key(first: Vector3, second: Vector3) -> PackedFloat32Array:
	if _lexicographic(second, first):
		return PackedFloat32Array([second.x, second.y, second.z, first.x, first.y, first.z])
	return PackedFloat32Array([first.x, first.y, first.z, second.x, second.y, second.z])


func _lexicographic(first: Vector3, second: Vector3) -> bool:
	if first.x != second.x:
		return first.x < second.x
	if first.y != second.y:
		return first.y < second.y
	return first.z < second.z


func _mask_selections() -> Array:
	var out := []
	for origin: Vector3i in MASK_ORIGINS:
		for mask in range(1, 256):
			var selection := VoxelSelection.new()
			for bit in 8:
				if mask & (1 << bit):
					selection.add(origin + Vector3i(bit & 1, (bit >> 1) & 1, (bit >> 2) & 1))
			out.append(selection)
	return out


func _representative_selections() -> Array:
	var out := []
	# A cavity: a hollow shell.
	out.append(_shell_selection(Vector3i.ZERO, Vector3i(7, 7, 7)))
	# A notch: a box with an interior sub-box removed.
	out.append(_box_with_gap(Vector3i.ZERO, Vector3i(7, 7, 7), Vector3i(3, 3, 3), Vector3i(5, 5, 5)))
	# Corner contact: two boxes that touch at one corner only.
	out.append(_pair_selection(_box_selection(Vector3i.ZERO, Vector3i(2, 2, 2)), _box_selection(Vector3i(3, 3, 3), Vector3i(5, 5, 5))))
	# Edge contact: two boxes that share one edge.
	out.append(_pair_selection(_box_selection(Vector3i.ZERO, Vector3i(2, 2, 2)), _box_selection(Vector3i(3, 3, 0), Vector3i(5, 5, 2))))
	# Face contact: two boxes that share one face.
	out.append(_pair_selection(_box_selection(Vector3i.ZERO, Vector3i(2, 2, 2)), _box_selection(Vector3i(3, 0, 0), Vector3i(5, 2, 2))))
	# Disconnected cells with gaps on every axis.
	out.append(_scattered_selection(20, 4))
	# Negative coordinates.
	out.append(_box_selection(Vector3i(-5, -5, -5), Vector3i(2, 2, 2)))
	# A box across the origin.
	out.append(_box_selection(Vector3i(-1, -1, -1), Vector3i(1, 1, 1)))
	# A box across a chunk boundary.
	out.append(_box_selection(Vector3i(14, 14, 14), Vector3i(17, 17, 17)))
	# A box that spans several chunks on every axis.
	out.append(_box_selection(Vector3i(0, 0, 0), Vector3i(19, 19, 19)))
	# A shell and a gap that span several chunks.
	out.append(_shell_selection(Vector3i(-2, -2, -2), Vector3i(19, 19, 19)))
	out.append(_box_with_gap(Vector3i(0, 0, 0), Vector3i(19, 19, 19), Vector3i(7, 7, 7), Vector3i(12, 12, 12)))
	# A stepped diagonal.
	out.append(_stair_selection())
	# Near the inline limit.
	out.append(_box_selection(Vector3i.ZERO, Vector3i(15, 15, 15)))
	out.append(_box_with_gap(Vector3i.ZERO, Vector3i(15, 15, 15), Vector3i(7, 7, 7), Vector3i(8, 8, 8)))
	return out


func _random_selections() -> Array:
	var out := []
	var rng := RandomNumberGenerator.new()
	rng.seed = RANDOM_SEED
	for shape in RANDOM_SHAPES:
		var side := 3 + rng.randi_range(0, 4)
		var density := 0.15 + rng.randf() * 0.7
		var origin := Vector3i(rng.randi_range(-2, 2), rng.randi_range(-2, 2), rng.randi_range(-2, 2))
		var selection := VoxelSelection.new()
		for z in side:
			for y in side:
				for x in side:
					if rng.randf() < density:
						selection.add(origin + Vector3i(x, y, z))
		if selection.is_empty():
			selection.add(origin)
		out.append(selection)
	return out


func _box_selection(min_corner: Vector3i, max_corner: Vector3i) -> VoxelSelection:
	var selection := VoxelSelection.new()
	selection.from_box(min_corner, max_corner)
	return selection


func _shell_selection(min_corner: Vector3i, max_corner: Vector3i) -> VoxelSelection:
	var selection := VoxelSelection.new()
	for z in range(min_corner.z, max_corner.z + 1):
		for y in range(min_corner.y, max_corner.y + 1):
			for x in range(min_corner.x, max_corner.x + 1):
				var inside := x > min_corner.x and x < max_corner.x and y > min_corner.y and y < max_corner.y and z > min_corner.z and z < max_corner.z
				if not inside:
					selection.add(Vector3i(x, y, z))
	return selection


func _box_with_gap(min_corner: Vector3i, max_corner: Vector3i, gap_min: Vector3i, gap_max: Vector3i) -> VoxelSelection:
	var selection := VoxelSelection.new()
	for z in range(min_corner.z, max_corner.z + 1):
		for y in range(min_corner.y, max_corner.y + 1):
			for x in range(min_corner.x, max_corner.x + 1):
				var cell := Vector3i(x, y, z)
				var in_gap := cell.x >= gap_min.x and cell.x <= gap_max.x and cell.y >= gap_min.y and cell.y <= gap_max.y and cell.z >= gap_min.z and cell.z <= gap_max.z
				if not in_gap:
					selection.add(cell)
	return selection


func _pair_selection(first: VoxelSelection, second: VoxelSelection) -> VoxelSelection:
	var selection := VoxelSelection.new()
	for cell_position in first.all_cells():
		selection.add(cell_position)
	for cell_position in second.all_cells():
		selection.add(cell_position)
	return selection


func _scattered_selection(side: int, step: int) -> VoxelSelection:
	var selection := VoxelSelection.new()
	for z in range(0, side, step):
		for y in range(0, side, step):
			for x in range(0, side, step):
				selection.add(Vector3i(x, y, z))
	return selection


func _stair_selection() -> VoxelSelection:
	var selection := VoxelSelection.new()
	for index in 12:
		selection.add(Vector3i(index, index, index))
		selection.add(Vector3i(index + 1, index, index))
	return selection


func _expect_cancellation() -> void:
	var selection := _box_selection(Vector3i.ZERO, Vector3i(20, 20, 20))
	expect(selection.count() > 8192, "the cancellation fixture crosses two checkpoints")
	var entry_job := VoxelFrame.EditJob.new()
	entry_job.cancel()
	expect(PREVIEW_SCRIPT._outline_vertices(selection, entry_job).is_empty(), "the live builder stops at the first checkpoint")
	expect(REFERENCE.outline_vertices(selection, entry_job).is_empty(), "the frozen reference stops at the first checkpoint")
	var live_job := CancelAfterJob.new()
	live_job.cancel_after = 1
	expect(PREVIEW_SCRIPT._outline_vertices(selection, live_job).is_empty(), "the live builder discards a mid-scan result")
	var reference_job := CancelAfterJob.new()
	reference_job.cancel_after = 1
	expect(REFERENCE.outline_vertices(selection, reference_job).is_empty(), "the frozen reference discards a mid-scan result")
	expect(not PREVIEW_SCRIPT._outline_vertices(selection).is_empty(), "an uncancelled build returns geometry")


func _measure_ab() -> void:
	_build_ab_fixtures()
	for label in _ab_order:
		var selection: VoxelSelection = _ab_fixtures[label]
		for warmup in AB_WARMUPS:
			_sink = REFERENCE.outline_vertices(selection).size()
			_sink = SharedMaskVariant.outline_vertices(selection).size()
			_sink = PREVIEW_SCRIPT._outline_vertices(selection).size()
		var reference_times: Array[int] = []
		var variant_times: Array[int] = []
		var production_times: Array[int] = []
		for sample in AB_SAMPLES:
			# Rotate the order so a slow frame cannot favour one side.
			match sample % 3:
				0:
					reference_times.append(_time_reference(selection))
					variant_times.append(_time_variant(selection))
					production_times.append(_time_production(selection))
				1:
					variant_times.append(_time_variant(selection))
					production_times.append(_time_production(selection))
					reference_times.append(_time_reference(selection))
				_:
					production_times.append(_time_production(selection))
					reference_times.append(_time_reference(selection))
					variant_times.append(_time_variant(selection))
		_reference_times[label] = reference_times
		_variant_times[label] = variant_times
		_production_times[label] = production_times
		var reference_median := _median(reference_times)
		var variant_median := _median(variant_times)
		var production_median := _median(production_times)
		print("MEASURE outline A/B %s: cells=%d reference %d us, shared_mask_variant %d us, production %d us, gain %.2fx, samples %d/%d/%d" % [
			label, selection.count(), reference_median, variant_median, production_median,
			float(reference_median) / maxf(1.0, float(production_median)),
			reference_times.size(), variant_times.size(), production_times.size(),
		])
	expect(_ab_order.size() == 5, "the A/B set holds five shapes")
	expect(_compared > 0 and _geometry_mismatches == 0, "the A/B shapes already matched the reference")


# The candidate must be a faithful shared-mask build, or its A/B row means nothing.
func _expect_variant_matches() -> void:
	var mismatches := 0
	for selection: VoxelSelection in _representative_selections():
		if REFERENCE.outline_vertices(selection) != SharedMaskVariant.outline_vertices(selection):
			mismatches += 1
	expect(mismatches == 0, "the shared-mask candidate keeps the exact vertex order")


func _build_ab_fixtures() -> void:
	_ab_fixtures = {
		"single_cell": _box_selection(Vector3i(4, 5, 6), Vector3i(4, 5, 6)),
		"tiny_box_2": _box_selection(Vector3i.ZERO, Vector3i(1, 1, 1)),
		"dense_box_8192": _box_selection(Vector3i.ZERO, Vector3i(31, 15, 15)),
		"sparse_stripes_4000": _striped_selection(20),
		"fragmented_1000": _scattered_selection(20, 2),
	}
	_ab_order = ["single_cell", "tiny_box_2", "dense_box_8192", "sparse_stripes_4000", "fragmented_1000"]


func _striped_selection(side: int) -> VoxelSelection:
	var selection := VoxelSelection.new()
	for z in side:
		for y in side:
			for x in range(0, side, 2):
				selection.add(Vector3i(x, y, z))
	return selection


func _time_reference(selection: VoxelSelection) -> int:
	var started := Time.get_ticks_usec()
	_sink = REFERENCE.outline_vertices(selection).size()
	return Time.get_ticks_usec() - started


func _time_variant(selection: VoxelSelection) -> int:
	var started := Time.get_ticks_usec()
	_sink = SharedMaskVariant.outline_vertices(selection).size()
	return Time.get_ticks_usec() - started


func _time_production(selection: VoxelSelection) -> int:
	var started := Time.get_ticks_usec()
	_sink = PREVIEW_SCRIPT._outline_vertices(selection).size()
	return Time.get_ticks_usec() - started


func _median(samples: Array[int]) -> int:
	var sorted := samples.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _build_preview() -> void:
	preview = SELECTION_PREVIEW.instantiate()
	main.add_child(preview)
	_inline_selection = _box_selection(Vector3i.ZERO, Vector3i(5, 5, 5))
	_mid_selection = _box_selection(Vector3i.ZERO, Vector3i(15, 15, 15))
	_large_selection = _box_selection(Vector3i.ZERO, Vector3i(31, 15, 15))
	_leaving_selection = _box_selection(Vector3i.ZERO, Vector3i(39, 15, 15))
	expect(_inline_selection.count() <= PREVIEW_SCRIPT.INLINE_OUTLINE_LIMIT, "the inline fixture fits the inline limit")
	expect(_mid_selection.count() > PREVIEW_SCRIPT.INLINE_OUTLINE_LIMIT, "the mid fixture crosses the inline limit")
	expect(_mid_selection.count() <= PREVIEW_SCRIPT.OUTLINE_DELAY_LIMIT, "the mid fixture stays below the delay limit")
	expect(_large_selection.count() > PREVIEW_SCRIPT.OUTLINE_DELAY_LIMIT, "the large fixture crosses the delay limit")


func _settle(instance: MeshInstance3D) -> void:
	while not instance.is_settled():
		await get_tree().process_frame
