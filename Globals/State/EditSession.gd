extends RefCounted

const DocumentSession := preload("res://Globals/State/DocumentSession.gd")
const SelectionState := preload("res://Globals/State/SelectionState.gd")
const EditingAids := preload("res://Globals/State/EditingAids.gd")

signal edit_state_changed()

var session: DocumentSession
var selection_state: SelectionState
var aids: EditingAids
var commit_history := Callable()
var cells_changed := Callable()
var history_restore_chunks := Callable()

var _active_edit: VoxelEditTransaction


func begin_edit(frame_index: int = -1) -> VoxelEditTransaction:
	if _active_edit != null:
		return null
	var frame := _current_frame() if frame_index < 0 else _frame(frame_index)
	if frame == null:
		return null
	_active_edit = VoxelEditTransaction.begin(session.document, frame, selection_state.selection, aids.drawing_context(null))
	edit_state_changed.emit()
	return _active_edit


func active_edit() -> VoxelEditTransaction:
	return _active_edit


func frozen_context() -> VoxelFrame.EditContext:
	return _active_edit.edit_context if _active_edit != null else null


func finish_edit(tx: VoxelEditTransaction, action: String = "Stroke") -> void:
	if tx == null or tx != _active_edit:
		return
	_active_edit = null
	var change := tx.finish()
	if change == null:
		edit_state_changed.emit()
		return
	var history := session.document.edit_history
	history.create_action(action)
	history.add_undo_method(history_restore_chunks.bind(change.frame, change.undo_chunks, change.undo_selection, change.undo_selection_masks))
	history.add_do_method(history_restore_chunks.bind(change.frame, change.redo_chunks, change.redo_selection, change.redo_selection_masks))
	commit_history.call(false)
	edit_state_changed.emit()


func finish_edit_collect(tx: VoxelEditTransaction) -> VoxelEditTransaction.Change:
	if tx == null or tx != _active_edit:
		return null
	_active_edit = null
	var change := tx.finish()
	edit_state_changed.emit()
	return change


func commit_changes(changes: Array, action: String = "Write Cells") -> void:
	if changes.is_empty():
		return
	var history := session.document.edit_history
	history.create_action(action)
	for value in changes:
		var change: VoxelEditTransaction.Change = value
		history.add_do_method(history_restore_chunks.bind(change.frame, change.redo_chunks, change.redo_selection, change.redo_selection_masks))
	for index in range(changes.size() - 1, -1, -1):
		var change: VoxelEditTransaction.Change = changes[index]
		history.add_undo_method(history_restore_chunks.bind(change.frame, change.undo_chunks, change.undo_selection, change.undo_selection_masks))
	commit_history.call(false)


func cancel_changes(changes: Array) -> void:
	if changes.is_empty():
		return
	for index in range(changes.size() - 1, -1, -1):
		var change: VoxelEditTransaction.Change = changes[index]
		_restore_chunks(change.frame, change.undo_chunks, change.undo_selection, change.undo_selection_masks)
	edit_state_changed.emit()


func cancel_edit(tx: VoxelEditTransaction) -> void:
	if tx == null or tx != _active_edit:
		return
	_active_edit = null
	var rollback := tx.cancel()
	if rollback == null:
		edit_state_changed.emit()
		return
	_restore_chunks(rollback.frame, rollback.chunks, rollback.selection, rollback.selection_masks)
	edit_state_changed.emit()


func _abandon_active_edit() -> void:
	if _active_edit == null:
		return
	_active_edit.abandon()
	_active_edit = null


func _restore_chunks(edited_frame: VoxelFrame, chunk_snapshot: Dictionary, selection_snapshot: Dictionary, selection_snapshot_masks: Dictionary = {}) -> void:
	var location := session.document.find_cel(edited_frame)
	if location.x < 0:
		return
	var cells_restored := edited_frame.chunks != chunk_snapshot
	edited_frame.restore(chunk_snapshot)
	session.document._bounds_dirty = true
	selection_state.selection.restore(selection_snapshot, selection_snapshot_masks)
	if cells_restored:
		var affected_cells: Array[Vector3i] = []
		cells_changed.call(location.y, affected_cells)
	selection_state.notify_changed()


func restore_history_chunks(edited_frame: VoxelFrame, chunk_snapshot: Dictionary, selection_snapshot: Dictionary, selection_snapshot_masks: Dictionary = {}) -> void:
	_restore_chunks(edited_frame, chunk_snapshot, selection_snapshot, selection_snapshot_masks)


func _current_frame() -> VoxelFrame:
	return _frame(session.playback.current_frame)


func _frame(index: int) -> VoxelFrame:
	return session.document.cel(session.document.edit_layer, index)
