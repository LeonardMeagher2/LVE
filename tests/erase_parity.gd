extends "res://tests/test.gd"

# Differential and performance test for selection deletion.
#
# `tests/erase_reference.gd` freezes the erase path that ran before the shared
# sentinel, the whole-chunk removal, and the deferred compaction. Every fixture
# is erased by the live `State.EraseJob` and by the reference, then compared as
# encoded chunk records, voxel counts, bounds, chunk sets, and changed-chunk
# coverage. The A/B alternates the two paths in one process and reports medians
# with their sample counts.
#
#   godot --headless --path . res://tests/erase_parity.tscn

const REFERENCE := preload("res://tests/erase_reference.gd")
const STATE_SCRIPT := preload("res://Globals/State/State.gd")
const CANCEL_JOB := preload("res://tests/erase_cancel_job.gd")

const AB_SAMPLES := 9
const AB_WARMUPS := 2
const CHUNK := VoxelFrame.CHUNK_SIZE
# The chunk that holds the cell at (CHUNK, 0, 0).
const NEIGHBOUR_CHUNK := Vector3i(1, 0, 0)
const CROSSTALK := [Vector3i(-1, -1, -1), Vector3i(-1, -1, 0), Vector3i(-1, -1, 1), Vector3i(-1, 0, -1), Vector3i(-1, 0, 0), Vector3i(-1, 0, 1), Vector3i(-1, 1, -1), Vector3i(-1, 1, 0), Vector3i(-1, 1, 1), Vector3i(0, -1, -1), Vector3i(0, -1, 0), Vector3i(0, -1, 1), Vector3i(0, 0, -1), Vector3i(0, 0, 1), Vector3i(0, 1, -1), Vector3i(0, 1, 0), Vector3i(0, 1, 1), Vector3i(1, -1, -1), Vector3i(1, -1, 0), Vector3i(1, -1, 1), Vector3i(1, 0, -1), Vector3i(1, 0, 0), Vector3i(1, 0, 1), Vector3i(1, 1, -1), Vector3i(1, 1, 0), Vector3i(1, 1, 1)]


var frame: VoxelFrame
var _sink := 0
var _compared := 0
var _mismatches := 0
var _first_mismatch := ""
var _mixed_compared := 0
var _mixed_mismatches := 0
var _mixed_first := ""
var _fixtures := {}
var _ab_order: Array[String] = []
var _erase_samples: Array[int] = []


func _ready() -> void:
	timeout = 120.0
	test("selection deletion matches its frozen reference and costs less", _run, "erase_parity")


func _run() -> void:
	step("Given the frozen erase reference", func():
		_expect_frozen_reference()
	)
	step("Given the erase fixtures", func():
		_build_fixtures()
		expect(_fixtures.size() == 11, "the fixture set holds every erase shape")
	)
	step("When every fixture is erased by both paths", func():
		for label: String in _fixtures:
			var fixture: Dictionary = _fixtures[label]
			_compare(label, fixture["cells"], fixture["mask"])
		expect(_compared == _fixtures.size(), "every fixture compared once")
	)
	step("Then the erase results match the reference", func():
		expect(_mismatches == 0, "every fixture keeps the encoded chunk records%s" % ("" if _first_mismatch == "" else " (first: %s)" % _first_mismatch))
	)
	step("Then a removed chunk invalidates all its crosstalk neighbors", func():
		_expect_full_chunk_invalidation()
	)
	step("When a captured frame loses a whole chunk", func():
		_expect_captured_removal()
	)
	step("When a batch mixes erases and writes around the compaction threshold", func():
		_compare_mixed_batches()
	)
	step("Then the mixed batches match the single-cell oracle", func():
		expect(_mixed_compared == 6, "every mixed batch compared once")
		expect(_mixed_mismatches == 0, "every mixed batch keeps the encoded chunk records%s" % ("" if _mixed_first == "" else " (first: %s)" % _mixed_first))
	)
	step("Then the warmed erase A/B medians are reported", func():
		_measure_ab()
	)
	step("Then the compaction attribution is reported", func():
		_measure_compaction()
	)
	step("When a cancelled erase job stops the work", func():
		_expect_cancellation()
	)
	step("When the editor erases a large selection", func():
		_expect_full_workflow()
	)
	await _settle_erase()
	step("Then the erase publishes one undoable action and keeps the selection", func():
		_expect_workflow_result()
	)
	step("Then undo and redo restore the voxels exactly", func():
		_expect_undo_redo()
	)
	step("Then a no-op erase records no history", func():
		_expect_no_op_history()
	)
	step("Then the erase is independent of the active tool", func():
		_expect_tool_independence()
	)
	step("When the document changes during a large erase", func():
		_expect_stale_document()
	)
	await _settle_erase()
	step("Then the stale erase publishes nothing", func():
		expect(not State.edit_busy(), "the stale erase releases the edit state")
		expect(State.get_current_voxel_frame().count() == 0, "the replacement document keeps no erased voxels")
	)
	step("When a large erase is cancelled and a new one starts at once", func():
		_expect_cancel_then_new()
	)
	await _settle_erase()
	step("Then the cancelled erase published nothing", func():
		expect(State.get_current_voxel_frame().count() == 2 * CHUNK * CHUNK * CHUNK, "the cancelled erase left both chunks intact")
		expect(State.selection.count() == 1, "the second erase kept its one-cell selection")
		expect(not State.edit_busy(), "the replacement erase released the edit state")
	)


func _expect_frozen_reference() -> void:
	var source := FileAccess.get_file_as_string("res://tests/erase_reference.gd")
	# The frozen algorithm must not call the methods this unit changed. The
	# helpers it does reuse are listed in its header.
	for forbidden in ["State.gd", "State.erase_selection", "._compact(", "._fill_chunk(", ".apply_changes(", ".set_cells("]:
		expect(not source.contains(forbidden), "the frozen reference never calls %s" % forbidden)
	var frame := VoxelFrame.new()
	frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
	REFERENCE.erase(frame, {Vector3i.ZERO: true})
	expect(frame.count() == 0, "the frozen reference erases one cell")
	expect(source.contains("VoxelFrame._touched_neighbors"), "the reference declares the helpers it reuses")


# Compare the live job with the reference on the same starting cells.
func _compare(label: String, cells: Dictionary, mask: Dictionary) -> void:
	var production_frame := _frame_of(cells)
	var reference_frame := _frame_of(cells)
	var before := _records(production_frame)
	_run_erase_job(production_frame, mask)
	REFERENCE.erase(reference_frame, mask)
	_compared += 1
	var production_records := _records(production_frame)
	var reference_records := _records(reference_frame)
	if production_records != reference_records:
		_fail(label, "encoded chunk records")
		return
	if production_frame.count() != reference_frame.count():
		_fail(label, "voxel count")
		return
	if production_frame.get_bounds() != reference_frame.get_bounds():
		_fail(label, "frame bounds")
		return
	if _keys(production_frame) != _keys(reference_frame):
		_fail(label, "chunk set")
		return


func _fail(label: String, what: String) -> void:
	_mismatches += 1
	if _first_mismatch == "":
		_first_mismatch = "%s %s" % [label, what]


func _expect_full_chunk_invalidation() -> void:
	var cells := _full_chunk_cells(Vector3i.ZERO)
	cells[Vector3i(CHUNK, 0, 0)] = VoxelFrame.material(Color.RED)
	var frame := _frame_of(cells)
	var mask := _slots_of(Vector3i.ZERO)
	var changed := _run_erase_job(frame, mask)
	var listed := _set_of(changed)
	expect(listed.has(Vector3i.ZERO), "the removed chunk is listed")
	var missing := 0
	for offset: Vector3i in CROSSTALK:
		if not listed.has(Vector3i.ZERO + offset):
			missing += 1
	expect(missing == 0, "all twenty-six crosstalk neighbors of the removed chunk are listed")


func _run_erase_job(target: VoxelFrame, mask: Dictionary) -> Array[Vector3i]:
	var job: Variant = STATE_SCRIPT.EraseJob.new()
	job.edited_frame = target
	job.selection_mask = mask
	job.run()
	return job.changed_chunks


func _measure_ab() -> void:
	_ab_order = ["full_slots_full_chunk", "full_slots_partial_chunk", "all_occupied_partial_chunk", "half_slab", "mixed_materials", "one_cell_chunks", "ordinary_small"]
	for label in _ab_order:
		var fixture: Dictionary = _fixtures[label]
		var cells: Dictionary = fixture["cells"]
		var mask: Dictionary = fixture["mask"]
		# Prepare every sample frame outside the timed region.
		var source := _frame_of(cells)
		var old_frames: Array[VoxelFrame] = []
		var new_frames: Array[VoxelFrame] = []
		for index in AB_SAMPLES + AB_WARMUPS:
			old_frames.append(source.copy_frame())
			new_frames.append(source.copy_frame())
		for warmup in AB_WARMUPS:
			REFERENCE.erase(old_frames[warmup], mask)
			_run_erase_job(new_frames[warmup], mask)
		var old_times: Array[int] = []
		var new_times: Array[int] = []
		for sample in AB_SAMPLES:
			var index := sample + AB_WARMUPS
			if sample % 2 == 0:
				old_times.append(_time_old(old_frames[index], mask))
				new_times.append(_time_new(new_frames[index], mask))
			else:
				new_times.append(_time_new(new_frames[index], mask))
				old_times.append(_time_old(old_frames[index], mask))
		var old_median := _median(old_times)
		var new_median := _median(new_times)
		print("MEASURE erase A/B %s: cells=%d mask=%d old %d us, new %d us, gain %.2fx, samples %d/%d" % [
			label, cells.size(), mask.size(), old_median, new_median,
			float(old_median) / maxf(1.0, float(new_median)), old_times.size(), new_times.size(),
		])
	expect(_ab_order.size() == 7, "the A/B set holds seven shapes")


func _time_old(target: VoxelFrame, mask: Dictionary) -> int:
	var started := Time.get_ticks_usec()
	_sink = REFERENCE.erase(target, mask).size()
	return Time.get_ticks_usec() - started


func _time_new(target: VoxelFrame, mask: Dictionary) -> int:
	var started := Time.get_ticks_usec()
	_sink = _run_erase_job(target, mask).size()
	return Time.get_ticks_usec() - started


# The same cells are erased from two chunks that differ only in their material
# table: one holds an entry per cell, the other one shared entry. The erase loop
# never reads the table, so the difference between the two rows is the compaction.
func _measure_compaction() -> void:
	var percell := VoxelFrame.new()
	var material := VoxelFrame.material(Color.RED)
	for z in CHUNK:
		for y in CHUNK:
			for x in CHUNK:
				percell.set_cell(Vector3i(x, y, z), material)
	var shared := VoxelFrame.new()
	shared.set_cells(_full_chunk_cells(Vector3i.ZERO))
	expect(percell.chunks[Vector3i.ZERO].materials.size() == CHUNK * CHUNK * CHUNK * VoxelFrame.MATERIAL_STRIDE, "the per-cell chunk holds one table entry per cell")
	expect(shared.chunks[Vector3i.ZERO].materials.size() == VoxelFrame.MATERIAL_STRIDE, "the shared chunk holds one table entry")
	var mask := _slab_cells(Vector3i.ZERO, 0, 0, 11)
	var old_percell := _sample_old(percell, mask)
	var old_shared := _sample_old(shared, mask)
	var new_percell := _sample_new(percell, mask)
	var new_shared := _sample_new(shared, mask)
	print("MEASURE erase compaction: old percell %d us, old shared %d us, old compaction %d us, new percell %d us, new shared %d us, new compaction %d us" % [
		old_percell, old_shared, old_percell - old_shared, new_percell, new_shared, new_percell - new_shared,
	])


func _sample_old(source: VoxelFrame, mask: Dictionary) -> int:
	var samples: Array[int] = []
	for index in 5:
		samples.append(_time_old(source.copy_frame(), mask))
	return _median(samples)


func _sample_new(source: VoxelFrame, mask: Dictionary) -> int:
	var samples: Array[int] = []
	for index in 5:
		samples.append(_time_new(source.copy_frame(), mask))
	return _median(samples)


# Cancellation is driven by a checkpoint counter on a real EraseJob subclass, so
# the stop lands at a known point in the prep loop, the chunk bucketing, or the
# per-chunk write.
func _expect_cancellation() -> void:
	# Three partly filled chunks. The mask selects every occupied cell, so each
	# batch takes the per-cell write path and the loop reaches several checkpoints.
	var cells := _three_partial_chunks()
	var mask := cells.duplicate()
	var source := _frame_of(cells)
	expect(mask.size() > 4096, "the cancellation fixture reaches a prep checkpoint")

	# Cancelled before any work: the prep loop stops at its first checkpoint.
	var entry_job: Variant = CANCEL_JOB.new()
	entry_job.cancel_after = 0
	entry_job.edited_frame = source.copy_frame()
	entry_job.selection_mask = mask
	entry_job.run()
	expect(entry_job.checks == 1, "the entry job stopped at its first checkpoint")
	expect(entry_job.changed_chunks.is_empty(), "the entry job reports no changed chunks")
	expect(entry_job.edited_frame.count() == source.count(), "the entry job leaves its frame untouched")

	# Cancelled during the prep loop, before the write starts.
	var prep_job: Variant = CANCEL_JOB.new()
	prep_job.cancel_after = 1
	prep_job.edited_frame = source.copy_frame()
	prep_job.selection_mask = mask
	prep_job.run()
	expect(prep_job.checks == 2, "the prep job stopped inside the prep loop")
	expect(prep_job.changed_chunks.is_empty(), "the prep job reports no changed chunks")
	expect(prep_job.edited_frame.count() == source.count(), "the prep job leaves its frame untouched")

	# Cancelled during the write, after the first chunk was already applied.
	var write_job: Variant = CANCEL_JOB.new()
	write_job.cancel_after = 5
	write_job.edited_frame = source.copy_frame()
	write_job.selection_mask = mask
	write_job.run()
	expect(write_job.checks == 6, "the write job stopped at the second chunk checkpoint")
	expect(write_job.changed_chunks.is_empty(), "the write job publishes no changed chunks")
	expect(write_job.edited_frame.count() < source.count(), "the write job stopped partway through its copy")
	expect(source.count() == cells.size(), "the cancelled jobs leave the source frame untouched")

	# A later job with no cancellation completes and reports its chunks.
	var done_job: Variant = CANCEL_JOB.new()
	done_job.cancel_after = 1000
	done_job.edited_frame = source.copy_frame()
	done_job.selection_mask = mask
	done_job.run()
	expect(done_job.changed_chunks.size() >= 3, "the uncancelled job reports every changed chunk")
	expect(done_job.edited_frame.count() == 0, "the uncancelled job erases every selected cell")
	expect(source.count() == cells.size(), "the uncancelled job also leaves the source frame untouched")


# A capture marks every chunk shared. Removing a whole chunk must drop its shared
# marker with it, keep the snapshot's own chunk intact, and stay independent of a
# later write into the freed location.
func _expect_captured_removal() -> void:
	var cells := _full_chunk_cells(Vector3i.ZERO)
	cells[Vector3i(CHUNK, 0, 0)] = VoxelFrame.material(Color.BLUE)
	var frame := _frame_of(cells)
	var snapshot: Dictionary = frame.capture()
	var kept: VoxelFrame.Chunk = snapshot[Vector3i.ZERO]
	expect(frame._shared_chunks.has(Vector3i.ZERO), "the capture marks the chunk shared")
	expect(kept.occupied_count == CHUNK * CHUNK * CHUNK, "the snapshot holds the full chunk")

	var changed := _run_erase_job(frame, _slots_of(Vector3i.ZERO))
	expect(not frame.chunks.has(Vector3i.ZERO), "the frame drops the erased chunk")
	expect(not frame._shared_chunks.has(Vector3i.ZERO), "the shared marker goes with the dropped chunk")
	expect(changed.has(Vector3i.ZERO), "the removed chunk is reported")
	var stale := 0
	for location in frame._shared_chunks:
		if not frame.chunks.has(location):
			stale += 1
	expect(stale == 0, "no shared marker outlives its chunk")

	expect(snapshot[Vector3i.ZERO] == kept, "the snapshot keeps the same chunk object")
	expect(kept.occupied_count == CHUNK * CHUNK * CHUNK, "the snapshot chunk keeps its voxels")
	expect(kept.get_color(Vector3i.ZERO) == Color.RED, "the snapshot chunk keeps its color")
	expect(snapshot.has(NEIGHBOUR_CHUNK), "the snapshot holds the neighbour chunk")
	expect(frame.chunks[NEIGHBOUR_CHUNK] == snapshot[NEIGHBOUR_CHUNK], "the untouched neighbour stays shared")
	expect(frame._shared_chunks.has(NEIGHBOUR_CHUNK), "the untouched neighbour keeps its shared marker")

	frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.GREEN))
	expect(frame._shared_chunks.has(Vector3i.ZERO) == false, "the new chunk at the freed location is not shared")
	expect(frame.get_color(Vector3i.ZERO) == Color.GREEN, "the frame holds the new voxel")
	expect(kept.get_color(Vector3i.ZERO) == Color.RED, "the snapshot chunk keeps its original voxel")

	frame.restore(snapshot)
	expect(frame.chunks.has(Vector3i.ZERO), "restore brings the chunk back")
	expect(frame.get_color(Vector3i.ZERO) == Color.RED, "restore returns the original voxel")


func _three_partial_chunks() -> Dictionary:
	var cells := {}
	for index in 3:
		for cell_position: Vector3i in _slab_cells(Vector3i(index * CHUNK, 0, 0), 0, 0, 11):
			cells[cell_position] = VoxelFrame.material(Color.RED)
	return cells


# Production `set_cells` handles a batch that mixes erases and writes. The erase
# reference rejects those, so the single-cell oracle in the reference covers them.
func _compare_mixed_batches() -> void:
	_compare_batch("mixed_below", _percell_frame, _mixed_batch(1000, 5))
	_compare_batch("mixed_at_threshold", _percell_frame, _mixed_batch(2048, 5))
	_compare_batch("mixed_above_threshold", _percell_frame, _mixed_batch(3000, 5))
	_compare_batch("mixed_write_only", _percell_frame, _write_only_batch(20))
	_compare_batch("mixed_on_shared", _shared_frame, _mixed_batch(2000, 5))
	_compare_batch("mixed_uniform_fill", _partial_frame, _uniform_batch())


func _compare_batch(label: String, builder: Callable, changes: Dictionary) -> void:
	var production: VoxelFrame = builder.call()
	var oracle: VoxelFrame = builder.call()
	production.set_cells(changes)
	REFERENCE.apply_cells(oracle, changes)
	_mixed_compared += 1
	if _records(production) != _records(oracle):
		_mixed_mismatches += 1
		if _mixed_first == "":
			_mixed_first = "%s records" % label
		return
	if production.count() != oracle.count():
		_mixed_mismatches += 1
		if _mixed_first == "":
			_mixed_first = "%s count" % label
		return
	if production.get_bounds() != oracle.get_bounds():
		_mixed_mismatches += 1
		if _mixed_first == "":
			_mixed_first = "%s bounds" % label


# A chunk that holds one table entry per cell, which an erase past half its cells
# compacts. A cell dictionary cannot build one, because a full-slot batch takes
# the bulk path and shares one entry.
func _percell_frame() -> VoxelFrame:
	var frame := VoxelFrame.new()
	var material := VoxelFrame.material(Color.RED)
	for z in CHUNK:
		for y in CHUNK:
			for x in CHUNK:
				frame.set_cell(Vector3i(x, y, z), material)
	return frame


func _shared_frame() -> VoxelFrame:
	return _frame_of(_full_chunk_cells(Vector3i.ZERO))


func _partial_frame() -> VoxelFrame:
	return _frame_of(_slab_cells(Vector3i.ZERO, 0, 0, 7))


func _mixed_batch(erase_count: int, write_count: int) -> Dictionary:
	var changes := {}
	var erased := VoxelFrame.material(Color.TRANSPARENT)
	var written := VoxelFrame.material(Color.GREEN, Color.BLUE, 0.5, 0.25)
	var index := 0
	for z in CHUNK:
		for y in CHUNK:
			for x in CHUNK:
				if index < erase_count:
					changes[Vector3i(x, y, z)] = erased
				index += 1
	for offset in write_count:
		changes[Vector3i(CHUNK + offset, 0, 0)] = written
	return changes


func _write_only_batch(write_count: int) -> Dictionary:
	var changes := {}
	var written := VoxelFrame.material(Color.GREEN, Color.BLUE, 0.5, 0.25)
	for offset in write_count:
		changes[Vector3i(offset, 3, 3)] = written
		changes[Vector3i(CHUNK + offset, 0, 0)] = written
	return changes


func _uniform_batch() -> Dictionary:
	var changes := {}
	var written := VoxelFrame.material(Color.GREEN, Color.BLUE, 0.5, 0.25)
	for z in CHUNK:
		for y in CHUNK:
			for x in CHUNK:
				changes[Vector3i(x, y, z)] = written
	return changes


func _expect_full_workflow() -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	var cells := _full_chunk_cells(Vector3i.ZERO)
	for cell_position: Vector3i in _full_chunk_cells(Vector3i(CHUNK, 0, 0)):
		cells[cell_position] = VoxelFrame.material(Color.GREEN)
	cells[Vector3i(CHUNK * 2, 0, 0)] = VoxelFrame.material(Color.BLUE)
	frame.set_cells(cells)
	State.document._bounds_dirty = true
	State.selection.clear()
	for cell_position: Vector3i in _slots_of(Vector3i.ZERO):
		State.selection.add(cell_position)
	for cell_position: Vector3i in _slots_of(Vector3i(CHUNK, 0, 0)):
		State.selection.add(cell_position)
	State.undo_redo.clear_history()
	_erase_samples.clear()
	_erase_started_us = Time.get_ticks_usec()
	State.erase_selection()


var _erase_started_us := 0


func _settle_erase() -> void:
	while State.edit_busy() or not State._erase_jobs.is_empty():
		await get_tree().process_frame
	if _erase_started_us > 0:
		_erase_samples.append(Time.get_ticks_usec() - _erase_started_us)
		_erase_started_us = 0


func _expect_workflow_result() -> void:
	expect(frame.count() == 1, "the erase leaves only the marker voxel")
	expect(frame.get_color(Vector3i(CHUNK * 2, 0, 0)) == Color.BLUE, "the third chunk keeps its voxel")
	expect(State.selection.count() == 2 * CHUNK * CHUNK * CHUNK, "the erase preserves the selection")
	expect(State.undo_redo.has_undo(), "the erase records one undo action")
	expect(_erase_samples.size() == 1, "the erase workflow time was recorded")
	print("MEASURE erase workflow: cells=%d full workflow %d us" % [2 * CHUNK * CHUNK * CHUNK, _erase_samples[0]])


func _expect_undo_redo() -> void:
	State.undo_redo.undo()
	expect(frame.count() == 2 * CHUNK * CHUNK * CHUNK + 1, "undo restores every erased voxel")
	State.undo_redo.redo()
	expect(frame.count() == 1, "redo removes them again")


func _expect_no_op_history() -> void:
	State.undo_redo.clear_history()
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
	State.selection.clear()
	State.selection.add(Vector3i(4, 4, 4))
	State.erase_selection()
	expect(not State.undo_redo.has_undo(), "erasing an empty cell records no history")
	expect(frame.count() == 1, "erasing an empty cell keeps the frame")


func _expect_tool_independence() -> void:
	var results: Array[int] = []
	for tool_button in ["Toolbar", "selection", "fill"]:
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cells(_full_chunk_cells(Vector3i.ZERO))
		State.selection.clear()
		for cell_position: Vector3i in _slots_of(Vector3i.ZERO):
			State.selection.add(cell_position)
		State.undo_redo.clear_history()
		activate_tool(tool_button)
		State.erase_selection()
		results.append(frame.count())
	expect(results == [0, 0, 0], "every tool leaves the same erase result")


func _expect_stale_document() -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	frame.set_cells(_two_chunk_cells())
	State.selection.clear()
	for cell_position: Vector3i in _slots_of(Vector3i.ZERO):
		State.selection.add(cell_position)
	for cell_position: Vector3i in _slots_of(Vector3i(CHUNK, 0, 0)):
		State.selection.add(cell_position)
	State.undo_redo.clear_history()
	_erase_started_us = 0
	State.erase_selection()
	State.document = VoxelDocument.new()


func _expect_cancel_then_new() -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	var cells := _two_chunk_cells()
	cells[Vector3i(CHUNK * 2, 0, 0)] = VoxelFrame.material(Color.BLUE)
	frame.set_cells(cells)
	State.selection.clear()
	for cell_position: Vector3i in _slots_of(Vector3i.ZERO):
		State.selection.add(cell_position)
	for cell_position: Vector3i in _slots_of(Vector3i(CHUNK, 0, 0)):
		State.selection.add(cell_position)
	State.undo_redo.clear_history()
	_erase_started_us = 0
	State.erase_selection()
	State._interrupt_erase()
	# A second erase over the marker voxel alone must still publish.
	State.selection.clear()
	State.selection.add(Vector3i(CHUNK * 2, 0, 0))
	State.erase_selection()


func _two_chunk_cells() -> Dictionary:
	var cells := _full_chunk_cells(Vector3i.ZERO)
	for cell_position: Vector3i in _full_chunk_cells(Vector3i(CHUNK, 0, 0)):
		cells[cell_position] = VoxelFrame.material(Color.GREEN)
	return cells


func _build_fixtures() -> void:
	_fixtures = {}
	# Every slot of a full chunk is selected, and the chunk is full.
	var full_full := _full_chunk_cells(Vector3i.ZERO)
	full_full[Vector3i(CHUNK, 0, 0)] = VoxelFrame.material(Color.RED)
	_fixtures["full_slots_full_chunk"] = {"cells": full_full, "mask": _slots_of(Vector3i.ZERO)}
	# Every slot is selected, but only half the chunk holds a voxel.
	var full_partial := _slab_cells(Vector3i.ZERO, 0, 0, 7)
	full_partial[Vector3i(CHUNK, 0, 0)] = VoxelFrame.material(Color.RED)
	_fixtures["full_slots_partial_chunk"] = {"cells": full_partial, "mask": _slots_of(Vector3i.ZERO)}
	# Only the occupied half is selected, so the batch is partial.
	_fixtures["all_occupied_partial_chunk"] = {"cells": _slab_cells(Vector3i.ZERO, 0, 0, 7), "mask": _slab_cells(Vector3i.ZERO, 0, 0, 7)}
	# A full chunk, half erased.
	_fixtures["half_slab"] = {"cells": _full_chunk_cells(Vector3i.ZERO), "mask": _slab_cells(Vector3i.ZERO, 0, 0, 7)}
	# A full chunk, a quarter erased.
	_fixtures["quarter_slab"] = {"cells": _full_chunk_cells(Vector3i.ZERO), "mask": _slab_cells(Vector3i.ZERO, 0, 0, 3)}
	# Many distinct materials in one chunk. The chunk holds one table entry per
	# cell, so an erase past half the cells crosses the compaction threshold.
	_fixtures["mixed_materials"] = {"cells": _mixed_chunk_cells(Vector3i.ZERO, 64), "mask": _slab_cells(Vector3i.ZERO, 0, 0, 11)}
	# Sixty-four chunks that each hold one voxel.
	var single := {}
	var single_mask := {}
	for index in 64:
		var location := Vector3i(index % 4, (index / 4) % 4, index / 16)
		var cell := location * CHUNK
		single[cell] = VoxelFrame.material(Color.RED)
		single_mask[cell] = true
	_fixtures["one_cell_chunks"] = {"cells": single, "mask": single_mask}
	# A few cells in one chunk.
	var small := {}
	for x in 8:
		small[Vector3i(x, 0, 0)] = VoxelFrame.material(Color.RED)
	_fixtures["ordinary_small"] = {"cells": small, "mask": small}
	# A box selection over a mostly empty chunk.
	var sparse := {}
	var sparse_mask := {}
	for index in 20:
		sparse[Vector3i(index, index % 4, 0)] = VoxelFrame.material(Color.RED)
	for z in 8:
		for y in 8:
			for x in 8:
				sparse_mask[Vector3i(x, y, z)] = true
	_fixtures["sparse_empty_partial"] = {"cells": sparse, "mask": sparse_mask}
	# Negative coordinates.
	var negative := _slab_cells(Vector3i(-CHUNK, -CHUNK, -CHUNK), 0, 0, 7)
	_fixtures["negative_cells"] = {"cells": negative, "mask": negative}
	# Three chunks with different occupancy.
	var multi := _slab_cells(Vector3i.ZERO, 0, 0, 15)
	for cell_position: Vector3i in _slab_cells(Vector3i(CHUNK, 0, 0), 0, 0, 7):
		multi[cell_position] = VoxelFrame.material(Color.GREEN)
	for cell_position: Vector3i in _slab_cells(Vector3i(CHUNK, CHUNK, 0), 0, 0, 3):
		multi[cell_position] = VoxelFrame.material(Color.BLUE)
	var multi_mask := {}
	for cell_position: Vector3i in multi:
		multi_mask[cell_position] = true
	_fixtures["multi_chunk"] = {"cells": multi, "mask": multi_mask}


func _full_chunk_cells(location: Vector3i) -> Dictionary:
	return _slab_cells(location, 0, 0, CHUNK - 1)


func _slab_cells(location: Vector3i, axis: int, from: int, to: int) -> Dictionary:
	var cells := {}
	var origin := location * CHUNK
	for z in CHUNK:
		for y in CHUNK:
			for x in range(from, to + 1):
				var local := Vector3i(x, y, z)
				cells[origin + local] = VoxelFrame.material(Color.RED)
	return cells


func _mixed_chunk_cells(location: Vector3i, materials: int) -> Dictionary:
	var cells := {}
	var origin := location * CHUNK
	for z in CHUNK:
		for y in CHUNK:
			for x in CHUNK:
				var index := x + CHUNK * (y + CHUNK * z)
				cells[origin + Vector3i(x, y, z)] = VoxelFrame.material(Color.from_rgba8(index % 256, (index * 3) % 256, (index * 7) % 256), Color.BLACK, float(index % 5) / 4.0, float(index % 3) / 2.0)
	return cells


func _slots_of(location: Vector3i) -> Dictionary:
	return _slab_cells(location, 0, 0, CHUNK - 1)


func _frame_of(cells: Dictionary) -> VoxelFrame:
	var built := VoxelFrame.new()
	built.set_cells(cells)
	return built


func _records(active_frame: VoxelFrame) -> Dictionary:
	var records := {}
	for record in active_frame.storage_data()[1]:
		records[record[0]] = record
	return records


func _keys(active_frame: VoxelFrame) -> Array:
	var locations := active_frame.chunks.keys()
	locations.sort_custom(func(first, second): return first.x < second.x or (first.x == second.x and (first.y < second.y or (first.y == second.y and first.z < second.z))))
	return locations


func _set_of(locations: Array[Vector3i]) -> Dictionary:
	var seen := {}
	for location in locations:
		seen[location] = true
	return seen


func _median(samples: Array[int]) -> int:
	var sorted := samples.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]
