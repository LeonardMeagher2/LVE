extends "res://tests/test.gd"

# Focused tests for the bounded batch slice consumer shared by the bucket fill
# and the wand.
#
# The consumer applies one bounded slice at a time. These tests prove that every
# queued cell is applied once, that a partial budget leaves the rest, that a
# drained queue is not a finished producer, that a cancel wakes a producer on a
# full queue, and that a callback cannot consume the same cursor again. The last
# test runs both tools through the shared path and checks the result and undo.
#
#   godot --path . res://tests/region_batch_slices.tscn

const REFERENCE := preload("res://tests/region_search_reference.gd")
const FILL_SIDE := 20
const FILL_TOTAL := FILL_SIDE * FILL_SIDE * FILL_SIDE
const WAIT_LIMIT_MS := 30000
# Keep this equal to VoxelRegionSearch.BatchQueue.LIMIT. The test pins the bound.
const QUEUE_LIMIT := 4

var frame: VoxelFrame
var fill_tool: Node
var wand_tool: Node
var _before: VoxelFrame
var _expected_cells := {}
var _producer_queue: VoxelRegionSearch.BatchQueue
var _producer_task := -1


# A producer that fills a bounded queue and then waits on a full one.
class QueueProducer extends RefCounted:
	var queue: VoxelRegionSearch.BatchQueue
	var pushed := 0

	func run() -> void:
		for index in 1000:
			if not queue.push({Vector3i(index, 0, 0): true}):
				return
			pushed += 1


# A slice callback that stops after a fixed number of slices.
class BudgetSlice extends RefCounted:
	var budget := 3
	var applied: Array[Vector3i] = []

	func run(keys: Array, start: int, end: int) -> bool:
		if budget <= 0:
			return false
		budget -= 1
		for index in range(start, end):
			applied.append(keys[index])
		return true


# A slice callback that refuses a stale context before it applies the slice.
class GuardedSlice extends RefCounted:
	var valid := true
	var applied: Array[Vector3i] = []

	func run(keys: Array, start: int, end: int) -> bool:
		if not valid:
			return false
		for index in range(start, end):
			applied.append(keys[index])
		return true


# A slice callback that tries to consume the same cursor again.
class ReentrantSlice extends RefCounted:
	var cursor: VoxelRegionSearch.BatchCursor
	var calls := 0
	var nested := true
	var applied: Array[Vector3i] = []

	func run(keys: Array, start: int, end: int) -> bool:
		calls += 1
		nested = cursor.apply_slice(1, Callable(self, "run"))
		for index in range(start, end):
			applied.append(keys[index])
		return true


func _ready() -> void:
	timeout = 60.0
	test("the shared cursor applies every queued cell once across partial budgets", _cursor_partial_budget, "cursor_partial_budget")
	test("the shared cursor reports done only after every queued cell is applied", _cursor_no_eager_completion, "cursor_no_eager_completion")
	test("a cancel wakes a producer blocked on a full queue", _queue_cancel_full_producer, "queue_cancel_full_producer")
	test("a refused or reentrant slice callback keeps the cursor consistent", _slice_callback_reentrancy, "slice_callback_reentrancy")
	test("the streamed fill and wand keep their exact results and one undo", _fill_and_wand_results_undo, "fill_and_wand_results_undo")


func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.clear_selection()
	State.undo_redo.clear_history()
	frame = State.get_current_voxel_frame()
	_expected_cells = {}
	_producer_queue = null
	_producer_task = -1
	await get_tree().process_frame


# Leave no worker or open stroke behind, so a test can run alone or in any order.
func after_test() -> void:
	if is_instance_valid(fill_tool):
		fill_tool._interrupt_fill()
	if is_instance_valid(wand_tool):
		wand_tool._cancel_selection()
	var guard := 0
	while is_instance_valid(wand_tool) and (not wand_tool._retired_jobs.is_empty() or wand_tool._reaping) and guard < 600:
		await get_tree().process_frame
		guard += 1
	if _producer_queue != null:
		_producer_queue.cancel()
	if _producer_task != -1:
		WorkerThreadPool.wait_for_task_completion(_producer_task)
		_producer_task = -1
	State.clear_selection()
	State.undo_redo.clear_history()
	await _await_until(func(): return State.edit_busy())
	await get_tree().process_frame


func _await_until(condition: Callable, limit_ms := WAIT_LIMIT_MS) -> bool:
	var deadline := Time.get_ticks_msec() + limit_ms
	while condition.call():
		if Time.get_ticks_msec() >= deadline:
			return false
		await get_tree().process_frame
	return true


# Three batches of different sizes. The cell position is unique across them.
func _queue_three_batches(queue: VoxelRegionSearch.BatchQueue) -> Dictionary:
	var expected := {}
	var sizes := [3, 5, 4]
	for batch_index in sizes.size():
		var batch := {}
		var count: int = sizes[batch_index]
		for offset in count:
			var cell := Vector3i(batch_index, offset, 0)
			batch[cell] = true
			expected[cell] = true
		queue.push(batch)
	return expected


func _accept_slice(_keys: Array, _start: int, _end: int) -> bool:
	return true


func _cursor_partial_budget() -> void:
	step("Given three queued batches and a partial slice budget", func():
		var queue := VoxelRegionSearch.BatchQueue.new()
		var cursor := VoxelRegionSearch.BatchCursor.new(queue)
		var expected := _queue_three_batches(queue)
		var slice := BudgetSlice.new()
		expect(queue.depth() == 3, "the queue holds three batches")
		var slices := 0
		while cursor.apply_slice(2, Callable(slice, "run")):
			slices += 1
		expect(slices == 3, "the budget stopped after three slices")
		expect(slice.applied.size() == 5, "the three slices applied five cells")
		expect(not cursor.is_done(), "the cursor is not done while cells wait")
		slice.budget = 100
		while cursor.apply_slice(2, Callable(slice, "run")):
			slices += 1
		expect(cursor.is_done(), "the cursor is done after the tail")
		var unique := {}
		for cell_position: Vector3i in slice.applied:
			unique[cell_position] = true
		expect(slice.applied.size() == expected.size(), "every queued cell was applied")
		expect(unique.size() == expected.size(), "no queued cell was applied twice")
		expect(not cursor.apply_slice(2, Callable(slice, "run")), "a drained cursor yields no slice")
	)


func _cursor_no_eager_completion() -> void:
	step("Given one queued batch and a cursor", func():
		var queue := VoxelRegionSearch.BatchQueue.new()
		var cursor := VoxelRegionSearch.BatchCursor.new(queue)
		expect(queue.push({Vector3i.ZERO: true, Vector3i(1, 0, 0): true}), "the batch is accepted")
		expect(not cursor.is_done(), "a queued batch is not done")
		expect(cursor.apply_slice(1, _accept_slice), "the first slice applies")
		expect(cursor.cursor == 1, "the cursor advanced one key")
		expect(not cursor.is_done(), "a partly applied batch is not done")
		expect(cursor.apply_slice(1, _accept_slice), "the second slice applies")
		expect(cursor.is_done(), "the drained cursor is done")
		# The cursor never reports the producer. The caller tests its task.
		expect(cursor.is_done(), "an empty queue stays done without a producer")
	)


func _queue_cancel_full_producer() -> void:
	var producer := QueueProducer.new()
	step("Given a producer that fills the bounded queue", func():
		_producer_queue = VoxelRegionSearch.BatchQueue.new()
		producer.queue = _producer_queue
		_producer_task = WorkerThreadPool.add_task(producer.run, true, "Batch queue producer")
		expect(_producer_task != -1, "the producer started")
	)
	if _producer_task == -1:
		return
	var guard := 0
	while _producer_queue.depth() < QUEUE_LIMIT and guard < 600:
		await get_tree().process_frame
		guard += 1
	step("When the queue is full and the consumer cancels", func():
		expect(_producer_queue.depth() == QUEUE_LIMIT, "the producer filled the bounded queue")
		expect(not WorkerThreadPool.is_task_completed(_producer_task), "the full queue holds the producer")
		_producer_queue.cancel()
	)
	WorkerThreadPool.wait_for_task_completion(_producer_task)
	_producer_task = -1
	step("Then the producer stopped and the queue refuses later pushes", func():
		expect(_producer_queue.is_cancelled(), "the queue reports the cancel")
		expect(producer.pushed == QUEUE_LIMIT, "the producer stopped at the queued batch limit")
		expect(not _producer_queue.push({Vector3i(9999, 0, 0): true}), "a cancelled queue refuses a later push")
	)


func _slice_callback_reentrancy() -> void:
	step("Given a guarded callback that refuses a stale slice", func():
		var queue := VoxelRegionSearch.BatchQueue.new()
		var cursor := VoxelRegionSearch.BatchCursor.new(queue)
		expect(queue.push({Vector3i.ZERO: true, Vector3i(1, 0, 0): true}), "the batch is accepted")
		var guarded := GuardedSlice.new()
		guarded.valid = false
		expect(not cursor.apply_slice(2, Callable(guarded, "run")), "the stale callback refuses the slice")
		expect(cursor.cursor == 0 and cursor.keys.size() == 2, "the refused slice stays intact")
		guarded.valid = true
		expect(cursor.apply_slice(2, Callable(guarded, "run")), "the valid callback takes the slice")
		expect(guarded.applied.size() == 2, "the valid callback applied the whole slice")
		expect(cursor.is_done(), "the cursor is done after the accepted slice")
	)
	step("When a callback consumes the same cursor again", func():
		var queue := VoxelRegionSearch.BatchQueue.new()
		var cursor := VoxelRegionSearch.BatchCursor.new(queue)
		expect(queue.push({Vector3i.ZERO: true, Vector3i(1, 0, 0): true, Vector3i(2, 0, 0): true}), "the batch is accepted")
		var reentrant := ReentrantSlice.new()
		reentrant.cursor = cursor
		expect(cursor.apply_slice(2, Callable(reentrant, "run")), "the outer slice applies")
		expect(not reentrant.nested, "the nested slice call is refused")
		expect(reentrant.calls == 1, "the callback ran once")
		expect(reentrant.applied.size() == 2, "the outer slice applied two cells")
		expect(cursor.cursor == 2, "the outer slice kept its end")
		expect(cursor.apply_slice(2, Callable(reentrant, "run")), "the remaining slice applies")
		expect(reentrant.applied.size() == 3, "the tail is applied once")
		expect(cursor.is_done(), "the cursor is done after the tail")
	)


func _block_fixture() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	var cells := {}
	var material := VoxelFrame.material(Color.RED)
	for x in FILL_SIDE:
		for y in FILL_SIDE:
			for z in FILL_SIDE:
				cells[Vector3i(x, y, z)] = material
	frame.set_cells(cells)
	State.document._bounds_dirty = true
	State.clear_selection()
	State.undo_redo.clear_history()


func _expected_fill() -> VoxelFrame:
	var expected := _before.copy_frame()
	var replacement := VoxelFrame.material(Color.BLUE)
	var changes := {}
	REFERENCE.find(changes, expected, Vector3i.ZERO, expected.get_material(Vector3i.ZERO), true, replacement)
	_expected_cells = {}
	for cell_position in changes:
		_expected_cells[cell_position] = true
	expected.set_cells(changes, null, replacement)
	return expected


func _fill_and_wand_results_undo() -> void:
	step("Given a red block above the streaming limit", func():
		_block_fixture()
		_before = frame.copy_frame()
		expect(frame.count() == FILL_TOTAL, "the block holds every cell")
	)
	step("When the fill streams the block", func():
		select_toolbar_item("paint", "Bucket Fill")
		fill_tool = plugin("PaintPlugin")._fill_tool
		if fill_tool == null:
			return
		State.current_material = VoxelFrame.material(Color.BLUE)
		fill_tool._settings.connected = true
		fill_tool._release_pending = true
		fill_tool._queue_seed(Vector3i.ZERO)
	)
	if fill_tool == null:
		expect(false, "the paint plugin exposes the bucket fill")
		return
	await _await_until(func(): return State.edit_busy() or not fill_tool.is_settled() or not fill_tool._search_jobs.is_empty())
	step("Then the fill equals the reference and one undo restores the block", func():
		var expected := _expected_fill()
		expect(frame.storage_data() == expected.storage_data(), "the streamed fill equals the reference")
		expect(State.undo_redo.has_undo(), "the fill records one undo action")
		State.undo_redo.undo()
		expect(frame.storage_data() == _before.storage_data(), "one undo restores the red block")
		State.undo_redo.clear_history()
	)
	step("When the wand streams the same block", func():
		activate_tool("selection")
		select_toolbar_item("selection", "Wand")
		wand_tool = plugin("SelectionPlugin")._wand
		if wand_tool == null:
			return
		wand_tool._settings.connected = true
		wand_tool._settings.mode = wand_tool._settings.SelectMode.REPLACE
		State.selection.clear()
		wand_tool._commit(Vector3i.ZERO)
	)
	if wand_tool == null:
		expect(false, "the selection plugin exposes the wand")
		return
	await _await_until(func(): return wand_tool._job != null or State.edit_busy())
	step("Then the wand selects every cell and one undo clears it", func():
		var selected := {}
		for cell_position in State.selection.all_cells():
			selected[cell_position] = true
		expect(State.selection.count() == FILL_TOTAL, "the wand selected the whole block")
		expect(selected == _expected_cells, "the wand selected the same cells the fill matched")
		expect(State.undo_redo.has_undo(), "the wand records one undo action")
		State.undo_redo.undo()
		expect(State.selection.is_empty(), "one undo clears the wand selection")
		State.undo_redo.clear_history()
	)
