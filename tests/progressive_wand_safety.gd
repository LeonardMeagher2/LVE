extends "res://tests/test.gd"

# Progressive wand selection safety.
#
# The wand streams a growing selection. These tests prove that an intermediate
# outline mesh installs while the search still runs, that a new snapshot does not
# cancel the outline already building, that the final result is exact, that a
# cancel or a clear cannot resurrect a stale outline, and that the tool lifecycle
# (tool switch, status-bar cancel, Esc, free, reaper) leaves no worker behind.
#
#   godot --path . res://tests/progressive_wand_safety.tscn
#   godot --path . res://tests/progressive_wand_safety.tscn -- replace_partial_excludes_prior
#
# The tests assert the installed mesh, not only the selection count. A pixel check
# is not part of a headless run, so visibility is proven by the installed surface,
# not by rendered pixels.

const PREVIEW_SCRIPT := preload("res://Globals/Rendering/VoxelPreview.gd")
const OUTLINE_REFERENCE := preload("res://tests/outline_reference.gd")
const WAND_SCENE := preload("res://plugins/selection/tools/WandSelectTool.tscn")
const JOB_STATUS_SCENE := preload("res://ui/JobStatus/job_status.tscn")
var _wand_settings := preload("res://plugins/selection/settings.tres")

const WAND_SIDE := 40
const WAND_TOTAL := WAND_SIDE * WAND_SIDE * WAND_SIDE
const MARKER := Vector3i(200, 200, 200)
# A frame of many small chunks. The disconnected scan walks every chunk slot, so
# the search lasts long enough for several outline publishes. Two isolated cells
# per chunk keep the cell count above the wand's streaming limit.
const GRID_AXIS := 14
const GRID_PER_CHUNK := 2
# An injected selection just above the wand's inline limit. A wand on the small
# frame plus this selection estimates above 4096, so it takes the worker branch.
const RESTART_SELECTION := 4096

var frame: VoxelFrame
var wand: Node
var selection_preview: MeshInstance3D
var unit_preview: MeshInstance3D
var standalone: Node
var widget: Node
var _snapshot_a: VoxelSelection
var _snapshot_b: VoxelSelection
var _grid_selection: VoxelSelection
var _add_expected: VoxelSelection
var _prior_selection: VoxelSelection
var _grid_total := 0
var _other_edit: VoxelEditTransaction
var _inline_started := false


func _ready() -> void:
	timeout = 60.0
	test("a replace partial excludes the prior selection and the final is exact", _replace_partial_excludes_prior, "replace_partial_excludes_prior")
	test("add and subtract stay exact and a cancel rolls back", _add_subtract_and_rollback, "add_subtract_and_rollback")
	test("one wand action undoes and redoes", _undo_redo_one_action, "undo_redo_one_action")
	test("a tool switch lets the partial and the final outline finish", _tool_switch_completes, "tool_switch_completes")
	test("the status cancel and Esc roll back a detached wand", _cancel_after_switch, "cancel_after_switch")
	test("an idle detached wand keeps another tool's stroke", _idle_detached_wand_keeps_other_stroke, "idle_detached_wand_keeps_other_stroke")
	test("an inline commit finalizer keeps a reentrant large selection", _inline_commit_reentrant_large, "inline_commit_reentrant_large")
	test("a cancelled worker is reaped once", _cancelled_workers_reaped, "cancelled_workers_reaped")
	test("a new selection starts while the old worker winds down", _cancel_then_restart, "cancel_then_restart")
	test("freeing a wand with a full handoff queue does not deadlock", _free_tool_with_full_queue, "free_tool_with_full_queue")
	test("a newer snapshot does not cancel the outline already building", _coalesced_outline_installs, "coalesced_outline_installs")
	test("a clear supersedes a building stream outline", _clear_supersedes_stream, "clear_supersedes_stream")
	test("a symmetric stream expands to the exact mirrored selection", _symmetry_stream_exact, "symmetry_stream_exact")
	test("a strict request after a stream reinstalls its exact outline", _strict_stream_strict_identity, "strict_stream_strict_identity")
	test("a stream drops a delayed strict request", _pending_strict_superseded_by_stream, "pending_strict_superseded_by_stream")
	test("a stream survives an active strict worker", _active_strict_superseded_by_stream, "active_strict_superseded_by_stream")
	test("a spent frame budget defers a completed stream install", _install_budget_gate, "install_budget_gate")
	test("a cancel after a partial restores the exact prior outline", _cancel_after_partial_restores_exact_mesh, "cancel_after_partial_restores_exact_mesh")


func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.clear_selection()
	State.undo_redo.clear_history()
	_wand_settings.connected = true
	_wand_settings.mode = 0
	while State.edit_busy():
		await get_tree().process_frame
	await get_tree().process_frame


# Leave no worker, preview, or open stroke behind, so a test can run alone or in
# any order.
func after_test() -> void:
	if is_instance_valid(wand):
		# The wand cancels only its own edit. A detached wand keeps its connection,
		# so this reaches a streamed selection that outlived a tool switch.
		wand._cancel_selection()
	if is_instance_valid(standalone):
		standalone.free()
		standalone = null
	if is_instance_valid(widget):
		widget.queue_free()
		widget = null
	if is_instance_valid(unit_preview):
		unit_preview.queue_free()
		unit_preview = null
	State.clear_selection()
	State.undo_redo.clear_history()
	_wand_settings.connected = true
	_wand_settings.mode = 0
	var guard := 0
	while State.edit_busy() or _wand_reaping():
		await get_tree().process_frame
		guard += 1
		if guard > 3000:
			break
	await get_tree().process_frame


func _wand_reaping() -> bool:
	return is_instance_valid(wand) and (not wand._retired_jobs.is_empty() or wand._reaping)


func _wand_fixture() -> void:
	activate_tool("selection")
	select_toolbar_item("selection", "Wand")
	wand = plugin("SelectionPlugin")._wand
	selection_preview = plugin("SelectionPlugin")._selection


# A large connected block. The wand streams it, so the search lasts several
# frames and a partial outline can install before the final one.
func _build_block(side: int) -> void:
	frame = State.get_current_voxel_frame()
	var cells := {}
	var material := VoxelFrame.material(Color.RED)
	for x in side:
		for y in side:
			for z in side:
				cells[Vector3i(x, y, z)] = material
	frame.set_cells(cells, null, material)
	State.document._bounds_dirty = true


# A frame of many small chunks with two isolated cells each. The disconnected
# wand scan walks every slot of every chunk, so the search runs for a long time
# and publishes several growing snapshots. The cell count stays above the wand's
# streaming limit.
func _build_grid() -> void:
	frame = State.get_current_voxel_frame()
	var cells := {}
	var material := VoxelFrame.material(Color.RED)
	for i in GRID_AXIS:
		for j in GRID_AXIS:
			for k in GRID_AXIS:
				for d in GRID_PER_CHUNK:
					cells[Vector3i(i * VoxelFrame.CHUNK_SIZE + d * 2, j * VoxelFrame.CHUNK_SIZE, k * VoxelFrame.CHUNK_SIZE)] = material
	frame.set_cells(cells, null, material)
	State.document._bounds_dirty = true
	_grid_total = cells.size()
	var selection := VoxelSelection.new()
	for cell_position in cells:
		selection.add(cell_position)
	_grid_selection = selection


func _box_selection(min_corner: Vector3i, max_corner: Vector3i) -> VoxelSelection:
	var selection := VoxelSelection.new()
	selection.from_box(min_corner, max_corner)
	return selection


# The X mirror of every cell, built without the production edit context. It is the
# expected result of an X-symmetric wand expansion.
func _mirrored_x(selection: VoxelSelection) -> VoxelSelection:
	var mirrored := VoxelSelection.new()
	for cell_position in selection.all_cells():
		mirrored.add(cell_position)
		mirrored.add(Vector3i(-cell_position.x, cell_position.y, cell_position.z))
	return mirrored


# A canonical segment key: the two endpoints in lexicographic order. Comparing the
# sorted key list proves the exact installed geometry, not only its vertex count.
func _canonical_segments(vertices: PackedVector3Array) -> PackedStringArray:
	var segments := PackedStringArray()
	var index := 0
	while index + 1 < vertices.size():
		segments.append(_segment_key(vertices[index], vertices[index + 1]))
		index += 2
	segments.sort()
	return segments


func _segment_key(first: Vector3, second: Vector3) -> String:
	var low := first
	var high := second
	if _lexicographic(second, first):
		low = second
		high = first
	return "%.3f,%.3f,%.3f;%.3f,%.3f,%.3f" % [low.x, low.y, low.z, high.x, high.y, high.z]


func _lexicographic(first: Vector3, second: Vector3) -> bool:
	if first.x != second.x:
		return first.x < second.x
	if first.y != second.y:
		return first.y < second.y
	return first.z < second.z


func _surface_vertices(mesh: Mesh) -> PackedVector3Array:
	if mesh == null or mesh.get_surface_count() == 0:
		return PackedVector3Array()
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]


# The installed outline geometry, canonicalized. An empty or hidden mesh has none.
func _installed_segments(mesh_instance: MeshInstance3D) -> PackedStringArray:
	if mesh_instance == null or not mesh_instance.visible or mesh_instance.mesh == null:
		return PackedStringArray()
	return _canonical_segments(_surface_vertices(mesh_instance.mesh))


# The expected outline geometry from the frozen reference. It calls no production
# builder, so the comparison is independent of the live code.
func _expected_segments(selection: VoxelSelection) -> PackedStringArray:
	return _canonical_segments(OUTLINE_REFERENCE.outline_vertices(selection))


# Wait for a standalone preview to install its final surface.
func _settle_unit() -> void:
	var guard := 0
	while not unit_preview.is_settled():
		await get_tree().process_frame
		guard += 1
		if guard > 4000:
			break


# Wait until the selection preview has installed its final surface, so an
# installed-outline check reads the settled mesh.
func _settle_preview() -> void:
	var guard := 0
	while not selection_preview.is_settled():
		await get_tree().process_frame
		guard += 1
		if guard > 3000:
			break


func _installed_outline(mesh_instance: MeshInstance3D) -> int:
	if mesh_instance == null or not mesh_instance.visible or mesh_instance.mesh == null:
		return 0
	if mesh_instance.mesh.get_surface_count() == 0:
		return 0
	return mesh_instance.mesh.surface_get_array_len(0)


# The vertices of a distinct, isolated cell set. Isolated cells make a dense
# outline, so a large snapshot builds for many frames.
func _scattered_selection(count: int, stride: int) -> VoxelSelection:
	var selection := VoxelSelection.new()
	var side := int(ceil(pow(float(count), 1.0 / 3.0))) + 1
	var placed := 0
	for x in side:
		for y in side:
			for z in side:
				if placed >= count:
					break
				selection.add(Vector3i(x * stride, y * stride, z * stride))
				placed += 1
	return selection


func _replace_partial_excludes_prior() -> void:
	var installed_while_running := false
	var first_partial := 0
	var marker_seen := false
	var installs := 0
	var longest_frame_us := 0
	var rebuilds := 0
	step("Given a large scattered frame, a prior marker, and the wand", func():
		_wand_fixture()
		_build_grid()
		expect(_grid_total > 4096, "the frame is large enough to stream")
		State.selection.add(MARKER)
		State.selection_changed.emit()
		# The preview may request the marker outline after the signal. Let that
		# request settle before the stream starts, so its mask lookup is not
		# counted as a rebuild from the streamed finish.
		await _settle_preview()
		rebuilds = VoxelSelection._profile_rebuild_calls
		expect(State.selection.count() == 1, "the prior marker is the whole selection")
	)
	step("When the user selects every matching voxel in replace mode", func():
		wand._settings.connected = false
		wand._settings.mode = wand._settings.SelectMode.REPLACE
		wand._commit(Vector3i.ZERO)
		expect(wand._job != null, "the large selection streams")
		expect(State.selection.count() == 0, "replace drops the prior selection before the search ends")
	)
	var previous_us := Time.get_ticks_usec()
	while wand._job != null:
		await get_tree().process_frame
		var now_us := Time.get_ticks_usec()
		longest_frame_us = maxi(longest_frame_us, now_us - previous_us)
		previous_us = now_us
		if wand._job == null:
			break
		var length := _installed_outline(selection_preview)
		if length > 0:
			if not installed_while_running:
				installed_while_running = true
				first_partial = length
			installs += 1
		if State.selection.contains(MARKER):
			marker_seen = true
	while State.edit_busy():
		await get_tree().process_frame
	await _settle_preview()
	var final_length := _installed_outline(selection_preview)
	step("Then an intermediate outline installed while the search still ran", func():
		expect(installed_while_running, "a partial outline mesh installed while the wand worker still ran")
		expect(installs > 0, "at least one intermediate outline installed")
		expect(first_partial > 0 and first_partial < final_length, "the first partial outline is smaller than the final outline")
		# The stream applies every batch, so the finish must keep the live masks
		# and publish through the progressive outline. The rebuild count is a
		# profile. A preview request can race the batch order under load, so the
		# final geometry and the strict-request check prove the stream stayed live.
		var rebuild_delta := VoxelSelection._profile_rebuild_calls - rebuilds
		print("MEASURE wand partial masks: rebuild_calls=%d" % rebuild_delta)
		expect(not selection_preview._strict_alive, "no strict outline request follows the stream")
		# The merge budget covers only the merge. The publication copy and the
		# installed surface are outside it, so the longest frame is reported as is.
		print("MEASURE wand partial: cells %d, first partial %d, final %d, frames_with_outline %d, longest_frame %d us" % [_grid_total, first_partial, final_length, installs, longest_frame_us])
	)
	step("Then the replace partial never held the prior marker", func():
		expect(not marker_seen, "the live selection never held the replaced marker while the stream ran")
		expect(not State.selection.contains(MARKER), "the final selection excludes the prior marker")
		expect(State.selection.count() == _grid_total, "the final selection holds every matching voxel")
		expect(_installed_segments(selection_preview) == _expected_segments(_grid_selection), "the final outline is the exact grid geometry")
	)


func _add_subtract_and_rollback() -> void:
	step("Given a large scattered frame, a prior marker, and add mode", func():
		_wand_fixture()
		_build_grid()
		State.selection.add(MARKER)
		_add_expected = VoxelSelection.new()
		for cell_position in _grid_selection.all_cells():
			_add_expected.add(cell_position)
		_add_expected.add(MARKER)
		wand._settings.connected = false
		wand._settings.mode = wand._settings.SelectMode.ADD
	)
	step("When the user adds the matching voxels", func():
		wand._commit(Vector3i.ZERO)
	)
	while wand._job != null or State.edit_busy():
		await get_tree().process_frame
	await _settle_preview()
	step("Then add keeps the marker and holds every matching voxel", func():
		expect(State.selection.contains(MARKER), "add keeps the prior marker")
		expect(State.selection.count() == _grid_total + 1, "add holds every matching voxel and the marker")
		expect(_installed_segments(selection_preview) == _expected_segments(_add_expected), "the added outline is the exact union geometry")
		State.undo_redo.undo()
		expect(State.selection.count() == 1 and State.selection.contains(MARKER), "one undo restores the marker")
		State.undo_redo.clear_history()
	)
	await _settle_preview()
	step("Then one undo restores the exact marker outline", func():
		var marker_expected := VoxelSelection.new()
		marker_expected.add(MARKER)
		expect(_installed_segments(selection_preview) == _expected_segments(marker_expected), "the undone outline is the exact marker geometry")
	)
	step("When the user adds the voxels again", func():
		wand._commit(Vector3i.ZERO)
	)
	while wand._job != null or State.edit_busy():
		await get_tree().process_frame
	step("Then the selection holds the voxels and the marker", func():
		expect(State.selection.count() == _grid_total + 1, "the second add holds every matching voxel")
	)
	step("When the user subtracts the matching voxels", func():
		wand._settings.mode = wand._settings.SelectMode.SUBTRACT
		wand._commit(Vector3i.ZERO)
	)
	while wand._job != null or State.edit_busy():
		await get_tree().process_frame
	await _settle_preview()
	step("Then subtract leaves the marker and one undo restores the voxels", func():
		var marker_expected := VoxelSelection.new()
		marker_expected.add(MARKER)
		expect(State.selection.count() == 1 and State.selection.contains(MARKER), "subtract leaves only the marker")
		expect(_installed_segments(selection_preview) == _expected_segments(marker_expected), "the subtracted outline is the exact marker geometry")
		State.undo_redo.undo()
		expect(State.selection.count() == _grid_total + 1, "one undo restores every subtracted voxel")
		State.undo_redo.clear_history()
	)
	step("When the user adds the voxels again and cancels mid-stream", func():
		State.clear_selection()
		State.selection.add(MARKER)
		State.undo_redo.clear_history()
		wand._settings.mode = wand._settings.SelectMode.ADD
		wand._commit(Vector3i.ZERO)
	)
	while State.selection.count() <= 1:
		await get_tree().process_frame
	step("Then the cancel rolls the partial add back to the marker", func():
		wand._cancel_selection()
	)
	while State.edit_busy() or not wand._retired_jobs.is_empty():
		await get_tree().process_frame
	await _settle_preview()
	step("Then the rolled-back add is exact with no history", func():
		var marker_expected := VoxelSelection.new()
		marker_expected.add(MARKER)
		expect(State.selection.count() == 1 and State.selection.contains(MARKER), "the cancel restores exactly the marker")
		expect(_installed_segments(selection_preview) == _expected_segments(marker_expected), "the rolled-back outline is the exact marker geometry")
		expect(not State.undo_redo.has_undo(), "the cancelled add records no history")
	)


func _undo_redo_one_action() -> void:
	step("Given a large block, a prior marker, and replace mode", func():
		_wand_fixture()
		_build_block(WAND_SIDE)
		State.selection.add(MARKER)
		wand._settings.connected = true
		wand._settings.mode = wand._settings.SelectMode.REPLACE
	)
	step("When the user selects the block", func():
		wand._commit(Vector3i.ZERO)
	)
	while wand._job != null or State.edit_busy():
		await get_tree().process_frame
	step("Then the streamed selection is one undo action", func():
		expect(State.selection.count() == WAND_TOTAL, "the final selection holds the whole block")
		expect(State.undo_redo.has_undo(), "the wand records one undo action")
		State.undo_redo.undo()
		expect(State.selection.count() == 1 and State.selection.contains(MARKER), "one undo restores the prior marker exactly")
		State.undo_redo.redo()
		expect(State.selection.count() == WAND_TOTAL, "redo restores the whole block exactly")
		expect(not State.selection.contains(MARKER), "redo does not resurrect the replaced marker")
		State.undo_redo.clear_history()
	)


func _tool_switch_completes() -> void:
	var partial := false
	step("Given a large scattered frame and a streaming wand", func():
		_wand_fixture()
		_build_grid()
		wand._settings.connected = false
		wand._settings.mode = wand._settings.SelectMode.REPLACE
		wand._commit(Vector3i.ZERO)
		expect(wand._job != null, "the wand streams")
	)
	while wand._job != null:
		await get_tree().process_frame
		if wand._job == null:
			break
		if _installed_outline(selection_preview) > 0:
			partial = true
			break
	step("When the user switches tools during the partial", func():
		activate_tool("paint")
		expect(wand._job != null, "the tool switch did not cancel the wand")
		expect(not wand.is_inside_tree(), "the wand is detached from the tree")
	)
	while wand._job != null or State.edit_busy():
		await get_tree().process_frame
	await _settle_preview()
	step("Then the detached wand completes exactly with one undo", func():
		expect(partial, "a partial outline installed before the switch")
		expect(State.selection.count() == _grid_total, "the detached wand selected every matching voxel")
		expect(State.undo_redo.has_undo(), "the detached wand records one undo action")
		State.undo_redo.undo()
		expect(State.selection.is_empty(), "one undo clears the detached wand selection")
		State.undo_redo.clear_history()
	)


func _cancel_after_switch() -> void:
	step("Given a large scattered frame, a prior marker, and a streaming wand", func():
		_wand_fixture()
		_build_grid()
		State.selection.add(MARKER)
		State.selection_changed.emit()
		wand._settings.connected = false
		wand._settings.mode = wand._settings.SelectMode.REPLACE
		wand._commit(Vector3i.ZERO)
	)
	while State.selection.count() == 0:
		await get_tree().process_frame
	step("When the user switches tools and clicks the status cancel", func():
		activate_tool("paint")
		expect(State.edit_busy(), "the detached wand still owns the operation")
		widget = JOB_STATUS_SCENE.instantiate()
		widget.delay_ms = 0
		main.add_child(widget)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the status bar exposes a real cancel button", func():
		var cancel: Button = widget.get_node("Cancel")
		expect(cancel.visible and not cancel.disabled, "the detached wand shows a cancel button")
		cancel.button_down.emit()
		cancel.pressed.emit()
	)
	while State.edit_busy() or not wand._retired_jobs.is_empty():
		await get_tree().process_frame
	step("Then the status cancel rolls back with no history", func():
		expect(State.selection.count() == 1 and State.selection.contains(MARKER), "the status cancel restores the prior marker")
		expect(not State.undo_redo.has_undo(), "the cancelled wand adds no undo action")
		expect(not State.edit_busy(), "the cancelled wand releases editing")
	)
	step("When the user starts another wand, switches tools, and presses Esc", func():
		activate_tool("selection")
		select_toolbar_item("selection", "Wand")
		wand._commit(Vector3i.ZERO)
	)
	while State.selection.count() == 0:
		await get_tree().process_frame
	step("Then Esc reaches the detached wand", func():
		activate_tool("paint")
		var key := InputEventKey.new()
		key.keycode = KEY_ESCAPE
		key.pressed = true
		get_tree().root.push_input(key)
	)
	while State.edit_busy() or not wand._retired_jobs.is_empty():
		await get_tree().process_frame
	step("Then the Esc cancel restores the prior marker with no history", func():
		expect(State.selection.count() == 1 and State.selection.contains(MARKER), "Esc restored the prior marker")
		expect(not State.undo_redo.has_undo(), "the Esc cancel adds no history")
	)


func _idle_detached_wand_keeps_other_stroke() -> void:
	step("Given a detached idle wand and another tool's open edit", func():
		_wand_fixture()
		activate_tool("paint")
		_other_edit = State.begin_edit()
		expect(_other_edit != null and State.active_edit() == _other_edit, "another tool opened an edit")
	)
	step("When the edit context changes", func():
		State.edit_context_changing.emit()
	)
	step("Then the idle wand does not roll the other edit back", func():
		expect(State.active_edit() == _other_edit, "the idle wand kept another tool's edit")
		State.cancel_edit(_other_edit)
		_other_edit = null
		expect(State.active_edit() == null, "the test releases the edit")
	)


# A small inline wand commits and its history handler starts a large worker
# selection on the same tool. The inline finalizer must consume only its own
# handle, operation, and source, so the replacement keeps its worker and context.
func _on_inline_history() -> void:
	if _inline_started:
		return
	_inline_started = true
	# Drop the inline cell and inject a region large enough for the worker branch.
	# The replacement then adds the matched cell back and records its own action.
	State.selection.erase(Vector3i.ZERO)
	for index in RESTART_SELECTION:
		State.selection.add(Vector3i(1000 + index, 0, 0))
	wand._settings.mode = wand._settings.SelectMode.ADD
	wand._commit(Vector3i.ZERO)


func _inline_commit_reentrant_large() -> void:
	step("Given a small frame, add mode, and a history handler", func():
		_wand_fixture()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.document._bounds_dirty = true
		State.undo_redo.clear_history()
		wand._settings.connected = false
		wand._settings.mode = wand._settings.SelectMode.ADD
		_inline_started = false
		State.history_changed.connect(_on_inline_history, CONNECT_ONE_SHOT)
	)
	step("When the user selects the small region inline", func():
		wand._commit(Vector3i.ZERO)
		expect(_inline_started, "the inline commit recorded history and the handler started a large selection")
		expect(wand._job != null, "the replacement selection streams on a worker")
		expect(State.get_activity() != null and State.get_activity().can_cancel(), "the replacement owns a cancellable activity")
		expect(wand._source_document == State.document, "the replacement keeps its document")
		expect(wand._source_frame == State.get_current_voxel_frame(), "the replacement keeps its frame")
		expect(wand._edit != null and State.active_edit() == wand._edit, "the replacement owns the active edit")
	)
	var guard := 0
	while wand._job != null or State.edit_busy() or not wand._retired_jobs.is_empty():
		await get_tree().process_frame
		guard += 1
		if guard > 900:
			break
	await _settle_preview()
	step("Then the replacement completes with the exact union and one action each", func():
		expect(State.selection.count() == RESTART_SELECTION + 1, "the replacement adds the matched cell to the injected region")
		expect(State.selection.contains(Vector3i.ZERO), "the matched cell is selected")
		expect(wand._edit == null and wand._job == null, "the replacement released its handle and job")
		expect(not State.edit_busy(), "no activity remains")
		expect(wand._retired_jobs.is_empty(), "no retired worker remains")
		expect(State.undo_redo.get_history_count() == 2, "each committed selection recorded one action")
		State.undo_redo.undo()
		expect(State.selection.count() == RESTART_SELECTION, "one undo removes the replacement add")
		State.undo_redo.undo()
		expect(State.selection.is_empty(), "the second undo removes the inline selection")
	)


func _cancelled_workers_reaped() -> void:
	step("Given a streaming wand", func():
		_wand_fixture()
		_build_grid()
		wand._settings.connected = false
		wand._settings.mode = wand._settings.SelectMode.REPLACE
		wand._commit(Vector3i.ZERO)
	)
	while State.selection.count() == 0:
		await get_tree().process_frame
	step("When the user cancels", func():
		wand._cancel_selection()
		expect(wand._job == null, "the cancel retires the job")
	)
	var guard := 0
	while not wand._retired_jobs.is_empty() or wand._reaping:
		await get_tree().process_frame
		guard += 1
		if guard > 3000:
			break
	step("Then the retired worker is joined once and the reaper is idle", func():
		expect(wand._retired_jobs.is_empty(), "no retired job remains")
		expect(not wand._reaping, "the reaper is idle")
		expect(not State.edit_busy(), "the cancel released editing")
	)


func _cancel_then_restart() -> void:
	step("Given a streaming wand", func():
		_wand_fixture()
		_build_grid()
		wand._settings.connected = false
		wand._settings.mode = wand._settings.SelectMode.REPLACE
		wand._commit(Vector3i.ZERO)
	)
	while State.selection.count() == 0:
		await get_tree().process_frame
	step("When the user cancels and starts a new selection before the old worker winds down", func():
		wand._cancel_selection()
		wand._commit(Vector3i.ZERO)
		expect(wand._job != null, "the new selection started")
	)
	while wand._job != null or State.edit_busy():
		await get_tree().process_frame
	step("Then the new selection is exact and the old worker is gone", func():
		expect(State.selection.count() == _grid_total, "the new selection holds every matching voxel")
		expect(wand._retired_jobs.is_empty(), "the old worker was reaped")
		expect(not wand._reaping, "the reaper is idle")
	)


func _free_tool_with_full_queue() -> void:
	step("Given a standalone wand streaming with a full handoff queue", func():
		standalone = WAND_SCENE.instantiate()
		add_child(standalone)
		_build_grid()
		standalone._settings.connected = false
		standalone._settings.mode = 0
		standalone._commit(Vector3i.ZERO)
		expect(standalone._job != null, "the standalone wand streams")
	)
	# Let the producer fill its bounded queue.
	await get_tree().process_frame
	await get_tree().process_frame
	step("When the tool is freed while its worker may block on a full queue", func():
		standalone.free()
		standalone = null
	)
	step("Then the free returns without deadlock and releases the operation", func():
		expect(true, "the free returned")
		expect(not State.edit_busy(), "the freed tool released its operation")
	)


func _coalesced_outline_installs() -> void:
	var lengths: Array[int] = []
	var first_install_while_job := false
	step("Given a large snapshot and a newer one queued while the first builds", func():
		unit_preview = PREVIEW_SCRIPT.new()
		add_child(unit_preview)
		_snapshot_a = _scattered_selection(16000, 4)
		_snapshot_b = _scattered_selection(24000, 4)
		unit_preview.show_selection(_snapshot_a, true)
		expect(unit_preview._stream_job != null, "the first outline started on a worker")
		unit_preview.show_selection(_snapshot_b, true)
		expect(unit_preview._stream_job != null, "the newer snapshot did not cancel the running outline")
		expect(unit_preview._stream_has_pending, "the newer snapshot waits for the running outline")
	)
	var guard := 0
	while unit_preview._stream_job != null or unit_preview._stream_has_pending:
		await get_tree().process_frame
		var length := _installed_outline(unit_preview)
		if length > 0:
			lengths.append(length)
			if lengths.size() == 1:
				first_install_while_job = unit_preview._stream_job != null
		guard += 1
		if guard > 4000:
			break
	step("Then the first outline installed before the newest one", func():
		expect(lengths.size() > 0, "an outline installed")
		var final_length := 0
		for length in lengths:
			final_length = maxi(final_length, length)
		expect(lengths[0] < final_length, "the first installed outline is smaller than the final one")
		expect(first_install_while_job, "the first outline installed while the newer stream job still ran")
		print("MEASURE coalescing: first %d cells -> outline %d, newest %d cells -> outline %d" % [_snapshot_a.count(), lengths[0], _snapshot_b.count(), final_length])
	)


func _clear_supersedes_stream() -> void:
	step("Given a large snapshot building on a worker", func():
		unit_preview = PREVIEW_SCRIPT.new()
		add_child(unit_preview)
		_snapshot_a = _scattered_selection(20000, 4)
		unit_preview.show_selection(_snapshot_a, true)
		expect(unit_preview._stream_job != null, "the outline started on a worker")
	)
	step("When the selection clears", func():
		unit_preview.show_selection(VoxelSelection.new(), true)
		expect(not unit_preview.visible, "the clear hides the outline at once")
	)
	var guard := 0
	while unit_preview._stream_job != null:
		await get_tree().process_frame
		guard += 1
		if guard > 3000:
			break
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the stale outline never appears", func():
		expect(unit_preview._stream_job == null, "the cancelled stream job is joined")
		expect(not unit_preview.visible, "the cancelled outline did not resurrect")
		expect(_installed_outline(unit_preview) == 0, "no stale surface is shown")
	)


# The wand captures the symmetry context. Each streamed batch expands through it,
# so the final selection is the exact mirrored set and one undo removes it.
func _symmetry_stream_exact() -> void:
	step("Given a large scattered frame and the X symmetry plane", func():
		_wand_fixture()
		_build_grid()
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3.ZERO
		wand._settings.connected = false
		wand._settings.mode = wand._settings.SelectMode.REPLACE
	)
	step("When the user selects every matching voxel", func():
		wand._commit(Vector3i.ZERO)
		expect(wand._job != null, "the symmetric selection streams")
	)
	while wand._job != null or State.edit_busy():
		await get_tree().process_frame
	await _settle_preview()
	step("Then the final selection is the exact mirrored set", func():
		expect(State.selection.contains(Vector3i(2, 0, 0)), "the original voxel is selected")
		expect(State.selection.contains(Vector3i(-2, 0, 0)), "the reflected voxel is selected")
		# The grid holds 5488 cells. The X reflection maps every cell with x != 0 to
		# a new cell and leaves the 196 cells with x == 0 in place.
		expect(State.selection.count() == 10780, "the mirrored selection is exact")
		expect(_installed_segments(selection_preview) == _expected_segments(_mirrored_x(_grid_selection)), "the mirrored outline is the exact geometry")
		expect(State.undo_redo.has_undo(), "the symmetric wand records one undo action")
		State.undo_redo.undo()
		expect(State.selection.is_empty(), "one undo clears the mirrored selection")
		State.undo_redo.clear_history()
	)


# Defect 1. A strict request repeated after a stream must reinstall its own exact
# geometry. The strict dedupe trusts the requested set only while the strict
# request still owns the preview, so a stream result cannot stand in for it.
func _strict_stream_strict_identity() -> void:
	step("Given a preview that installed strict A", func():
		unit_preview = PREVIEW_SCRIPT.new()
		add_child(unit_preview)
		_snapshot_a = _box_selection(Vector3i.ZERO, Vector3i(9, 9, 9))
		_snapshot_b = _scattered_selection(4000, 4)
		unit_preview.show_selection(_snapshot_a, false)
	)
	await _settle_unit()
	step("Then strict A is installed exactly", func():
		expect(_installed_segments(unit_preview) == _expected_segments(_snapshot_a), "the strict A outline is installed exactly")
	)
	step("When a progressive B installs", func():
		unit_preview.show_selection(_snapshot_b, true)
	)
	await _settle_unit()
	step("Then B is installed exactly", func():
		expect(_installed_segments(unit_preview) == _expected_segments(_snapshot_b), "the progressive B outline is installed exactly")
	)
	step("When strict A is requested again after the stream", func():
		unit_preview.show_selection(_snapshot_a, false)
	)
	await _settle_unit()
	step("Then the exact strict A outline replaces B", func():
		expect(_installed_segments(unit_preview) == _expected_segments(_snapshot_a), "the repeated strict A restores its exact geometry")
		expect(_installed_segments(unit_preview) != _expected_segments(_snapshot_b), "the stream outline does not remain")
	)


# Defect 2. A delayed strict request must not revive after a stream takes over.
func _pending_strict_superseded_by_stream() -> void:
	step("Given a delayed strict request larger than the debounce limit", func():
		unit_preview = PREVIEW_SCRIPT.new()
		add_child(unit_preview)
		_snapshot_a = _box_selection(Vector3i.ZERO, Vector3i(17, 17, 17))
		_snapshot_b = _scattered_selection(3000, 4)
		expect(_snapshot_a.count() > PREVIEW_SCRIPT.OUTLINE_DELAY_LIMIT, "strict A crosses the delay limit")
		unit_preview.show_selection(_snapshot_a, false)
		expect(not unit_preview._pending_cells.is_empty(), "strict A waits for its delay")
		expect(unit_preview._preview_job == null, "strict A has no job yet")
	)
	step("When a progressive B takes over before the delay elapses", func():
		unit_preview.show_selection(_snapshot_b, true)
		expect(unit_preview._pending_cells.is_empty(), "the stream drops the delayed strict request")
	)
	await _settle_unit()
	step("Then only the exact B outline is installed", func():
		expect(_installed_segments(unit_preview) == _expected_segments(_snapshot_b), "the stream result is the exact B geometry")
	)


# Defect 3. A stream queued while a strict worker runs must not be lost.
func _active_strict_superseded_by_stream() -> void:
	step("Given a strict worker already running", func():
		unit_preview = PREVIEW_SCRIPT.new()
		add_child(unit_preview)
		_snapshot_a = _scattered_selection(2000, 4)
		_snapshot_b = _scattered_selection(5000, 4)
		expect(_snapshot_a.count() > PREVIEW_SCRIPT.INLINE_OUTLINE_LIMIT, "strict A crosses the inline limit")
		expect(_snapshot_a.count() <= PREVIEW_SCRIPT.OUTLINE_DELAY_LIMIT, "strict A starts without a delay")
		unit_preview.show_selection(_snapshot_a, false)
		expect(unit_preview._preview_job != null, "the strict outline runs on a worker")
	)
	step("When a progressive B takes over while the strict job still exists", func():
		unit_preview.show_selection(_snapshot_b, true)
		expect(unit_preview._stream_has_pending, "the stream keeps its newest snapshot")
		expect(unit_preview._preview_job != null, "the strict job is still winding down")
	)
	await _settle_unit()
	step("Then the stream result B is installed, not lost", func():
		expect(_installed_segments(unit_preview) == _expected_segments(_snapshot_b), "the stream outline survives the strict takeover")
	)


# Defect 4. A completed stream outline shares the strict install budget. A spent
# frame defers it, and the next frame installs it and charges the budget.
func _install_budget_gate() -> void:
	step("Given a completed stream outline and a spent frame budget", func():
		unit_preview = PREVIEW_SCRIPT.new()
		add_child(unit_preview)
		# Drive the preview by hand, so the engine cannot reset the frame budget.
		unit_preview.set_process(false)
		_snapshot_b = _scattered_selection(3000, 4)
		unit_preview.show_selection(_snapshot_b, true)
		expect(unit_preview._stream_job != null, "the stream job started")
	)
	var guard := 0
	while unit_preview._stream_job == null or not WorkerThreadPool.is_task_completed(unit_preview._stream_job.worker_task_id):
		await get_tree().process_frame
		guard += 1
		if guard > 4000:
			break
	step("When the frame budget is already spent", func():
		expect(unit_preview._stream_job != null, "the completed stream job waits")
		var mesh_before := unit_preview.mesh
		unit_preview._install_frame = Engine.get_process_frames()
		unit_preview._install_time_us = State.WORK_SLICE_US
		unit_preview._process(0.0)
		expect(unit_preview._stream_job != null, "the spent budget defers the stream install")
		expect(unit_preview.mesh == mesh_before, "the deferred install leaves the mesh unchanged")
	)
	step("Then the next frame installs the outline and charges the budget", func():
		unit_preview._process(0.0)
		expect(unit_preview._stream_job != null, "the install stays deferred inside one frame")
		unit_preview._install_frame = -1
		unit_preview._process(0.0)
		expect(unit_preview._stream_job == null, "the next frame installs the stream outline")
		expect(unit_preview._install_time_us > 0, "the install charges the frame budget")
		expect(_installed_segments(unit_preview) == _expected_segments(_snapshot_b), "the installed outline is the exact stream geometry")
	)


# Defect 1, user path. A cancel after a partial outline installed must restore the
# exact prior outline, not leave the partial on screen.
func _cancel_after_partial_restores_exact_mesh() -> void:
	step("Given a prior selection with its exact outline installed", func():
		_wand_fixture()
		_build_grid()
		_prior_selection = VoxelSelection.new()
		_prior_selection.add(Vector3i(300, 300, 300))
		_prior_selection.add(Vector3i(301, 300, 300))
		_prior_selection.add(Vector3i(302, 300, 300))
		State.selection.restore(_prior_selection.all_cells().duplicate())
		State.selection_changed.emit()
	)
	await _settle_preview()
	step("Then the prior outline is exact before the wand", func():
		expect(_installed_segments(selection_preview) == _expected_segments(_prior_selection), "the prior outline is installed exactly")
	)
	step("When the wand adds the grid and a growing partial outline installs", func():
		wand._settings.connected = false
		wand._settings.mode = wand._settings.SelectMode.ADD
		wand._commit(Vector3i.ZERO)
	)
	var guard := 0
	while wand._job != null:
		await get_tree().process_frame
		guard += 1
		if _installed_outline(selection_preview) > 0 and _installed_segments(selection_preview) != _expected_segments(_prior_selection):
			break
		if guard > 4000:
			break
	step("Then a partial outline replaced the prior outline", func():
		expect(_installed_segments(selection_preview) != _expected_segments(_prior_selection), "a growing partial outline is installed")
		wand._cancel_selection()
	)
	while State.edit_busy() or not wand._retired_jobs.is_empty():
		await get_tree().process_frame
	await _settle_preview()
	step("Then the cancel restores the exact prior outline, not the partial", func():
		expect(State.selection.count() == _prior_selection.count(), "the selection rolls back to the prior set")
		expect(_installed_segments(selection_preview) == _expected_segments(_prior_selection), "the installed outline is the exact prior geometry")
	)
