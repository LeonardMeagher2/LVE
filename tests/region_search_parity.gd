extends "res://tests/test.gd"

# Differential and performance test for the shared region search.
#
# `tests/region_search_reference.gd` freezes the search the fill job ran before
# the shared helper replaced it. Every shape is searched by both implementations
# and compared as the match dictionary, its size, and its insertion order. The
# A/B alternates the two in one process and reports medians with their sample
# counts.
#
#   godot --path . res://tests/region_search_parity.tscn

const REFERENCE := preload("res://tests/region_search_reference.gd")
const CANCEL_JOB := preload("res://tests/region_search_cancel_job.gd")
const WAND_TOOL := preload("res://plugins/selection/tools/WandSelectTool.gd")

const AB_SAMPLES := 9
const AB_WARMUPS := 2
const CHUNK := VoxelFrame.CHUNK_SIZE
const RANDOM_SHAPES := 40
const RANDOM_SEED := 20261018

var frame: VoxelFrame
var fill_tool: Node
var wand_tool: Node
var _sink := 0
var _compared := 0
var _mismatches := 0
var _first_mismatch := ""
var _ab_order: Array[String] = []
var _ab_fixtures := {}
var _fill_samples: Array[int] = []
var _wand_samples: Array[int] = []
var _workflow_started_us := 0


func _ready() -> void:
	timeout = 120.0
	test("the shared region search matches its frozen reference and costs less", _run, "region_search_parity")


func _run() -> void:
	step("Given the frozen search reference", func():
		_expect_frozen_reference()
	)
	step("When every nonempty two-by-two-by-two mask is searched twice", func():
		for fixture: Dictionary in _exhaustive_cases():
			_compare("mask %s" % fixture["label"], fixture["cells"], fixture["seed"], {}, true)
			_compare("mask %s" % fixture["label"], fixture["cells"], fixture["seed"], {}, false)
		expect(_compared == 255 * 3 * 2, "the exhaustive set holds every mask at every origin in both modes")
	)
	step("Then the exhaustive searches match the reference", func():
		_expect_no_mismatches("the exhaustive masks")
	)
	step("When deterministic random shapes and barrier masks are searched twice", func():
		for fixture: Dictionary in _random_cases():
			_compare(fixture["label"], fixture["cells"], fixture["seed"], {}, true)
			_compare(fixture["label"], fixture["cells"], fixture["seed"], {}, false)
		for fixture: Dictionary in _special_cases():
			_compare(fixture["label"], fixture["cells"], fixture["seed"], fixture.get("mask", {}), fixture["connected"])
	)
	step("Then the random and special searches match the reference", func():
		_expect_no_mismatches("the random and special shapes")
	)
	step("Then the seed contract is stated", func():
		_expect_seed_contract()
	)
	step("Then the batch cursor hands out bounded slices and loses no tail", func():
		_expect_batch_cursor()
	)
	step("Then the direct value contract saves a conversion pass", func():
		_expect_conversion_cost()
	)
	step("Then the per-chunk checkpoint cost is reported", func():
		_expect_checkpoint_cost()
	)
	step("Then the warmed search A/B medians are reported", func():
		_measure_ab()
	)
	step("When a search job is cancelled at entry and mid-work", func():
		_expect_cancellation()
	)
	step("Then the search leaves its snapshot untouched", func():
		_expect_snapshot_immutable()
	)
	step("When the fill tool runs its complete workflow", func():
		_start_fill_workflow()
	)
	await _settle_fill_workflow()
	step("Then the fill settled result is correct", func():
		expect(frame.count() == 8192, "the fill keeps the voxel count")
		expect(frame.get_color(Vector3i(16, 8, 8)) == Color.GREEN, "the fill painted the connected block")
		expect(State.undo_redo.has_undo(), "the fill recorded one undo action")
		expect(_fill_samples.size() == 1, "the fill workflow was timed")
		print("MEASURE search workflow: fill %d us over 8192 cells" % _fill_samples[0])
	)
	step("When the wand tool runs its complete workflow", func():
		_start_wand_workflow()
	)
	await _settle_wand_workflow()
	step("Then the wand settled result is correct", func():
		expect(frame.count() == 8192, "the wand leaves the source voxels")
		expect(State.selection.count() == 8192, "the wand selected the whole block")
		expect(State.undo_redo.has_undo(), "the wand recorded one undo action")
		expect(_wand_samples.size() == 1, "the wand workflow was timed")
		print("MEASURE search workflow: wand %d us over 8192 cells" % _wand_samples[0])
	)
	step("Then the wand modes, symmetry, and undo stay correct", func():
		_expect_modes_and_symmetry()
	)


func _expect_frozen_reference() -> void:
	var source := FileAccess.get_file_as_string("res://tests/region_search_reference.gd")
	# The frozen search must not call the shared helper.
	for forbidden in ["VoxelRegionSearch", "Globals/State/VoxelRegionSearch"]:
		expect(not source.contains(forbidden), "the frozen reference never names %s" % forbidden)
	for helper in ["VoxelFrame.matches", "Chunk.matches", "world_cells", "VoxelFrame.DIRECTIONS", "chunk_position"]:
		expect(source.contains(helper), "the frozen reference declares the helper %s it reuses" % helper)
	var built := VoxelFrame.new()
	built.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
	var found := {}
	REFERENCE.find(found, built, Vector3i.ZERO, VoxelFrame.material(Color.RED), true, true)
	expect(found.size() == 1, "the frozen reference finds one connected cell")


func _compare(label: String, cells: Dictionary, seed_cell: Vector3i, mask: Dictionary, connected: bool) -> void:
	var built := _frame_of(cells)
	var target := built.get_material(seed_cell)
	var reference := {}
	var production := {}
	REFERENCE.find(reference, built, seed_cell, target, connected, true, mask)
	VoxelRegionSearch.find(production, built, seed_cell, target, connected, true, mask)
	_compared += 1
	if reference.size() != production.size():
		_fail(label, "%s size %d vs %d" % ["connected" if connected else "disconnected", reference.size(), production.size()])
		return
	if reference != production:
		_fail(label, "%s content" % ("connected" if connected else "disconnected"))
		return
	if reference.keys() != production.keys():
		_fail(label, "%s insertion order" % ("connected" if connected else "disconnected"))


func _fail(label: String, what: String) -> void:
	_mismatches += 1
	if _first_mismatch == "":
		_first_mismatch = "%s %s" % [label, what]


func _expect_no_mismatches(label: String) -> void:
	expect(_mismatches == 0, "%s keep the exact match set and order%s" % [label, "" if _first_mismatch == "" else " (first: %s)" % _first_mismatch])
	expect(_compared > 0, "%s compare at least one shape" % label)


# The shared search tests the seed. The frozen search did not, because the job
# validated the seed first. The difference is deliberate and stated here.
func _expect_seed_contract() -> void:
	var built := VoxelFrame.new()
	built.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
	built.set_cell(Vector3i(4, 0, 0), VoxelFrame.material(Color.RED))
	var target := VoxelFrame.material(Color.RED)
	var empty_seed := Vector3i(2, 0, 0)
	var production := {}
	VoxelRegionSearch.find(production, built, empty_seed, target, true, true)
	expect(production.is_empty(), "the shared search adds nothing for an empty seed")
	var reference := {}
	REFERENCE.find(reference, built, empty_seed, target, true, true)
	expect(reference.has(empty_seed), "the frozen search added the seed without a test")
	var mismatched := {}
	VoxelRegionSearch.find(mismatched, built, Vector3i.ZERO, VoxelFrame.material(Color.BLUE), true, true)
	expect(mismatched.is_empty(), "the shared search adds nothing for a seed of another material")
	# A mask never gates the seed, because the caller rejects a seed it cannot edit.
	var mask := {Vector3i(4, 0, 0): true}
	var masked := {}
	VoxelRegionSearch.find(masked, built, Vector3i.ZERO, target, true, true, mask)
	expect(masked.has(Vector3i.ZERO), "the seed joins the result even when the mask excludes it")
	expect(not masked.has(Vector3i(4, 0, 0)), "the mask keeps the other region out")
	# A disconnected search ignores the seed, so an empty seed still scans the frame.
	var disconnected := {}
	VoxelRegionSearch.find(disconnected, built, empty_seed, target, false, true)
	expect(disconnected.size() == 2, "the disconnected search ignores the seed and finds both red voxels")
	var reference_disconnected := {}
	REFERENCE.find(reference_disconnected, built, empty_seed, target, false, true)
	expect(reference_disconnected == disconnected, "the frozen search ignores the seed in the same way")


# The consumer cursor owns the pending batch keys and their position. It must
# hand out bounded slices, load the next batch only when the current keys are
# spent, and report done only when the queue is drained and every key is applied.
func _expect_batch_cursor() -> void:
	var queue := VoxelRegionSearch.BatchQueue.new()
	var cursor := VoxelRegionSearch.BatchCursor.new(queue)
	expect(cursor.next_end(2) == -1, "an empty queue yields no slice")
	var first := {Vector3i(0, 0, 0): true, Vector3i(1, 0, 0): true, Vector3i(2, 0, 0): true}
	var second := {Vector3i(3, 0, 0): true, Vector3i(4, 0, 0): true}
	expect(queue.push(first), "the first batch is accepted")
	expect(queue.push(second), "the second batch is accepted")
	expect(not cursor.is_done(), "a queued batch reports not done")
	var end := cursor.next_end(2)
	expect(end == 2, "the first slice ends at the limit inside the batch")
	expect(cursor.keys[0] == Vector3i(0, 0, 0) and cursor.keys[1] == Vector3i(1, 0, 0), "the first slice holds the first two keys")
	cursor.cursor = end
	expect(cursor.cursor < cursor.keys.size(), "the batch keeps one key after the first slice")
	expect(not cursor.is_done(), "a partly applied batch is not done")
	end = cursor.next_end(2)
	expect(end == 3, "the second slice takes the last key of the batch")
	cursor.cursor = end
	end = cursor.next_end(2)
	expect(end == 2, "the next slice loads the second batch")
	expect(cursor.keys[0] == Vector3i(3, 0, 0), "the second batch starts at its first key")
	cursor.cursor = end
	expect(cursor.is_done(), "the drained queue with every key applied reports done")
	expect(cursor.next_end(2) == -1, "no slice waits on a drained queue")
	# A drained cursor is not proof that the producer finished. The caller pairs
	# `is_done` with its worker task check, so an empty queue alone stays "done".
	expect(cursor.is_done(), "an empty queue reports done without a producer state")
	# Dropping the last owner releases the queue, so an abandoned operation does
	# not retain the bounded batches.
	var weak: WeakRef = weakref(queue)
	cursor = null
	queue = null
	expect(weak.get_ref() == null, "dropping the cursor releases its queue")


# The fill needs a change map, not a match set. Writing the replacement material
# during the search avoids a second pass over every match.
func _expect_conversion_cost() -> void:
	var cells := _block_cells(Vector3i.ZERO, Vector3i(31, 15, 15))
	var built := _frame_of(cells)
	var target := built.get_material(Vector3i.ZERO)
	var replacement := VoxelFrame.material(Color.GREEN)
	var convert_us := _time_min(func():
		var matches := {}
		VoxelRegionSearch.find(matches, built, Vector3i.ZERO, target, true, true)
		var changes := {}
		for cell_position in matches:
			changes[cell_position] = replacement
		_sink = changes.size()
	, 5)
	var direct_us := _time_min(func():
		var changes := {}
		VoxelRegionSearch.find(changes, built, Vector3i.ZERO, target, true, replacement)
		_sink = changes.size()
	, 5)
	expect(_sink == cells.size(), "the search found the whole block")
	print("MEASURE search conversion: cells=%d set_then_convert %d us, direct_value %d us" % [cells.size(), convert_us, direct_us])
	expect(direct_us < convert_us, "writing the value during the search beats a separate conversion pass")


# The per-chunk checkpoint bounds a sparse disconnected scan. Measure what a real
# job adds, so the bound is not assumed free.
func _expect_checkpoint_cost() -> void:
	var sparse := _frame_of(_scattered_cells(80, CHUNK))
	var sparse_target := sparse.get_material(Vector3i.ZERO)
	var dense := _frame_of(_block_cells(Vector3i.ZERO, Vector3i(31, 15, 15)))
	var dense_target := dense.get_material(Vector3i.ZERO)
	var job := VoxelFrame.EditJob.new()
	var sparse_plain := _time_min(func():
		var matches := {}
		VoxelRegionSearch.find(matches, sparse, Vector3i.ZERO, sparse_target, false, true)
		_sink = matches.size()
	, 5)
	var sparse_job := _time_min(func():
		var matches := {}
		VoxelRegionSearch.find(matches, sparse, Vector3i.ZERO, sparse_target, false, true, {}, job)
		_sink = matches.size()
	, 5)
	var dense_plain := _time_min(func():
		var matches := {}
		VoxelRegionSearch.find(matches, dense, Vector3i.ZERO, dense_target, false, true)
		_sink = matches.size()
	, 5)
	var dense_job := _time_min(func():
		var matches := {}
		VoxelRegionSearch.find(matches, dense, Vector3i.ZERO, dense_target, false, true, {}, job)
		_sink = matches.size()
	, 5)
	expect(_sink == 8192, "the dense scan found the whole block")
	print("MEASURE search checkpoint: sparse chunks=%d plain %d us, with_job %d us, delta %d us; dense chunks=%d plain %d us, with_job %d us, delta %d us" % [
		sparse.chunks.size(), sparse_plain, sparse_job, sparse_job - sparse_plain,
		dense.chunks.size(), dense_plain, dense_job, dense_job - dense_plain,
	])


func _measure_ab() -> void:
	_build_ab_fixtures()
	for label in _ab_order:
		var fixture: Dictionary = _ab_fixtures[label]
		var source: VoxelFrame = fixture["frame"]
		var seed_cell: Vector3i = fixture["seed"]
		var target: PackedFloat32Array = source.get_material(seed_cell)
		var mask: Dictionary = fixture["mask"]
		var connected: bool = fixture["connected"]
		for warmup in AB_WARMUPS:
			var sink := {}
			REFERENCE.find(sink, source, seed_cell, target, connected, true, mask)
			sink = {}
			VoxelRegionSearch.find(sink, source, seed_cell, target, connected, true, mask)
		var reference_times: Array[int] = []
		var production_times: Array[int] = []
		for sample in AB_SAMPLES:
			if sample % 2 == 0:
				reference_times.append(_time_reference(source, seed_cell, target, connected, mask))
				production_times.append(_time_production(source, seed_cell, target, connected, mask))
			else:
				production_times.append(_time_production(source, seed_cell, target, connected, mask))
				reference_times.append(_time_reference(source, seed_cell, target, connected, mask))
		var reference_median := _median(reference_times)
		var production_median := _median(production_times)
		print("MEASURE search A/B %s: cells=%d matches=%d connected=%s reference %d us, production %d us, gain %.2fx, samples %d/%d" % [
			label, fixture["cells"], _sink, str(connected), reference_median, production_median,
			float(reference_median) / maxf(1.0, float(production_median)), reference_times.size(), production_times.size(),
		])
	expect(_ab_order.size() == 10, "the A/B set holds ten shapes")


func _time_reference(source: VoxelFrame, seed_cell: Vector3i, target: PackedFloat32Array, connected: bool, mask: Dictionary) -> int:
	var matches := {}
	var started := Time.get_ticks_usec()
	REFERENCE.find(matches, source, seed_cell, target, connected, true, mask)
	var elapsed := Time.get_ticks_usec() - started
	_sink = matches.size()
	return elapsed


func _time_production(source: VoxelFrame, seed_cell: Vector3i, target: PackedFloat32Array, connected: bool, mask: Dictionary) -> int:
	var matches := {}
	var started := Time.get_ticks_usec()
	VoxelRegionSearch.find(matches, source, seed_cell, target, connected, true, mask)
	var elapsed := Time.get_ticks_usec() - started
	_sink = matches.size()
	return elapsed


func _expect_cancellation() -> void:
	var cells := _three_chunks()
	var source := _frame_of(cells)
	var target := source.get_material(Vector3i.ZERO)
	expect(cells.size() > 8192, "the cancellation fixture reaches two checkpoints")
	var entry_job: Variant = CANCEL_JOB.new()
	entry_job.cancel_after = 0
	entry_job.source_frame = source
	entry_job.seed_cell = Vector3i.ZERO
	entry_job.target_material = target
	entry_job.connected = true
	entry_job.replacement_material = VoxelFrame.material(Color.GREEN)
	entry_job.apply_changes = false
	entry_job.run()
	expect(entry_job.checks == 1, "the entry job stopped at its first checkpoint")
	expect(entry_job.matching_cells.is_empty(), "the entry job reports no matches")
	var mid_job: Variant = CANCEL_JOB.new()
	mid_job.cancel_after = 1
	mid_job.source_frame = source
	mid_job.seed_cell = Vector3i.ZERO
	mid_job.target_material = target
	mid_job.connected = true
	mid_job.replacement_material = VoxelFrame.material(Color.GREEN)
	mid_job.apply_changes = false
	mid_job.run()
	expect(mid_job.checks == 2, "the mid-work job stopped at the second checkpoint")
	expect(mid_job.matching_cells.is_empty(), "the mid-work job reports no matches")
	# A later job with no cancellation completes, so the snapshot stays usable.
	var done_job: Variant = CANCEL_JOB.new()
	done_job.cancel_after = 1000
	done_job.source_frame = source
	done_job.seed_cell = Vector3i.ZERO
	done_job.target_material = target
	done_job.connected = true
	done_job.replacement_material = VoxelFrame.material(Color.GREEN)
	done_job.apply_changes = false
	done_job.run()
	expect(done_job.matching_cells.size() == cells.size(), "the uncancelled job matches every connected cell")
	# The disconnected scan bounds its wait at each chunk. A frame of one-cell chunks
	# proves the bound: without it the scan would run every chunk before the first
	# occupied-cell checkpoint.
	var sparse_cells := _scattered_cells(80, CHUNK)
	expect(sparse_cells.size() == 125, "the sparse fixture holds one cell per chunk")
	var sparse := _frame_of(sparse_cells)
	var sparse_before := sparse.storage_data()
	var sparse_target := sparse.get_material(Vector3i.ZERO)
	var sparse_entry: Variant = CANCEL_JOB.new()
	sparse_entry.cancel_after = 0
	sparse_entry.source_frame = sparse
	sparse_entry.seed_cell = Vector3i.ZERO
	sparse_entry.target_material = sparse_target
	sparse_entry.connected = false
	sparse_entry.replacement_material = VoxelFrame.material(Color.GREEN)
	sparse_entry.apply_changes = false
	sparse_entry.run()
	expect(sparse_entry.checks == 1, "the disconnected entry job stopped at its first checkpoint")
	expect(sparse_entry.matching_cells.is_empty(), "the disconnected entry job reports no matches")
	var sparse_mid: Variant = CANCEL_JOB.new()
	sparse_mid.cancel_after = 10
	sparse_mid.source_frame = sparse
	sparse_mid.seed_cell = Vector3i.ZERO
	sparse_mid.target_material = sparse_target
	sparse_mid.connected = false
	sparse_mid.replacement_material = VoxelFrame.material(Color.GREEN)
	sparse_mid.apply_changes = false
	sparse_mid.run()
	expect(sparse_mid.checks == 11, "the disconnected scan stopped at a chunk boundary")
	expect(sparse_mid.matching_cells.is_empty(), "the disconnected mid-scan job discards its partial result")
	expect(sparse.storage_data() == sparse_before, "the cancelled scan leaves the snapshot bytes unchanged")
	# A cancelled fill publishes no chunk and leaves its own copy unchanged.
	var publish_job: Variant = CANCEL_JOB.new()
	publish_job.cancel_after = 10
	publish_job.source_frame = sparse.copy_frame()
	publish_job.seed_cell = Vector3i.ZERO
	publish_job.target_material = sparse_target
	publish_job.connected = false
	publish_job.replacement_material = VoxelFrame.material(Color.GREEN)
	publish_job.apply_changes = true
	publish_job.run()
	expect(publish_job.changed_chunks.is_empty(), "a cancelled disconnected fill publishes no chunk")
	expect(publish_job.matching_cells.is_empty(), "a cancelled disconnected fill reports no matches")
	expect(publish_job.source_frame.count() == sparse_cells.size(), "a cancelled disconnected fill leaves its copy unchanged")
	var sparse_done: Variant = CANCEL_JOB.new()
	sparse_done.cancel_after = 100000
	sparse_done.source_frame = sparse
	sparse_done.seed_cell = Vector3i.ZERO
	sparse_done.target_material = sparse_target
	sparse_done.connected = false
	sparse_done.replacement_material = VoxelFrame.material(Color.GREEN)
	sparse_done.apply_changes = false
	sparse_done.run()
	expect(sparse_done.matching_cells.size() == sparse_cells.size(), "the uncancelled disconnected scan matches every cell")


func _expect_snapshot_immutable() -> void:
	var cells := _block_cells(Vector3i.ZERO, Vector3i(31, 15, 15))
	var source := _frame_of(cells)
	var snapshot: Dictionary = source.capture()
	var before := source.storage_data()
	var target := source.get_material(Vector3i.ZERO)
	var matches := {}
	VoxelRegionSearch.find(matches, source, Vector3i.ZERO, target, true, VoxelFrame.material(Color.GREEN))
	expect(source.storage_data() == before, "the search leaves the snapshot bytes unchanged")
	expect(source.count() == cells.size(), "the search adds no voxel")
	for location in source.chunks:
		expect(source.chunks[location] == snapshot[location], "the search keeps the shared chunk objects")


func _start_fill_workflow() -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	frame.set_cells(_block_cells(Vector3i.ZERO, Vector3i(31, 15, 15)))
	State.document._bounds_dirty = true
	State.selection.clear()
	State.undo_redo.clear_history()
	select_toolbar_item("paint", "Bucket Fill")
	fill_tool = plugin("PaintPlugin")._fill_tool
	State.current_material = VoxelFrame.material(Color.GREEN)
	fill_tool._settings.connected = true
	fill_tool._release_pending = true
	_fill_samples.clear()
	_workflow_started_us = Time.get_ticks_usec()
	fill_tool._queue_seed(Vector3i.ZERO)


func _settle_fill_workflow() -> void:
	while not fill_tool.is_settled() or not fill_tool._search_jobs.is_empty() or State.edit_busy():
		await get_tree().process_frame
	await _settle_renderers()
	_fill_samples.append(Time.get_ticks_usec() - _workflow_started_us)


func _start_wand_workflow() -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	frame.set_cells(_block_cells(Vector3i.ZERO, Vector3i(31, 15, 15)))
	State.document._bounds_dirty = true
	State.selection.clear()
	State.undo_redo.clear_history()
	activate_tool("selection")
	select_toolbar_item("selection", "Wand")
	wand_tool = plugin("SelectionPlugin")._wand
	wand_tool._settings.connected = true
	wand_tool._settings.mode = wand_tool._settings.SelectMode.REPLACE
	_wand_samples.clear()
	_workflow_started_us = Time.get_ticks_usec()
	wand_tool._commit(Vector3i.ZERO)


func _settle_wand_workflow() -> void:
	while wand_tool._job != null or State.edit_busy():
		await get_tree().process_frame
	await _settle_renderers()
	_wand_samples.append(Time.get_ticks_usec() - _workflow_started_us)


func _expect_modes_and_symmetry() -> void:
	var built := VoxelFrame.new()
	built.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
	built.set_cell(Vector3i(4, 0, 0), VoxelFrame.material(Color.RED))
	built.set_cell(Vector3i(0, 4, 0), VoxelFrame.material(Color.BLUE))
	var job: Variant = WAND_TOOL.WandJob.new()
	job.source_frame = built
	job.seed_cell = Vector3i.ZERO
	job.target_material = VoxelFrame.material(Color.RED)
	job.connected = false
	job.previous_selection = {Vector3i(0, 4, 0): true}
	job.mode = 0
	job.run()
	expect(job.result.size() == 2, "replace mode selects only the matching red voxels")
	job.mode = 1
	job.run()
	expect(job.result.size() == 3 and job.result.has(Vector3i(0, 4, 0)), "add mode keeps the prior selection")
	job.mode = 2
	job.run()
	expect(job.result.size() == 1 and job.result.has(Vector3i(0, 4, 0)), "subtract mode removes only the matching voxels")
	# Symmetry expands the match set before the mode merge.
	var context := VoxelFrame.EditContext.new()
	context.axes = 1
	context.origin_twice = Vector3i(-1, 0, 0)
	var symmetric: Variant = WAND_TOOL.WandJob.new()
	symmetric.source_frame = built
	symmetric.seed_cell = Vector3i.ZERO
	symmetric.target_material = VoxelFrame.material(Color.RED)
	symmetric.connected = false
	symmetric.previous_selection = {}
	symmetric.mode = 0
	symmetric.edit_context = context
	symmetric.run()
	expect(symmetric.result.size() == 4, "the mirror plane adds the reflected matching voxels")
	expect(symmetric.result.has(Vector3i(-1, 0, 0)) and symmetric.result.has(Vector3i(-5, 0, 0)), "the reflected voxels are selected")


func _build_ab_fixtures() -> void:
	var dense := _frame_of(_block_cells(Vector3i.ZERO, Vector3i(31, 15, 15)))
	var dense_seed := Vector3i.ZERO
	var huge := _frame_of(_huge_with_island())
	var huge_seed := Vector3i(40, 0, 0)
	var scattered := _frame_of(_scattered_cells(20, 2))
	var scattered_seed := Vector3i.ZERO
	var mixed := _frame_of(_mixed_cells(Vector3i.ZERO, 64))
	var interface := _frame_of(_interface_cells(Vector3i.ZERO, 16))
	var core := _frame_of(_core_in_other_material())
	var barrier_cells := _block_cells(Vector3i.ZERO, Vector3i(15, 15, 15))
	var barrier_mask := {}
	for cell_position: Vector3i in barrier_cells:
		if cell_position.x != 8:
			barrier_mask[cell_position] = true
	var small := _frame_of(_block_cells(Vector3i.ZERO, Vector3i(1, 1, 1)))
	_ab_fixtures = {
		"ordinary_small": {"frame": small, "seed": Vector3i.ZERO, "mask": {}, "connected": true, "cells": 8},
		"dense_connected": {"frame": dense, "seed": dense_seed, "mask": {}, "connected": true, "cells": 8192},
		"dense_disconnected": {"frame": dense, "seed": dense_seed, "mask": {}, "connected": false, "cells": 8192},
		"scattered_connected": {"frame": scattered, "seed": scattered_seed, "mask": {}, "connected": true, "cells": 1000},
		"scattered_disconnected": {"frame": scattered, "seed": scattered_seed, "mask": {}, "connected": false, "cells": 1000},
		"mixed_materials": {"frame": mixed, "seed": Vector3i.ZERO, "mask": {}, "connected": true, "cells": 4096},
		"interface": {"frame": interface, "seed": Vector3i.ZERO, "mask": {}, "connected": true, "cells": 4096},
		"barrier_mask": {"frame": _frame_of(barrier_cells), "seed": Vector3i.ZERO, "mask": barrier_mask, "connected": true, "cells": 4096},
		"tiny_island_huge_frame": {"frame": huge, "seed": huge_seed, "mask": {}, "connected": true, "cells": 32771},
		"core_in_other_material": {"frame": core, "seed": Vector3i(2, 2, 2), "mask": {}, "connected": true, "cells": 8000},
	}
	_ab_order = ["ordinary_small", "dense_connected", "dense_disconnected", "scattered_connected", "scattered_disconnected", "mixed_materials", "interface", "barrier_mask", "tiny_island_huge_frame", "core_in_other_material"]


func _exhaustive_cases() -> Array:
	var out := []
	for origin: Vector3i in [Vector3i.ZERO, Vector3i(-1, -1, -1), Vector3i(15, 15, 15)]:
		for mask in range(1, 256):
			var cells := {}
			var seed := origin
			var first := true
			for bit in 8:
				if mask & (1 << bit) == 0:
					continue
				var cell := origin + Vector3i(bit & 1, (bit >> 1) & 1, (bit >> 2) & 1)
				cells[cell] = VoxelFrame.material(Color.RED)
				if first:
					seed = cell
					first = false
			out.append({"label": "%d at %s" % [mask, str(origin)], "cells": cells, "seed": seed})
	return out


func _random_cases() -> Array:
	var out := []
	var rng := RandomNumberGenerator.new()
	rng.seed = RANDOM_SEED
	for shape in RANDOM_SHAPES:
		var side := 3 + rng.randi_range(0, 2)
		var density := 0.2 + rng.randf() * 0.7
		var origin := Vector3i(rng.randi_range(-2, 2), rng.randi_range(-2, 2), rng.randi_range(-2, 2))
		var kinds := 1 + rng.randi_range(0, 2)
		var cells := {}
		var seed := origin
		var first := true
		for z in side:
			for y in side:
				for x in side:
					if rng.randf() >= density:
						continue
					var cell := origin + Vector3i(x, y, z)
					cells[cell] = _material_of(rng.randi_range(0, kinds - 1))
					if first:
						seed = cell
						first = false
		if cells.is_empty():
			cells[origin] = _material_of(0)
			seed = origin
		out.append({"label": "random %d" % shape, "cells": cells, "seed": seed})
	return out


func _special_cases() -> Array:
	var out := []
	var material := VoxelFrame.material(Color.RED)
	# Two cells that touch at one corner only. A face walk cannot reach the second.
	out.append({"label": "corner contact", "cells": {Vector3i.ZERO: material, Vector3i(1, 1, 0): material}, "seed": Vector3i.ZERO, "connected": true})
	out.append({"label": "edge contact", "cells": {Vector3i.ZERO: material, Vector3i(1, 1, 1): material}, "seed": Vector3i.ZERO, "connected": true})
	# A mask that cuts a dense block in half.
	var barrier_cells := _block_cells(Vector3i.ZERO, Vector3i(7, 7, 7))
	var barrier_mask := {}
	for cell_position: Vector3i in barrier_cells:
		if cell_position.x != 4:
			barrier_mask[cell_position] = true
	out.append({"label": "barrier mask", "cells": barrier_cells, "seed": Vector3i.ZERO, "connected": true, "mask": barrier_mask})
	out.append({"label": "barrier mask", "cells": barrier_cells, "seed": Vector3i(7, 0, 0), "connected": true, "mask": barrier_mask})
	# A negative chunk and a chunk boundary.
	out.append({"label": "negative chunk", "cells": _block_cells(Vector3i(-16, -16, -16), Vector3i(-9, -9, -9)), "seed": Vector3i(-16, -16, -16), "connected": true})
	out.append({"label": "chunk boundary", "cells": _block_cells(Vector3i(14, 14, 14), Vector3i(17, 17, 17)), "seed": Vector3i(14, 14, 14), "connected": true})
	out.append({"label": "chunk boundary", "cells": _block_cells(Vector3i(14, 14, 14), Vector3i(17, 17, 17)), "seed": Vector3i(14, 14, 14), "connected": false})
	# A tiny island inside a large frame.
	out.append({"label": "tiny island", "cells": _huge_with_island(), "seed": Vector3i(40, 0, 0), "connected": true})
	out.append({"label": "tiny island", "cells": _huge_with_island(), "seed": Vector3i(40, 0, 0), "connected": false})
	# A hole and a cavity.
	out.append({"label": "cavity", "cells": _shell_cells(Vector3i.ZERO, Vector3i(7, 7, 7)), "seed": Vector3i.ZERO, "connected": true})
	out.append({"label": "cavity", "cells": _shell_cells(Vector3i.ZERO, Vector3i(7, 7, 7)), "seed": Vector3i.ZERO, "connected": false})
	return out


func _material_of(index: int) -> PackedFloat32Array:
	return VoxelFrame.material(Color.from_rgba8((index * 37) % 256, (index * 61) % 256, (index * 97) % 256), Color.BLACK, float(index % 4) / 4.0, float(index % 3) / 2.0)


func _block_cells(min_corner: Vector3i, max_corner: Vector3i) -> Dictionary:
	var cells := {}
	var material := VoxelFrame.material(Color.RED)
	for z in range(min_corner.z, max_corner.z + 1):
		for y in range(min_corner.y, max_corner.y + 1):
			for x in range(min_corner.x, max_corner.x + 1):
				cells[Vector3i(x, y, z)] = material
	return cells


func _shell_cells(min_corner: Vector3i, max_corner: Vector3i) -> Dictionary:
	var cells := {}
	var material := VoxelFrame.material(Color.RED)
	for z in range(min_corner.z, max_corner.z + 1):
		for y in range(min_corner.y, max_corner.y + 1):
			for x in range(min_corner.x, max_corner.x + 1):
				var inside := x > min_corner.x and x < max_corner.x and y > min_corner.y and y < max_corner.y and z > min_corner.z and z < max_corner.z
				if not inside:
					cells[Vector3i(x, y, z)] = material
	return cells


func _scattered_cells(side: int, step: int) -> Dictionary:
	var cells := {}
	var material := VoxelFrame.material(Color.RED)
	for z in range(0, side, step):
		for y in range(0, side, step):
			for x in range(0, side, step):
				cells[Vector3i(x, y, z)] = material
	return cells


func _mixed_cells(location: Vector3i, kinds: int) -> Dictionary:
	var cells := {}
	var origin := location * CHUNK
	for z in CHUNK:
		for y in CHUNK:
			for x in CHUNK:
				cells[origin + Vector3i(x, y, z)] = _material_of((x + y + z) % kinds)
	return cells


func _interface_cells(location: Vector3i, side: int) -> Dictionary:
	var cells := {}
	var origin := location * CHUNK
	var first := VoxelFrame.material(Color.RED)
	var second := VoxelFrame.material(Color.BLUE)
	for z in side:
		for y in side:
			for x in side:
				cells[origin + Vector3i(x, y, z)] = first if (x + y + z) % 2 == 0 else second
	return cells


func _huge_with_island() -> Dictionary:
	var cells := _block_cells(Vector3i.ZERO, Vector3i(31, 31, 31))
	var material := VoxelFrame.material(Color.GREEN)
	cells[Vector3i(40, 0, 0)] = material
	cells[Vector3i(41, 0, 0)] = material
	cells[Vector3i(42, 0, 0)] = material
	return cells


# A red core inside a blue block. The blue cells at the interface are reached from
# several red neighbors, which is the shape a failed-neighbor mask would help.
func _core_in_other_material() -> Dictionary:
	var cells := {}
	var outer := VoxelFrame.material(Color.BLUE)
	var inner := VoxelFrame.material(Color.RED)
	for z in 20:
		for y in 20:
			for x in 20:
				cells[Vector3i(x, y, z)] = outer
	for cell_position: Vector3i in _block_cells(Vector3i(2, 2, 2), Vector3i(17, 17, 17)):
		cells[cell_position] = inner
	return cells


func _three_chunks() -> Dictionary:
	var cells := {}
	for index in 3:
		for cell_position: Vector3i in _block_cells(Vector3i(index * CHUNK, 0, 0), Vector3i(index * CHUNK + CHUNK - 1, 15, 15)):
			cells[cell_position] = VoxelFrame.material(Color.RED)
	return cells


func _frame_of(cells: Dictionary) -> VoxelFrame:
	var built := VoxelFrame.new()
	built.set_cells(cells)
	return built


func _renderers() -> Array[VoxelRenderer]:
	var found: Array[VoxelRenderer] = []
	for connection in State.chunks_changed.get_connections():
		var callable: Callable = connection["callable"]
		var object: Object = callable.get_object()
		if object is VoxelRenderer and not found.has(object):
			found.append(object)
	return found


func _settle_renderers() -> void:
	var renderers := _renderers()
	var settled := false
	while not settled:
		settled = true
		for renderer in renderers:
			if not renderer.is_settled():
				settled = false
				break
		if not settled:
			await get_tree().process_frame


func _time_min(work: Callable, count: int) -> int:
	var best := -1
	for index in count:
		var started := Time.get_ticks_usec()
		work.call()
		var elapsed := Time.get_ticks_usec() - started
		best = elapsed if best < 0 else mini(best, elapsed)
	return best


func _median(samples: Array[int]) -> int:
	var sorted := samples.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]
