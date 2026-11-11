extends "res://tests/test.gd"

# The owned edit transaction. These tests prove the contract: one edit at a time,
# an identity-checked commit and cancel, a frozen context, and a clean release on
# a document reset.
#
#   godot --path . res://tests/edit_transaction.tscn
#   godot --path . res://tests/edit_transaction.tscn -- noop

var _brush_settings := preload("res://plugins/brush/settings.tres")
const BRUSH_SCENE := preload("res://plugins/brush/BrushTool.tscn")
const MOVE_SCENE := preload("res://plugins/Transform/tools/MoveTool.tscn")

var viewport: SubViewport
var edit: VoxelEditTransaction
var second: VoxelEditTransaction
var released: WeakRef
var tool: Node
var transform_tool: Node
var committed: VoxelEditTransaction
var reentrant: VoxelEditTransaction
var old_context: VoxelFrame.EditContext
var refs: Array[WeakRef] = []
var before_data := PackedByteArray()
var before_count := 0
var scope: VoxelFrame.EditContext
var _default_color := Color.BLACK
var _default_mode := BrushToolSettings.BrushMode.PENCIL
var _defaults_ready := false


func _ready() -> void:
	timeout = 30.0
	test("a no-op edit records no history", _noop, "noop")
	test("a selection-only change records one undo", _selection_only, "selection_only")
	test("undo and redo install the selection masks and keep them frozen", _selection_masks, "selection_masks")
	test("an edit keeps the full material of a changed cell", _changed_material, "changed_material")
	test("a cancel restores the frame bounds and the selection", _cancel_restores, "cancel_restores")
	test("a nested begin is refused and leaves the active edit intact", _nested_begin_refused, "nested_begin_refused")
	test("a repeated commit or cancel is safe", _repeat_close_safe, "repeat_close_safe")
	test("a stale handle cannot touch a newer edit", _stale_handle, "stale_handle")
	test("a document reset closes an abandoned transaction", _abandoned_release, "abandoned_release")
	test("an empty click does not block a later edit", _empty_click_recovery, "empty_click_recovery")
	test("undo restores another frame exactly and redo restores it", _undo_other_frame, "undo_other_frame")
	test("a cancel reentry does not disturb a new edit", _cancel_reentry, "cancel_reentry")
	test("an edit captures the selection and the symmetry", _captured_context, "captured_context")
	test("a same-tool commit reentry keeps the new stroke", _same_tool_reentrant_commit, "same_tool_reentrant_commit")
	test("a same-tool cancel reentry keeps the new stroke", _same_tool_reentrant_cancel, "same_tool_reentrant_cancel")
	test("a same-tool transform cancel keeps the new stroke", _same_tool_reentrant_transform_cancel, "same_tool_reentrant_transform_cancel")
	test("a tool reacquires an edit after a document reset", _tool_reacquire_after_document, "tool_reacquire_after_document")
	test("closed transactions are released while history keeps the frame", _transaction_release, "transaction_release")
	test("one edit scope limits the selection, the slice, and the writes", _scope_filter, "scope_filter")


func before_test() -> void:
	if not _defaults_ready:
		_default_color = State.current_color
		_default_mode = _brush_settings.mode
		_defaults_ready = true
	State.stop()
	State.document = VoxelDocument.new()
	State.current_color = _default_color
	_brush_settings.mode = _default_mode
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.slice_enabled = false
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	State.clear_selection()
	State.undo_redo.clear_history()
	edit = null
	second = null
	released = null
	tool = null
	transform_tool = null
	committed = null
	reentrant = null
	old_context = null
	refs.clear()
	await get_tree().process_frame


# Cancel only the handles this file created. The document reset above already
# releases any transaction that a failed test left open.
func after_test() -> void:
	if is_instance_valid(tool):
		tool.free()
		tool = null
	if is_instance_valid(transform_tool):
		transform_tool.free()
		transform_tool = null
	if edit != null:
		State.cancel_edit(edit)
		edit = null
	if second != null:
		State.cancel_edit(second)
		second = null
	if committed != null:
		State.cancel_edit(committed)
		committed = null
	if reentrant != null:
		State.cancel_edit(reentrant)
		reentrant = null
	State.clear_selection()
	State.undo_redo.clear_history()
	await get_tree().process_frame


func _noop() -> void:
	step("Given a document with one voxel and an open edit", func():
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.undo_redo.clear_history()
		edit = State.begin_edit()
	)
	step("When the edit rewrites the same voxel and closes", func():
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.finish_edit(edit)
		edit = null
	)
	step("Then no history action was recorded", func():
		expect(not State.undo_redo.has_undo(), "an unchanged edit records no history")
		expect(State.active_edit() == null, "the closed edit is no longer active")
	)


func _selection_only() -> void:
	step("Given an open edit on an empty frame", func():
		edit = State.begin_edit()
	)
	step("When the edit only changes the selection", func():
		State.selection.add(Vector3i(3, 0, 3))
		State.finish_edit(edit, "Select")
		edit = null
	)
	step("Then one undo restores the empty selection and redo restores it", func():
		expect(State.undo_redo.has_undo(), "a selection change records one action")
		State.undo_redo.undo()
		expect(State.selection.is_empty(), "undo restores the selection")
		State.undo_redo.redo()
		expect(State.selection.contains(Vector3i(3, 0, 3)), "redo restores the added cell")
	)


func _selection_masks() -> void:
	var first_chunk_cell := Vector3i(1, 2, 3)
	var second_chunk_cell := Vector3i(20, 1, 1)
	var added_cell := Vector3i(33, 4, 5)
	var after_undo_cell := Vector3i(-2, 0, 2)
	step("Given a selection in two chunks and an open edit", func():
		State.selection.add(first_chunk_cell)
		State.selection.add(second_chunk_cell)
		edit = State.begin_edit()
		expect(edit != null, "the edit opens")
	)
	step("When the edit adds a cell in a third chunk", func():
		State.selection.add(added_cell)
		State.finish_edit(edit, "Select")
		edit = null
	)
	step("Then undo installs the recorded masks without a rebuild", func():
		var rebuilds := VoxelSelection._profile_rebuild_calls
		State.undo_redo.undo()
		expect(VoxelSelection._profile_rebuild_calls == rebuilds, "the undo adopts the recorded masks")
		expect(_masks_match_cells(), "the undo masks describe the restored cells")
	)
	step("When a later write changes the restored selection", func():
		State.selection.add(after_undo_cell)
		expect(State.selection.contains(after_undo_cell), "the write lands")
	)
	step("Then redo installs the exact recorded masks", func():
		var rebuilds := VoxelSelection._profile_rebuild_calls
		State.undo_redo.redo()
		expect(VoxelSelection._profile_rebuild_calls == rebuilds, "the redo adopts the recorded masks")
		expect(State.selection.contains(added_cell), "redo restores the added cell")
		expect(not State.selection.contains(after_undo_cell), "redo drops the later cell")
		expect(_masks_match_cells(), "the redo masks describe the restored cells")
	)


# True when the live masks agree with the masks of a fresh rebuild.
func _masks_match_cells() -> bool:
	var rebuilt := VoxelSelection.new()
	rebuilt.cells = State.selection.all_cells().duplicate()
	return VoxelEditTransaction._masks_equal(State.selection.mask_chunks(), rebuilt.mask_chunks())


func _changed_material() -> void:
	var material := VoxelFrame.material(Color(0.25, 0.5, 0.75, 1.0), Color(0.1, 0.2, 0.3), 0.4, 0.6)
	step("Given a plain voxel and an open edit", func():
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.undo_redo.clear_history()
		edit = State.begin_edit()
	)
	step("When the edit writes the full material", func():
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, material)
		State.finish_edit(edit, "Material")
		edit = null
	)
	step("Then undo restores every value and redo restores the change", func():
		expect(State.get_current_voxel_frame().get_material(Vector3i.ZERO) == material, "the changed cell keeps all nine values")
		State.undo_redo.undo()
		expect(State.get_current_voxel_frame().get_color(Vector3i.ZERO) == Color.RED, "undo restores the color")
		expect(State.get_current_voxel_frame().get_metallic(Vector3i.ZERO) == 0.0, "undo restores the default metallic")
		expect(State.get_current_voxel_frame().get_roughness(Vector3i.ZERO) == 1.0, "undo restores the default roughness")
		State.undo_redo.redo()
		expect(State.get_current_voxel_frame().get_material(Vector3i.ZERO) == material, "redo restores all nine values")
	)


func _cancel_restores() -> void:
	var material := VoxelFrame.material(Color.RED)
	var full_bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3(6.0, 1.0, 1.0))
	step("Given two voxels on the frame bounds and an open edit", func():
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, material)
		frame.set_cell(Vector3i(5, 0, 0), material)
		State.undo_redo.clear_history()
		edit = State.begin_edit()
	)
	step("When the edit erases a bound voxel and changes the selection", func():
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i(5, 0, 0), VoxelFrame.material(Color.TRANSPARENT))
		State.selection.add(Vector3i(9, 0, 9))
		expect(frame.get_bounds() != full_bounds, "the erase shrinks the bounds")
		State.cancel_edit(edit)
		edit = null
	)
	step("Then the frame, bounds, and selection return to the start", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.has(Vector3i(5, 0, 0)), "cancel restores the erased voxel")
		expect(frame.get_bounds() == full_bounds, "cancel restores the bounds")
		expect(State.selection.is_empty(), "cancel restores the selection")
		expect(not State.undo_redo.has_undo(), "cancel records no history")
	)


func _nested_begin_refused() -> void:
	step("Given an open edit", func():
		edit = State.begin_edit()
	)
	step("When a second begin runs", func():
		second = State.begin_edit()
	)
	step("Then the second begin returns null and the first edit is intact", func():
		expect(second == null, "a second edit is refused")
		expect(State.active_edit() == edit, "the first edit stays active")
		State.selection.add(Vector3i(1, 0, 1))
		State.finish_edit(edit, "First")
		edit = null
		expect(State.undo_redo.has_undo(), "the first edit still commits")
	)


func _repeat_close_safe() -> void:
	step("Given a committed edit", func():
		edit = State.begin_edit()
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.finish_edit(edit)
	)
	step("Then a repeated finish and cancel do nothing", func():
		var count := State.undo_redo.get_history_count()
		State.finish_edit(edit)
		State.cancel_edit(edit)
		expect(State.undo_redo.get_history_count() == count, "a repeated close adds no history")
		expect(State.active_edit() == null, "no edit is active")
		edit = null
	)


func _stale_handle() -> void:
	step("Given a closed edit and a newer open edit", func():
		edit = State.begin_edit()
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.finish_edit(edit)
		second = State.begin_edit()
		State.get_current_voxel_frame().set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.BLUE))
	)
	step("When the stale handle cancels and finishes", func():
		State.cancel_edit(edit)
		State.finish_edit(edit)
	)
	step("Then the newer edit is untouched and still active", func():
		expect(State.active_edit() == second, "the newer edit stays active")
		expect(State.get_current_voxel_frame().has(Vector3i(1, 0, 0)), "the newer edit keeps its change")
		State.finish_edit(second, "Second")
		second = null
	)


func _abandoned_release() -> void:
	step("Given an open edit", func():
		edit = State.begin_edit()
		released = weakref(edit)
	)
	step("When the document is replaced", func():
		State.document = VoxelDocument.new()
	)
	step("Then the edit is closed and cannot touch the new document", func():
		expect(edit.is_closed(), "the replaced edit is closed")
		expect(edit.frame == null, "the closed edit releases its frame")
		expect(State.active_edit() == null, "no edit is active in the new document")
		State.finish_edit(edit)
		State.cancel_edit(edit)
		expect(not State.undo_redo.has_undo(), "a stale close records no history")
		edit = null
	)
	await get_tree().process_frame
	step("Then the abandoned transaction is freed", func():
		expect(released.get_ref() == null, "the released transaction is freed")
	)


func _empty_click_recovery() -> void:
	step("Given the pencil on an empty grid", func():
		viewport = editor_viewport()
		viewport.get_parent().stretch = false
		viewport.size = Vector2i(800, 500)
		activate_tool("Toolbar")
		select_toolbar_item("Toolbar", "Pencil")
		State.current_color = Color.RED
	)
	step("When the user clicks where no voxel is under the pointer", func():
		_press(Vector2(5.0, 5.0))
		_release(Vector2(5.0, 5.0))
		expect(State.active_edit() == null, "the empty click leaves no open edit")
	)
	step("When the user clicks the center of the empty grid", func():
		_click(Vector2(400.0, 250.0))
	)
	step("Then the later click paints a voxel", func():
		expect(State.get_current_voxel_frame().count() > 0, "the later edit paints a voxel")
		expect(State.active_edit() == null, "the closed edit is released")
	)
	step("When another edit is active and the user clicks", func():
		edit = State.begin_edit()
		before_data = State.get_current_voxel_frame().voxel_data
		before_count = State.get_current_voxel_frame().count()
		_press(Vector2(400.0, 250.0))
		_release(Vector2(400.0, 250.0))
	)
	step("Then the refused click starts no edit and writes no voxel data", func():
		expect(State.active_edit() == edit, "the other edit stays active")
		expect(State.get_current_voxel_frame().voxel_data == before_data, "the refused click writes no voxel data")
		expect(State.get_current_voxel_frame().count() == before_count, "the refused click adds no voxel")
		State.cancel_edit(edit)
		edit = null
	)


func _undo_other_frame() -> void:
	step("Given a duplicate frame edited in an open edit", func():
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.duplicate_frame()
		State.undo_redo.clear_history()
		edit = State.begin_edit()
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.BLUE))
		State.finish_edit(edit)
		edit = null
	)
	step("When the user switches to the first frame and undoes", func():
		State.current_frame = 0
		State.undo_redo.undo()
	)
	step("Then the other frame is restored exactly and redo restores it", func():
		var duplicate: VoxelFrame = State.document.frames[1]
		expect(duplicate.get_color(Vector3i.ZERO) == Color.RED, "undo restores the other frame")
		State.undo_redo.redo()
		expect(duplicate.get_color(Vector3i.ZERO) == Color.BLUE, "redo restores the other frame edit")
	)


func _cancel_reentry() -> void:
	step("Given an edit whose cancel begins a new edit", func():
		edit = State.begin_edit()
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.selection_changed.connect(_begin_on_selection_change, CONNECT_ONE_SHOT)
		State.cancel_edit(edit)
		edit = null
	)
	step("Then the reentrant edit is active and the cancel restored the frame", func():
		expect(State.active_edit() == second, "the reentrant edit is active")
		expect(not State.get_current_voxel_frame().has(Vector3i.ZERO), "the cancel restored the frame")
		State.finish_edit(second)
		second = null
	)


func _begin_on_selection_change() -> void:
	second = State.begin_edit()


func _captured_context() -> void:
	step("Given the X symmetry plane and two selected cells", func():
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3.ZERO
		State.selection.add(Vector3i(2, 0, 0))
		State.selection.add(Vector3i(-2, 0, 0))
		edit = State.begin_edit()
		expect(State.drawing_context().axes == 1, "the edit captures the symmetry axes")
	)
	step("When the symmetry and the selection change during the edit", func():
		State.symmetry_axes = 0
		State.symmetry_origin = Vector3.ONE * 100
		State.selection.clear()
		State.paint(Vector3i(2, 0, 0), VoxelFrame.material(Color.GREEN))
		State.finish_edit(edit)
		edit = null
	)
	step("Then the edit used its captured symmetry and selection", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.has(Vector3i(2, 0, 0)), "the source cell is written")
		expect(frame.has(Vector3i(-2, 0, 0)), "the captured reflection is written")
		expect(not frame.has(Vector3i(198, 0, 0)), "the changed origin is not used")
	)


# One frozen scope holds every writable-cell rule. The write gate applies it to
# any job that carries it, and a job without one writes everything.
func _scope_filter() -> void:
	step("Given a scope with a Y slice and one selected cell", func():
		scope = VoxelFrame.EditContext.new()
		scope.slice_axis = Vector3.Axis.AXIS_Y
		scope.slice_index = 2
		scope.selection[Vector3i(0, 2, 0)] = true
		expect(scope.allows(Vector3i(0, 2, 0)), "the selected slice cell is allowed")
		expect(not scope.allows(Vector3i(0, 3, 0)), "a cell off the slice is refused")
		expect(not scope.allows(Vector3i(1, 2, 0)), "a cell outside the selection is refused")
		var copy := scope.duplicate()
		expect(copy.slice_axis == Vector3.Axis.AXIS_Y and copy.slice_index == 2, "the copy keeps the slice")
		expect(copy.allows(Vector3i(0, 2, 0)), "the copy keeps the selection")
	)
	step("When a job with the scope writes a batch", func():
		var frame := State.get_current_voxel_frame()
		var job := VoxelFrame.EditJob.new()
		job.edit_context = scope
		frame.set_cells({
			Vector3i(0, 2, 0): VoxelFrame.material(Color.RED),
			Vector3i(0, 3, 0): VoxelFrame.material(Color.GREEN),
			Vector3i(1, 2, 0): VoxelFrame.material(Color.BLUE),
		}, job)
		expect(frame.has(Vector3i(0, 2, 0)), "the allowed cell is written")
		expect(not frame.has(Vector3i(0, 3, 0)), "the off-slice cell is not written")
		expect(not frame.has(Vector3i(1, 2, 0)), "the unselected cell is not written")
		expect(job.applied_cells.size() == 1, "the job reports only the written cell")
	)
	step("When a job without a scope writes the same batch", func():
		var frame := State.get_current_voxel_frame()
		frame.set_cells({
			Vector3i(0, 3, 0): VoxelFrame.material(Color.GREEN),
			Vector3i(1, 2, 0): VoxelFrame.material(Color.BLUE),
		}, VoxelFrame.EditJob.new())
		expect(frame.has(Vector3i(0, 3, 0)) and frame.has(Vector3i(1, 2, 0)), "an unscoped job writes every cell")
	)
	step("When a sliced edit is undone", func():
		State.document = VoxelDocument.new()
		State.slice_enabled = true
		State.floor_index = 2
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i(0, 5, 0), VoxelFrame.material(Color.RED))
		var tx := State.begin_edit()
		expect(tx != null, "the sliced edit opens")
		State.paint(Vector3i(0, 2, 0), VoxelFrame.material(Color.BLUE))
		State.finish_edit(tx)
		expect(frame.has(Vector3i(0, 2, 0)), "the sliced edit writes the layer")
		State.undo_redo.undo()
		expect(not frame.has(Vector3i(0, 2, 0)), "undo removes the sliced edit")
		expect(frame.has(Vector3i(0, 5, 0)), "undo restores the whole chunk, not only the slice")
	)


func _open_on_history() -> void:
	reentrant = tool.open_stroke()


func _open_on_selection() -> void:
	reentrant = tool.open_stroke()


func _open_transform_on_selection() -> void:
	reentrant = transform_tool.open_stroke()


# A real transform tool cancels and a selection handler opens a new stroke on the
# same tool. The cancel must reset the input state before the callback and must not
# close the replacement stroke.
func _same_tool_reentrant_transform_cancel() -> void:
	step("Given a real move tool with an open stroke", func():
		transform_tool = MOVE_SCENE.instantiate()
		add_child(transform_tool)
		committed = transform_tool.open_stroke()
		transform_tool._dragging = true
		expect(committed != null, "the move tool opened a stroke")
	)
	step("When a selection handler opens a new stroke during the cancel", func():
		reentrant = null
		State.selection_changed.connect(_open_transform_on_selection, CONNECT_ONE_SHOT)
		transform_tool._cancel()
	)
	step("Then the replacement stroke is active with its own input state", func():
		expect(committed.is_closed(), "the cancelled edit is closed")
		expect(reentrant != null, "the handler opened a new stroke")
		expect(transform_tool._edit == reentrant, "the tool holds the replacement edit")
		expect(State.active_edit() == reentrant, "the replacement edit is active")
		expect(transform_tool._plane == null and not transform_tool._stroke_active, "the cancel reset the input state before the callback")
		expect(not State.undo_redo.has_undo(), "the cancel records no history")
		transform_tool._dragging = false
		transform_tool.abort_stroke()
		expect(State.active_edit() == null, "the replacement edit releases cleanly")
	)


# A real brush commits and a history handler opens a new stroke on the same tool.
# The new stroke must survive the close, with its own context and source frame.
func _same_tool_reentrant_commit() -> void:
	step("Given a real brush with an open stroke", func():
		tool = BRUSH_SCENE.instantiate()
		add_child(tool)
		committed = tool.open_stroke()
		expect(committed != null, "the brush opened a stroke")
	)
	step("When a history handler opens a new stroke on the same tool during the commit", func():
		reentrant = null
		State.history_changed.connect(_open_on_history, CONNECT_ONE_SHOT)
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		tool._end()
	)
	step("Then the tool holds the new edit with its own context", func():
		expect(committed.is_closed(), "the committed edit is closed")
		expect(reentrant != null and reentrant != committed, "the handler opened a new stroke")
		expect(tool._edit == reentrant, "the tool holds the new edit")
		expect(State.active_edit() == reentrant, "the new edit is active")
		expect(tool._edit_context == reentrant.edit_context, "the tool keeps the new stroke context")
		expect(reentrant.edit_context != committed.edit_context, "the new stroke uses a new context")
		expect(tool._source_frame == State.get_current_voxel_frame(), "the tool keeps the new source frame")
	)
	step("Then the new stroke commits and releases cleanly", func():
		expect(State.undo_redo.has_undo(), "the committed edit recorded history")
		tool._end()
		expect(tool._edit == null and State.active_edit() == null, "the new stroke commits and releases")
	)


# A real brush cancels and a selection handler opens a new stroke on the same
# tool. The cancel must restore the frame without clearing the new stroke.
func _same_tool_reentrant_cancel() -> void:
	step("Given a real brush with an open stroke", func():
		tool = BRUSH_SCENE.instantiate()
		add_child(tool)
		committed = tool.open_stroke()
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
	)
	step("When a selection handler opens a new stroke during the cancel", func():
		reentrant = null
		State.selection_changed.connect(_open_on_selection, CONNECT_ONE_SHOT)
		tool._cancel_edit()
	)
	step("Then the tool holds the new edit and the cancelled frame is restored", func():
		expect(committed.is_closed(), "the cancelled edit is closed")
		expect(reentrant != null, "the handler opened a new stroke")
		expect(tool._edit == reentrant, "the tool holds the reentrant edit")
		expect(State.active_edit() == reentrant, "the reentrant edit is active")
		expect(tool._edit_context == reentrant.edit_context, "the tool keeps the new context")
		expect(not State.get_current_voxel_frame().has(Vector3i.ZERO), "the cancel restored the frame")
		tool.abort_stroke()
	)


# A document reset closes the tool's retained handle. The next open drops the
# closed handle and acquires a fresh edit.
func _tool_reacquire_after_document() -> void:
	step("Given a real brush with an open stroke", func():
		tool = BRUSH_SCENE.instantiate()
		add_child(tool)
		committed = tool.open_stroke()
		old_context = committed.edit_context
	)
	step("When the document is replaced while the tool holds the handle", func():
		# A manual tool that does not react to the context change keeps its handle.
		State.edit_context_changing.disconnect(tool._cancel_edit)
		State.document = VoxelDocument.new()
		expect(tool._edit == committed and committed.is_closed(), "the tool holds the closed handle")
		State.edit_context_changing.connect(tool._cancel_edit)
		reentrant = tool.open_stroke()
	)
	step("Then the tool acquires a new edit with a new context", func():
		expect(reentrant != null and reentrant != committed, "the tool acquires a new edit")
		expect(tool._edit == reentrant, "the tool holds the new edit")
		expect(State.active_edit() == reentrant, "the new edit is active")
		expect(reentrant.edit_context != old_context, "the new edit uses a new context")
		tool.abort_stroke()
	)


# A closed transaction releases the live document and selection, while the undo
# history keeps the frozen frame on purpose.
func _transaction_release() -> void:
	step("Given a commit, a cancel, and a no-op edit", func():
		refs.clear()
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.undo_redo.clear_history()
		var tx1 := State.begin_edit()
		frame.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.BLUE))
		State.finish_edit(tx1)
		refs.append(weakref(tx1))
		var tx2 := State.begin_edit()
		frame.set_cell(Vector3i(2, 0, 0), VoxelFrame.material(Color.GREEN))
		State.cancel_edit(tx2)
		refs.append(weakref(tx2))
		var tx3 := State.begin_edit()
		State.finish_edit(tx3)
		refs.append(weakref(tx3))
		tx1 = null
		tx2 = null
		tx3 = null
	)
	await get_tree().process_frame
	step("Then every closed transaction is released while the history keeps the frame", func():
		for ref: WeakRef in refs:
			expect(ref.get_ref() == null, "the closed transaction is released")
		expect(State.undo_redo.has_undo(), "the commit stays in history")
		State.undo_redo.undo()
		expect(not State.get_current_voxel_frame().has(Vector3i(1, 0, 0)), "the history restores the frozen frame")
	)


func _press(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	viewport.push_input(event)


func _release(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = pos
	viewport.push_input(event)


func _click(pos: Vector2) -> void:
	_press(pos)
	_release(pos)
