extends "res://tests/test.gd"

# Focused safety tests for the streamed bucket fill. They cover the settings the
# fill captures at the stroke start, the bounded main-thread apply of a streamed
# search, the coalesced chunk notification, one undo per stroke, a cancel after a
# partial result, and a tool switch.
#
#   godot --path . res://tests/progressive_fill_safety.tscn
#   godot --path . res://tests/progressive_fill_safety.tscn -- connected_capture

const REFERENCE := preload("res://tests/region_search_reference.gd")
const FILL_TOOL := preload("res://plugins/paint/FillTool.gd")


# A frame that counts the per-cell occupancy and material checks. The shared
# search never calls these, so the count shows exactly the calls the edit-context
# expansion makes. It proves the redundant filter is skipped or retained.
class CountingFrame extends VoxelFrame:
	var has_calls := 0
	var matches_calls := 0

	func has(cell_position: Vector3i) -> bool:
		has_calls += 1
		return super.has(cell_position)

	func matches(cell_position: Vector3i, cell_material: PackedFloat32Array) -> bool:
		matches_calls += 1
		return super.matches(cell_position, cell_material)


# Test-only A/B partner. It keeps the pre-change behavior: a streamed batch is
# always expanded through the edit context, even when that filter is redundant.
# The real job is compared against this path, not against itself.
class OldFilterFillJob extends FILL_TOOL.FillJob:
	func _expand_fill_batch(changes: Dictionary) -> Dictionary:
		if edit_context:
			return edit_context.expand(changes, source_frame, true, target_material, self)
		return changes


# Test-only. It cancels at the pre-write checkpoint, which follows the search
# progress checkpoint. It proves the identity atomic path still checks for a
# cancel before it writes.
class CancelOnApplyFillJob extends FILL_TOOL.FillJob:
	var checkpoints := 0
	var _saw_progress := false

	func checkpoint(completed: int) -> bool:
		checkpoints += 1
		if completed > 0:
			_saw_progress = true
		elif _saw_progress:
			return false
		return super.checkpoint(completed)
# A fill this size estimates above 4096, so the job streams its cells.
const SIDE := 20
const TOTAL := SIDE * SIDE * SIDE
# A larger block, so the streamed fill lasts many frames and a partial surface can
# install while the worker still runs.
const BIG_SIDE := 24
const BIG_TOTAL := BIG_SIDE * BIG_SIDE * BIG_SIDE
const D := Vector3i(64, 0, 0)
const E := Vector3i(68, 0, 0)
const G := Vector3i(72, 0, 0)
# Two disconnected large blocks for the stale-coroutine test.
const BLOCK_A := Vector3i.ZERO
const BLOCK_B := Vector3i(48, 0, 0)

var frame: VoxelFrame
var tool: Node
var _settings := preload("res://plugins/paint/settings.tres")
# Step lambdas capture locals by value, so the frames a later step needs are members.
var _before: VoxelFrame
var _expected_frame: VoxelFrame
var _mask := {}
var _max_installed := 0
var _partial_frames := 0
var _partial_surface_seen := false
var _worker_partial := false
var _peak_depth := 0
var _frames := 0
var _watch_us := 0
var _cancel_fired := false
var _new_activity_cancellable := false
var _reentrant_started := false
var _reentrant_busy := false
var _old_operation_id := 0
var _newer_keys: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(3, 0, 0), Vector3i(4, 0, 0), Vector3i(5, 0, 0)]
var _flush_count := 0


func _ready() -> void:
	timeout = 60.0
	test("the connected option is captured at the stroke start", _connected_capture, "connected_capture")
	test("the streamed fill matches the frozen reference for every mode", _parity, "parity")
	test("a search longer than the queue drops no cell", _queue_tail, "queue_tail")
	test("a partial surface installs while the worker still runs", _partial_surface, "partial_surface")
	test("one undo and one redo cover the whole streamed stroke", _undo_redo, "undo_redo")
	test("a cancel after a partial result restores the whole stroke", _cancel_partial, "cancel_partial")
	test("a cancel then a new fill leaves no stale work", _cancel_then_new, "cancel_then_new")
	test("a reentrant restart keeps its own operation and state", _reentrant_restart, "reentrant_restart")
	test("a document or frame change stops the streamed fill", _context_change, "context_change")
	test("a tool switch lets the fill finish and adds no second connection", _tool_switch, "tool_switch")
	test("the status widget cancels a detached fill", _widget_cancel, "widget_cancel")
	test("an unrelated selection change does not cancel the fill", _unrelated_cancel, "unrelated_cancel")
	test("a stale cancelled coroutine does not drop the new fill", _stale_finalize, "stale_finalize")
	test("a stale finalizer leaves a newer pending slice and chunks alone", _stale_guard, "stale_guard")
	test("benchmark: a large fill settles with the expected result", _bench_fill, "bench_fill")
	test("an identity context skips the redundant per-cell filter", _identity_skips_filter, "identity_skips_filter")
	test("a streamed identity batch skips the filter and keeps every cell", _stream_identity_skips_filter, "stream_identity_skips_filter")
	test("the identity fill matches the frozen reference atomic and streamed", _identity_matches_reference, "identity_matches_reference")
	test("a selection keeps the expansion and drops an excluded seed", _selection_keeps_filter, "selection_keeps_filter")
	test("symmetry keeps the reflected occupancy and material filter", _symmetry_keeps_filter, "symmetry_keeps_filter")
	test("a cancelled fill job writes nothing", _cancel_before_write, "cancel_before_write")


# Each test starts from a fresh document, the default symmetry, and connected on.
func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.clear_selection()
	State.undo_redo.clear_history()
	_settings.connected = true
	_before = null
	await get_tree().process_frame


# Leave no worker or open stroke behind, so a test can run alone or in any order.
func after_test() -> void:
	if State.chunks_changed.is_connected(_on_first_notification):
		State.chunks_changed.disconnect(_on_first_notification)
	if State.chunks_changed.is_connected(_count_flush):
		State.chunks_changed.disconnect(_count_flush)
	if tool != null:
		tool._interrupt_fill()
	State.clear_selection()
	State.undo_redo.clear_history()
	while State.edit_busy() or (tool != null and not tool._search_jobs.is_empty()):
		await get_tree().process_frame
	await get_tree().process_frame


func _block(x_side: int, y_side: int, z_side: int) -> Dictionary:
	var cells := {}
	var material := VoxelFrame.material(Color.RED)
	for x in x_side:
		for y in y_side:
			for z in z_side:
				cells[Vector3i(x, y, z)] = material
	return cells


func _count_block(x_side: int, y_side: int, z_side: int, color: Color) -> int:
	var total := 0
	for x in x_side:
		for y in y_side:
			for z in z_side:
				if frame.get_color(Vector3i(x, y, z)) == color:
					total += 1
	return total


func _fill_tool() -> void:
	select_toolbar_item("paint", "Bucket Fill")
	tool = plugin("PaintPlugin")._fill_tool
	State.current_material = VoxelFrame.material(Color.BLUE)
	State.undo_redo.clear_history()


# Build a fresh document and frame, install the red block, and tell the renderer
# to show it, so a later partial surface can be told from the start state. This
# stays synchronous, because a step lambda must not await.
func _stream_fixture(x_side: int, y_side: int, z_side: int, extra: Array[Vector3i] = []) -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	frame.set_cells(_block(x_side, y_side, z_side))
	for cell in extra:
		frame.set_cell(cell, VoxelFrame.material(Color.RED))
	State.document._bounds_dirty = true
	State.clear_selection()
	State.undo_redo.clear_history()
	_fill_tool()
	sync_viewport()


func _expected(before: VoxelFrame, seed_cell: Vector3i, connected: bool, mask: Dictionary) -> VoxelFrame:
	var expected := before.copy_frame()
	var target := expected.get_material(seed_cell)
	var replacement := VoxelFrame.material(Color.BLUE)
	var changes := {}
	REFERENCE.find(changes, expected, seed_cell, target, connected, replacement, mask)
	changes = State.drawing_context().expand(changes, expected, true, target)
	expected.set_cells(changes, null, replacement)
	return expected


func _settle_fill() -> void:
	while State.edit_busy() or not tool.is_settled() or not tool._search_jobs.is_empty():
		await get_tree().process_frame


func _settle_renderer() -> void:
	var renderer := viewport_scene().get_node_or_null("VoxelRenderer")
	if renderer == null:
		return
	while not renderer.is_settled():
		await get_tree().process_frame


func _installed_vertices() -> int:
	var renderer := viewport_scene().get_node_or_null("VoxelRenderer")
	if renderer == null:
		return 0
	var total := 0
	for instance in renderer._chunk_instances.values():
		if instance.mesh and instance.mesh.get_surface_count() > 0:
			total += instance.mesh.surface_get_array_len(0)
	return total


# The revision of every chunk surface the renderer has installed. A change while
# the fill is partial means the renderer meshed a partial state of the fill.
func _displayed_signature() -> String:
	var renderer := viewport_scene().get_node_or_null("VoxelRenderer")
	if renderer == null:
		return ""
	var parts := PackedStringArray()
	for chunk_location in renderer._displayed_surface_keys:
		var surface_key: PackedInt64Array = renderer._displayed_surface_keys[chunk_location]
		if surface_key.size() >= 3:
			parts.append("%s=%d" % [str(chunk_location), surface_key[2]])
	return "|".join(parts)


# Watch a running fill frame by frame. Records the peak queue depth, the frames
# that showed a partial result, and whether a partial surface installed.
func _watch_fill(x_side: int, y_side: int, z_side: int, total: int) -> void:
	_max_installed = 0
	_partial_frames = 0
	_partial_surface_seen = false
	_worker_partial = false
	_peak_depth = 0
	_frames = 0
	_watch_us = 0
	var started_us := Time.get_ticks_usec()
	var initial_signature := _displayed_signature()
	while State.edit_busy() or not tool.is_settled() or not tool._search_jobs.is_empty():
		await get_tree().process_frame
		_frames += 1
		var blue := _count_block(x_side, y_side, z_side, Color.BLUE)
		var installed := _installed_vertices()
		_max_installed = maxi(_max_installed, installed)
		for search_job in tool._search_jobs:
			if search_job.batch_queue:
				_peak_depth = maxi(_peak_depth, search_job.batch_queue.depth())
		if blue > 0 and blue < total:
			_partial_frames += 1
			if installed > 0 and not tool._search_jobs.is_empty():
				_worker_partial = true
			if _displayed_signature() != initial_signature:
				_partial_surface_seen = true
	_watch_us = Time.get_ticks_usec() - started_us


func _connected_capture() -> void:
	step("Given a large block and three isolated matching voxels", func():
		_stream_fixture(BIG_SIDE, BIG_SIDE, BIG_SIDE, [D, E, G])
		_before = frame.copy_frame()
		expect(frame.count() == BIG_TOTAL + 3, "the fixture holds the block and the three voxels")
	)
	step("When the user fills the block, flips the option, and fills a distant voxel", func():
		_settings.connected = true
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
		expect(State.edit_busy(), "the large fill reports foreground work")
		expect(not tool._search_jobs.is_empty(), "the large fill runs a worker")
		_settings.connected = false
		tool._queue_seed(D)
	)
	await _settle_fill()
	step("Then the queued seed kept the connected setting from the stroke start", func():
		expect(_count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.BLUE) == BIG_TOTAL, "the block takes the fill material")
		expect(frame.get_color(D) == Color.BLUE, "the queued distant voxel takes the fill material")
		expect(frame.get_color(E) == Color.RED, "the other matching voxel stays, because the queued seed kept connected on")
		expect(frame.get_color(G) == Color.RED, "the third matching voxel stays")
	)
	step("When the user fills again with connected off in a new stroke", func():
		_settings.connected = false
		tool._release_pending = true
		tool._queue_seed(G)
	)
	await _settle_fill()
	step("Then the new stroke reads the option and fills every matching voxel", func():
		expect(frame.get_color(G) == Color.BLUE, "the seed voxel takes the fill material")
		expect(frame.get_color(E) == Color.BLUE, "the new disconnected fill reaches the other matching voxel")
	)


func _parity() -> void:
	for connected in [true, false]:
		var label := "connected" if connected else "disconnected"
		step("Given a large block and the fill tool with %s" % label, func():
			_stream_fixture(SIDE, SIDE, SIDE)
			_settings.connected = connected
			_before = frame.copy_frame()
			_expected_frame = _expected(_before, Vector3i.ZERO, connected, {})
			tool._release_pending = true
			tool._queue_seed(Vector3i.ZERO)
		)
		await _settle_fill()
		step("Then the streamed %s fill equals the frozen reference" % label, func():
			expect(frame.storage_data() == _expected_frame.storage_data(), "the streamed %s fill equals the reference" % label)
			State.undo_redo.undo()
			State.undo_redo.clear_history()
		)
	step("Given a selected half block", func():
		_stream_fixture(SIDE, SIDE, SIDE)
		for x in range(0, SIDE / 2):
			for y in SIDE:
				for z in SIDE:
					State.selection.add(Vector3i(x, y, z))
		_mask = State.selection.capture()
		_settings.connected = true
		_before = frame.copy_frame()
		_expected_frame = _expected(_before, Vector3i.ZERO, true, _mask)
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	await _settle_fill()
	step("Then the masked streamed fill equals the frozen reference", func():
		expect(frame.storage_data() == _expected_frame.storage_data(), "the masked streamed fill equals the reference")
		expect(_count_block(SIDE, SIDE, SIDE, Color.BLUE) == TOTAL / 2, "the fill covers only the selected half")
		State.undo_redo.undo()
		State.undo_redo.clear_history()
		State.clear_selection()
	)
	step("Given a mirrored matching voxel and the X plane on", func():
		_stream_fixture(SIDE, SIDE, SIDE, [Vector3i(-3, 0, 0), Vector3i(-5, 5, 5)])
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3.ZERO
		_settings.connected = true
		_before = frame.copy_frame()
		_expected_frame = _expected(_before, Vector3i.ZERO, true, {})
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	await _settle_fill()
	step("Then the mirrored streamed fill equals the frozen reference", func():
		expect(frame.storage_data() == _expected_frame.storage_data(), "the mirrored streamed fill equals the reference")
		expect(frame.get_color(Vector3i(-3, 0, 0)) == Color.BLUE, "the reflected voxel takes the fill material")
		expect(frame.get_color(Vector3i(-5, 5, 5)) == Color.BLUE, "the second reflected voxel takes the fill material")
		State.undo_redo.undo()
		State.undo_redo.clear_history()
		State.symmetry_axes = 0
		State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	)


func _queue_tail() -> void:
	step("Given a block whose search is longer than the handoff queue", func():
		_stream_fixture(BIG_SIDE, BIG_SIDE, BIG_SIDE)
		_settings.connected = true
		_before = frame.copy_frame()
		_expected_frame = _expected(_before, Vector3i.ZERO, true, {})
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	await _watch_fill(BIG_SIDE, BIG_SIDE, BIG_SIDE, BIG_TOTAL)
	step("Then every found cell lands and the queue stays inside its bound", func():
		expect(frame.storage_data() == _expected_frame.storage_data(), "the long stream equals the frozen reference")
		expect(_count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.BLUE) == BIG_TOTAL, "no found cell is dropped")
		expect(_peak_depth <= 4, "the handoff queue stayed inside its bound")
		expect(_frames > 1, "the fill streamed across more than one frame")
		print("MEASURE fill safety: queue_tail cells=%d frames=%d total_us=%d peak_depth=%d" % [BIG_TOTAL, _frames, _watch_us, _peak_depth])
		State.undo_redo.undo()
		State.undo_redo.clear_history()
	)


func _partial_surface() -> void:
	step("Given a large block and the fill tool", func():
		_stream_fixture(BIG_SIDE, BIG_SIDE, BIG_SIDE)
		_settings.connected = true
		_before = frame.copy_frame()
		_expected_frame = _expected(_before, Vector3i.ZERO, true, {})
	)
	# Let the start surface install, so a later change proves a partial rebuild.
	await _settle_renderer()
	step("When the user fills the block", func():
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	await _watch_fill(BIG_SIDE, BIG_SIDE, BIG_SIDE, BIG_TOTAL)
	await _settle_renderer()
	step("Then a partial result and a partial surface arrived before the end", func():
		expect(_partial_frames > 0, "the live frame showed a partial fill while the job ran")
		expect(_max_installed > 0, "the renderer installed a surface while the job ran")
		expect(_worker_partial, "a surface was installed while the worker still ran")
		expect(_partial_surface_seen, "the installed surface was meshed from a partial fill state")
		expect(_peak_depth <= 4, "the handoff queue stayed inside its bound")
		print("MEASURE fill safety: partial cells=%d frames=%d total_us=%d partial_frames=%d installed=%d partial_surface=%s" % [
			BIG_TOTAL, _frames, _watch_us, _partial_frames, _max_installed, str(_partial_surface_seen),
		])
	)
	step("Then the final fill equals the frozen expectation", func():
		expect(frame.storage_data() == _expected_frame.storage_data(), "the streamed frame equals the reference frame")
		State.undo_redo.undo()
		State.undo_redo.clear_history()
	)


func _undo_redo() -> void:
	step("Given a large red block", func():
		_stream_fixture(BIG_SIDE, BIG_SIDE, BIG_SIDE)
		_settings.connected = true
		_before = frame.copy_frame()
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	await _settle_fill()
	step("Then one undo restores the start and one redo applies the whole fill", func():
		expect(_count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.BLUE) == BIG_TOTAL, "the block takes the fill material")
		expect(State.undo_redo.has_undo(), "the fill records one undo action")
		State.undo_redo.undo()
		expect(frame.storage_data() == _before.storage_data(), "one undo restores the whole start frame")
		State.undo_redo.redo()
		expect(_count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.BLUE) == BIG_TOTAL, "one redo applies the whole fill")
		State.undo_redo.clear_history()
	)


func _cancel_partial() -> void:
	step("Given a large red block and a running fill", func():
		_stream_fixture(BIG_SIDE, BIG_SIDE, BIG_SIDE)
		_settings.connected = true
		_before = frame.copy_frame()
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	while _count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.BLUE) == 0 or not State.edit_busy():
		await get_tree().process_frame
	step("Then a partial result is already applied", func():
		var blue := _count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.BLUE)
		expect(blue > 0 and blue < BIG_TOTAL, "the fill applied a partial result before the cancel")
		expect(State.cancel_operation(State.get_activity().id), "the cancel request is accepted")
	)
	await _settle_fill()
	step("Then the cancel restores the whole stroke with no history", func():
		expect(frame.storage_data() == _before.storage_data(), "the cancelled fill restores every cell")
		expect(not State.undo_redo.has_undo(), "the cancelled fill records no history")
		expect(not State.edit_busy(), "the cancelled fill releases editing")
		expect(tool._search_jobs.is_empty(), "the cancelled fill joins its worker")
	)


func _cancel_then_new() -> void:
	step("Given a running fill that is cancelled", func():
		_stream_fixture(BIG_SIDE, BIG_SIDE, BIG_SIDE)
		_settings.connected = true
		_before = frame.copy_frame()
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	while _count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.BLUE) == 0 or not State.edit_busy():
		await get_tree().process_frame
	step("When the user cancels and starts a new fill with another material", func():
		expect(State.cancel_operation(State.get_activity().id), "the cancel request is accepted")
		State.current_material = VoxelFrame.material(Color.GREEN)
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	await _settle_fill()
	step("Then the new fill covers the block and one undo restores the start", func():
		expect(_count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.GREEN) == BIG_TOTAL, "the new fill covers the connected block")
		expect(_count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.BLUE) == 0, "no cancelled work survives")
		expect(not State.edit_busy(), "the completed fill releases editing")
		State.undo_redo.undo()
		expect(frame.storage_data() == _before.storage_data(), "one undo restores the start frame")
		State.undo_redo.clear_history()
	)


# A rollback starts a new fill from a selection-changed handler. The old cancel
# must finish only its own operation, so the replacement keeps its busy state and
# its cancel capability.
func _on_rollback_start_fill() -> void:
	if _reentrant_started:
		return
	_reentrant_started = true
	State.current_material = VoxelFrame.material(Color.GREEN)
	tool._release_pending = true
	tool._queue_seed(Vector3i.ZERO)
	var activity := State.get_activity()
	_reentrant_busy = activity != null and activity.can_cancel()


func _reentrant_restart() -> void:
	step("Given a running streamed fill and a rollback handler that starts a new one", func():
		_stream_fixture(BIG_SIDE, BIG_SIDE, BIG_SIDE)
		_settings.connected = true
		_before = frame.copy_frame()
		_reentrant_started = false
		_reentrant_busy = false
		State.selection_changed.connect(_on_rollback_start_fill, CONNECT_ONE_SHOT)
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	while _count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.BLUE) == 0 or not State.edit_busy():
		await get_tree().process_frame
	step("When the fill is interrupted during a partial result", func():
		_old_operation_id = State.get_activity().id
		tool._interrupt_fill()
		expect(_reentrant_started, "the rollback handler started a new fill")
		expect(State.get_activity() != null and State.get_activity().id == tool._operation_id, "the replacement operation owns the activity")
		expect(State.get_activity() != null and State.get_activity().can_cancel(), "the replacement operation stays cancellable")
		expect(not State.has_operation(_old_operation_id), "the old operation is finished")
	)
	await _settle_fill()
	step("Then the replacement fill completes with one undo and no dropped tail", func():
		expect(_reentrant_busy, "the replacement fill was cancellable when it started")
		expect(_count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.GREEN) == BIG_TOTAL, "the replacement fill covers the block")
		expect(_count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.BLUE) == 0, "no cancelled work survives")
		expect(not State.edit_busy(), "the replacement fill releases editing")
		expect(State.undo_redo.has_undo(), "the replacement fill records one undo action")
		State.undo_redo.undo()
		expect(frame.storage_data() == _before.storage_data(), "one undo restores the start frame")
		State.undo_redo.clear_history()
	)


func _context_change() -> void:
	step("Given a running fill on the first frame", func():
		State.document = VoxelDocument.new()
		State.document.add_frame()
		State.current_frame = 0
		frame = State.get_current_voxel_frame()
		frame.set_cells(_block(SIDE, SIDE, SIDE))
		State.document._bounds_dirty = true
		State.undo_redo.clear_history()
		_fill_tool()
		sync_viewport()
		_settings.connected = true
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	while _count_block(SIDE, SIDE, SIDE, Color.BLUE) == 0 or not State.edit_busy():
		await get_tree().process_frame
	step("When the user switches to the second frame", func():
		State.current_frame = 1
	)
	await _settle_fill()
	step("Then the fill stops and the switched-to frame stays empty", func():
		expect(State.get_current_voxel_frame().count() == 0, "the switched-to frame stays empty")
		expect(not State.edit_busy(), "the frame change releases the fill")
	)
	step("When the user replaces the document during another fill", func():
		State.current_frame = 0
		State.undo_redo.clear_history()
		_fill_tool()
		_settings.connected = true
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	while _count_block(SIDE, SIDE, SIDE, Color.BLUE) == 0 or not State.edit_busy():
		await get_tree().process_frame
	step("Then the replacement document receives no old fill", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
	)
	await _settle_fill()
	step("Then the new document stays empty", func():
		expect(State.get_current_voxel_frame().count() == 0, "the replacement document stays empty")
		expect(not State.edit_busy(), "the document change releases the fill")
	)


# On the first notification of a running fill, cancel it and start a second fill.
# The cancelled coroutine still has to finish, and it must not clear the new fill's
# pending slice or emit the new fill's chunks early. The notification fires from the
# running fill's own drain, so the new fill registers its frame wait after the old
# one, and the new fill resumes first with a partial pending slice.
func _on_first_notification(_updated_frame: int, _chunks: Array[Vector3i]) -> void:
	if _cancel_fired:
		return
	_cancel_fired = true
	tool._interrupt_fill()
	tool._release_pending = true
	tool._queue_seed(BLOCK_B)
	var activity := State.get_activity()
	_new_activity_cancellable = activity != null and activity.can_cancel()


func _block_at(origin: Vector3i, side: int) -> Dictionary:
	var cells := {}
	var material := VoxelFrame.material(Color.RED)
	for x in side:
		for y in side:
			for z in side:
				cells[origin + Vector3i(x, y, z)] = material
	return cells


func _count_block_at(origin: Vector3i, x_side: int, y_side: int, z_side: int, color: Color) -> int:
	var total := 0
	for x in x_side:
		for y in y_side:
			for z in z_side:
				if frame.get_color(origin + Vector3i(x, y, z)) == color:
					total += 1
	return total


func _stale_finalize() -> void:
	step("Given two large blocks and the fill tool", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cells(_block_at(BLOCK_A, BIG_SIDE))
		frame.set_cells(_block_at(BLOCK_B, BIG_SIDE))
		State.document._bounds_dirty = true
		State.clear_selection()
		State.undo_redo.clear_history()
		_fill_tool()
		sync_viewport()
		_settings.connected = true
		_before = frame.copy_frame()
		_cancel_fired = false
		_new_activity_cancellable = false
		State.chunks_changed.connect(_on_first_notification)
	)
	step("When the first notification cancels the running fill into a new fill", func():
		tool._release_pending = true
		tool._queue_seed(BLOCK_A)
		expect(not _cancel_fired, "the first notification has not fired yet")
	)
	await _settle_fill()
	await _settle_renderer()
	step("Then the new fill completes with no dropped cell and its own state", func():
		expect(_cancel_fired, "the first notification cancelled the old fill and started a new one")
		expect(_new_activity_cancellable, "the new fill keeps its cancel capability")
		expect(_count_block_at(BLOCK_B, BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.BLUE) == BIG_TOTAL, "the new fill covers its whole block")
		expect(_count_block_at(BLOCK_A, BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.RED) == BIG_TOTAL, "the cancelled fill restored its block")
		expect(tool._search_jobs.is_empty(), "both workers are reaped")
		expect(not State.edit_busy(), "the new fill releases editing")
		expect(_installed_vertices() > 0, "the renderer installed a surface for the new fill")
		expect(State.undo_redo.has_undo(), "the new fill records one undo action")
		State.undo_redo.undo()
		expect(frame.storage_data() == _before.storage_data(), "one undo restores both blocks")
		State.undo_redo.clear_history()
	)


func _count_flush(_updated_frame: int, _chunks: Array[Vector3i]) -> void:
	_flush_count += 1


# A controlled interleaving of the stale-finalizer race. The running fill owns a
# partial pending slice. It is cancelled, and the slice is handed to a newer
# operation before the cancelled coroutine finishes. Headless frame timing does not
# land a real new worker's first slice before the old coroutine finishes, so the
# handoff is forced here. The stale finalizer must leave the newer slice and its
# coalesced chunks alone.
func _stale_guard() -> void:
	step("Given a running fill that owns a partial pending slice", func():
		_stream_fixture(BIG_SIDE, BIG_SIDE, BIG_SIDE)
		_settings.connected = true
		# A one-cell slice keeps the running fill on a partial batch across a frame,
		# so the stale finalizer can be observed against it.
		tool._slice_cells = 1
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	var waited := 0
	while tool._batch_cursor.cursor == 0 and waited < 240:
		await get_tree().process_frame
		waited += 1
	step("When the fill is cancelled while a newer operation owns a partial slice", func():
		expect(tool._batch_cursor.cursor > 0, "the running fill owns a partial pending slice")
		tool._interrupt_fill()
		tool._batch_cursor.keys.assign(_newer_keys)
		tool._batch_cursor.cursor = 3
		tool._changed_chunks[Vector3i(1, 0, 0)] = true
		_flush_count = 0
		State.chunks_changed.connect(_count_flush)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the stale finalizer left the newer slice and its chunks alone", func():
		expect(tool._batch_cursor.keys.size() == _newer_keys.size(), "the newer pending slice is intact")
		expect(tool._batch_cursor.cursor == 3, "the newer pending cursor is intact")
		expect(tool._changed_chunks.has(Vector3i(1, 0, 0)), "the newer chunk set is intact")
		expect(_flush_count == 0, "the stale finalizer did not flush the newer chunks")
		State.chunks_changed.disconnect(_count_flush)
		tool._batch_cursor = VoxelRegionSearch.BatchCursor.new()
		tool._changed_chunks.clear()
		tool._slice_cells = 128
	)


# A clean wall-time measure: queue a large fill and wait for it to settle, with no
# per-frame scan in between.
func _bench_fill() -> void:
	step("Given a large block and the fill tool", func():
		_stream_fixture(BIG_SIDE, BIG_SIDE, BIG_SIDE)
		_settings.connected = true
	)
	await _settle_renderer()
	var started_us := Time.get_ticks_usec()
	var frames := 0
	step("When the user fills the block", func():
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	while State.edit_busy() or not tool.is_settled() or not tool._search_jobs.is_empty():
		await get_tree().process_frame
		frames += 1
	var total_us := Time.get_ticks_usec() - started_us
	step("Then the fill covers the block", func():
		expect(_count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.BLUE) == BIG_TOTAL, "the bench fill covers the block")
		print("MEASURE fill safety: bench cells=%d fill_us=%d frames=%d slice=%d" % [BIG_TOTAL, total_us, frames, tool._slice_cells])
		State.undo_redo.undo()
		State.undo_redo.clear_history()
	)


func _fill_connections() -> int:
	var count := 0
	for connection in State.edit_context_changing.get_connections():
		if connection["callable"].get_object() == tool:
			count += 1
	return count


func _tool_switch() -> void:
	step("Given a running fill and a switch to another tool", func():
		_stream_fixture(BIG_SIDE, BIG_SIDE, BIG_SIDE)
		_settings.connected = true
		_before = frame.copy_frame()
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	while _count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.BLUE) == 0:
		await get_tree().process_frame
	step("Then the switched-away fill keeps running", func():
		activate_tool("selection")
		expect(State.edit_busy(), "the tool switch did not cancel the fill")
		expect(not tool._search_jobs.is_empty(), "the detached fill keeps its worker")
	)
	await _settle_fill()
	step("Then the detached fill completes with one undo action", func():
		expect(frame.storage_data() == _expected(_before, Vector3i.ZERO, true, {}).storage_data(), "the detached fill equals the reference")
		expect(State.undo_redo.has_undo(), "the detached fill records one undo action")
		State.undo_redo.undo()
		State.undo_redo.clear_history()
	)
	step("When the user switches back to the fill tool", func():
		select_toolbar_item("paint", "Bucket Fill")
	)
	step("Then the fill holds exactly one context connection", func():
		expect(_fill_connections() == 1, "a switch back adds no second connection")
	)


func _widget_cancel() -> void:
	step("Given a running fill and a switch to another tool", func():
		_stream_fixture(BIG_SIDE, BIG_SIDE, BIG_SIDE)
		_settings.connected = true
		_before = frame.copy_frame()
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	while _count_block(BIG_SIDE, BIG_SIDE, BIG_SIDE, Color.BLUE) == 0 or not State.edit_busy():
		await get_tree().process_frame
	step("When the user detaches the tool and presses the status cancel button", func():
		activate_tool("selection")
		expect(State.edit_busy(), "the detached fill still runs")
		var activity: Node = main.get_node_or_null("Content/VBoxContainer/StatusBar/Activity")
		expect(activity != null, "the status widget exists")
		if activity == null:
			return
		activity.delay_ms = 0
		activity._refresh_from_state()
		expect(activity._cancel.visible, "the status widget shows its cancel button")
		activity._cancel.pressed.emit()
	)
	await _settle_fill()
	step("Then the widget cancel restores the whole stroke with no history", func():
		expect(frame.storage_data() == _before.storage_data(), "the widget cancel restores every cell")
		expect(not State.undo_redo.has_undo(), "the widget cancel records no history")
		expect(not State.edit_busy(), "the widget cancel releases editing")
	)


func _unrelated_cancel() -> void:
	step("Given a running fill", func():
		_stream_fixture(SIDE, SIDE, SIDE)
		_settings.connected = true
		_before = frame.copy_frame()
		tool._release_pending = true
		tool._queue_seed(Vector3i.ZERO)
	)
	while _count_block(SIDE, SIDE, SIDE, Color.BLUE) == 0 or not State.edit_busy():
		await get_tree().process_frame
	step("When the user adds a selection cell and emits an unrelated edit signal", func():
		State.selection.add(Vector3i(99, 99, 99))
		var affected: Array[Vector3i] = []
		State.cells_changed.emit(State.current_frame, affected)
		expect(State.edit_busy(), "the unrelated signals did not cancel the fill")
	)
	await _settle_fill()
	step("Then the fill completes and keeps the unrelated selection", func():
		expect(_count_block(SIDE, SIDE, SIDE, Color.BLUE) == TOTAL, "the fill completes")
		expect(State.selection.contains(Vector3i(99, 99, 99)), "the unrelated selection cell stays")
		State.undo_redo.undo()
		expect(frame.storage_data() == _before.storage_data(), "one undo restores the start frame")
		State.undo_redo.clear_history()
		State.clear_selection()
	)


# A counting frame that holds the same uniform block as the shared fixture.
func _counting_block(x_side: int, y_side: int, z_side: int) -> CountingFrame:
	var counting := CountingFrame.new()
	counting.set_cells(_block(x_side, y_side, z_side))
	counting.has_calls = 0
	counting.matches_calls = 0
	return counting


# The real fill job over the live fixture, run in one atomic step. The edit
# context is the default: no symmetry axes and an empty selection.
func _atomic_fill_frame(old_filter: bool) -> VoxelFrame:
	var job: Variant = OldFilterFillJob.new() if old_filter else FILL_TOOL.FillJob.new()
	job.source_frame = frame.copy_frame()
	job.edit_context = State.drawing_context()
	job.selection_mask = {}
	job.seed_cell = Vector3i.ZERO
	job.target_material = frame.get_material(Vector3i.ZERO)
	job.connected = true
	job.replacement_material = VoxelFrame.material(Color.BLUE)
	job.apply_changes = true
	job.run()
	var result: VoxelFrame = job.source_frame
	return result


# The identity atomic fill must still write the whole block, and the per-cell
# filter must not run. The counting frame proves the second part.
func _identity_skips_filter() -> void:
	step("Given a counting frame and the fill job with an identity context", func():
		var counting := _counting_block(SIDE, SIDE, SIDE)
		expect(counting.count() == TOTAL, "the counting frame holds the whole block")
		var job: Variant = FILL_TOOL.FillJob.new()
		job.source_frame = counting
		job.edit_context = State.drawing_context()
		job.selection_mask = {}
		job.seed_cell = Vector3i.ZERO
		job.target_material = counting.get_material(Vector3i.ZERO)
		job.connected = true
		job.replacement_material = VoxelFrame.material(Color.BLUE)
		job.apply_changes = true
		job.run()
		expect(job.matching_cells.size() == TOTAL, "the search matched the whole block")
		expect(job.applied_cells.size() == TOTAL, "the write data holds every matched cell")
		expect(job.changed_chunks.size() > 0, "the fill reports its changed chunks")
		expect(counting.has_calls == 0, "the identity fill skipped the per-cell has check")
		expect(counting.matches_calls == 0, "the identity fill skipped the per-cell material check")
	)


# One real streamed batch. The identity job returns the owned batch unchanged,
# while the old-filter job checks each cell. The same batch content reaches the
# queue in both cases.
func _stream_identity_skips_filter() -> void:
	step("Given a counting frame and one streamed batch with an identity context", func():
		var counting := _counting_block(SIDE, SIDE, SIDE)
		var job: Variant = FILL_TOOL.FillJob.new()
		job.source_frame = counting
		job.edit_context = State.drawing_context()
		job.seed_cell = Vector3i.ZERO
		job.target_material = counting.get_material(Vector3i.ZERO)
		job.replacement_material = VoxelFrame.material(Color.BLUE)
		job.batch_queue = VoxelRegionSearch.BatchQueue.new()
		var cells: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)]
		job._stream_batch(cells)
		var batch: Dictionary = job.batch_queue.take()
		expect(batch.size() == 3, "the identity batch keeps every found cell")
		expect(batch[Vector3i(1, 0, 0)] == job.replacement_material, "the identity batch carries the replacement material")
		expect(counting.has_calls == 0, "the identity stream skipped the per-cell has check")
		expect(counting.matches_calls == 0, "the identity stream skipped the per-cell material check")
	)
	step("Given the same batch through the old filter job", func():
		var counting := _counting_block(SIDE, SIDE, SIDE)
		var job: Variant = OldFilterFillJob.new()
		job.source_frame = counting
		job.edit_context = State.drawing_context()
		job.seed_cell = Vector3i.ZERO
		job.target_material = counting.get_material(Vector3i.ZERO)
		job.replacement_material = VoxelFrame.material(Color.BLUE)
		job.batch_queue = VoxelRegionSearch.BatchQueue.new()
		var cells: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)]
		job._stream_batch(cells)
		var batch: Dictionary = job.batch_queue.take()
		expect(batch.size() == 3, "the old filter kept every matching cell")
		expect(counting.has_calls > 0, "the old filter checked each cell for occupancy")
		expect(counting.matches_calls > 0, "the old filter checked each cell for its material")
	)


# The atomic and the streamed identity fills must equal the frozen reference,
# and the old filter must give the same frame. This is the data check, not a
# timing check.
func _identity_matches_reference() -> void:
	step("Given a red block and its frozen fill reference", func():
		_stream_fixture(SIDE, SIDE, SIDE)
		_before = frame.copy_frame()
		_expected_frame = _expected(_before, Vector3i.ZERO, true, {})
		expect(_expected_frame.count() == TOTAL, "the reference covers the whole block")
	)
	step("Then the atomic identity fill and the old filter equal the reference", func():
		var atomic := _atomic_fill_frame(false)
		var old := _atomic_fill_frame(true)
		expect(atomic.storage_data() == _expected_frame.storage_data(), "the atomic identity fill equals the reference")
		expect(old.storage_data() == _expected_frame.storage_data(), "the old-filter fill equals the reference")
	)
	step("Then the streamed identity fill equals the reference", func():
		var side := 12
		var total := side * side * side
		var counting := _counting_block(side, side, side)
		var reference := counting.copy_frame()
		var target := reference.get_material(Vector3i.ZERO)
		var replacement := VoxelFrame.material(Color.BLUE)
		var changes := {}
		REFERENCE.find(changes, reference, Vector3i.ZERO, target, true, replacement, {})
		reference.set_cells(changes, null, replacement)
		var job: Variant = FILL_TOOL.FillJob.new()
		job.source_frame = counting
		job.edit_context = State.drawing_context()
		job.selection_mask = {}
		job.seed_cell = Vector3i.ZERO
		job.target_material = target
		job.connected = true
		job.replacement_material = replacement
		job.apply_changes = false
		job.batch_queue = VoxelRegionSearch.BatchQueue.new()
		job.run()
		var applied: VoxelFrame = counting.copy_frame()
		var batch: Dictionary = job.batch_queue.take()
		while not batch.is_empty():
			applied.set_cells(batch, null, replacement)
			batch = job.batch_queue.take()
		expect(counting.has_calls == 0, "the streamed identity search skipped the per-cell filter")
		expect(applied.count() == total, "the streamed fill covers the whole block")
		expect(applied.storage_data() == reference.storage_data(), "the streamed identity fill equals the reference")
	)


# A non-empty selection keeps the expansion. The search adds its seed without a
# mask test, so the context must drop a seed that the selection excludes.
func _selection_keeps_filter() -> void:
	step("Given a counting frame, a selection that excludes the seed, and the fill job", func():
		var counting := _counting_block(SIDE, SIDE, SIDE)
		var mask := {}
		for x in SIDE:
			for y in SIDE:
				for z in SIDE:
					var cell := Vector3i(x, y, z)
					if cell != Vector3i.ZERO:
						mask[cell] = true
		var job: Variant = FILL_TOOL.FillJob.new()
		job.source_frame = counting
		job.edit_context = State.drawing_context()
		job.edit_context.selection = mask
		job.selection_mask = mask
		job.seed_cell = Vector3i.ZERO
		job.target_material = counting.get_material(Vector3i.ZERO)
		job.connected = true
		job.replacement_material = VoxelFrame.material(Color.BLUE)
		job.apply_changes = true
		job.run()
		expect(counting.has_calls > 0, "the selection kept the per-cell expansion")
		expect(job.matching_cells.size() == TOTAL, "the search found the block and its seed")
		expect(not job.applied_cells.has(Vector3i.ZERO), "the seed outside the selection is dropped")
		expect(job.applied_cells.size() == TOTAL - 1, "every other selected cell is kept")
		expect(counting.get_color(Vector3i.ZERO) == Color.RED, "the excluded seed stays unchanged")
		expect(counting.get_color(Vector3i(1, 0, 0)) == Color.BLUE, "a selected cell takes the fill material")
	)


# A nonzero axes keeps the expansion. A same-color mirror of a different full
# material must be rejected by the reflected occupancy and material test.
func _symmetry_keeps_filter() -> void:
	step("Given a block, an X mirror, and a same-color voxel of a different material", func():
		var counting := _counting_block(SIDE, SIDE, SIDE)
		var mirror_material := VoxelFrame.material(Color.RED, VoxelFrame.DEFAULT_EMISSION, 0.8, 0.5)
		counting.set_cell(Vector3i(-1, 0, 0), mirror_material)
		counting.has_calls = 0
		counting.matches_calls = 0
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3.ZERO
		var job: Variant = FILL_TOOL.FillJob.new()
		job.source_frame = counting
		job.edit_context = State.drawing_context()
		job.selection_mask = {}
		job.seed_cell = Vector3i.ZERO
		job.target_material = counting.get_material(Vector3i.ZERO)
		job.connected = true
		job.replacement_material = VoxelFrame.material(Color.BLUE)
		job.apply_changes = true
		job.run()
		expect(counting.has_calls > 0, "the symmetry kept the reflected occupancy check")
		expect(counting.matches_calls > 0, "the symmetry kept the reflected material check")
		expect(not job.applied_cells.has(Vector3i(-1, 0, 0)), "the same-color different-material mirror is rejected")
		expect(counting.get_material(Vector3i(-1, 0, 0)) == mirror_material, "the rejected mirror keeps its full material")
		expect(counting.get_color(Vector3i(0, 0, 0)) == Color.BLUE, "the block takes the fill material")
		State.symmetry_axes = 0
		State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	)


# A cancel must stop the job before any write, at the search entry and at the
# pre-write checkpoint that the identity path keeps.
func _cancel_before_write() -> void:
	step("Given a pre-cancelled fill job", func():
		_stream_fixture(SIDE, SIDE, SIDE)
		var job: Variant = FILL_TOOL.FillJob.new()
		job.source_frame = frame.copy_frame()
		job.edit_context = State.drawing_context()
		job.selection_mask = {}
		job.seed_cell = Vector3i.ZERO
		job.target_material = frame.get_material(Vector3i.ZERO)
		job.connected = true
		job.replacement_material = VoxelFrame.material(Color.BLUE)
		job.apply_changes = true
		job.cancel()
		job.run()
		expect(job.changed_chunks.is_empty(), "a cancelled fill reports no changed chunks")
		expect(job.source_frame.storage_data() == frame.storage_data(), "a cancelled fill writes nothing")
	)
	step("Given a fill job that cancels at the pre-write checkpoint", func():
		_stream_fixture(SIDE, SIDE, SIDE)
		var job: Variant = CancelOnApplyFillJob.new()
		job.source_frame = frame.copy_frame()
		job.edit_context = State.drawing_context()
		job.selection_mask = {}
		job.seed_cell = Vector3i.ZERO
		job.target_material = frame.get_material(Vector3i.ZERO)
		job.connected = true
		job.replacement_material = VoxelFrame.material(Color.BLUE)
		job.apply_changes = true
		job.run()
		expect(job.checkpoints >= 3, "the search progress checkpoint ran before the pre-write checkpoint")
		expect(job.changed_chunks.is_empty(), "the pre-write checkpoint refused the write")
		expect(job.source_frame.storage_data() == frame.storage_data(), "the refused write left the frame unchanged")
	)
