class_name VoxelEditTransaction
extends RefCounted

# One owned edit. The transaction captures the document, the target frame, the
# frozen edit context, and the start snapshots. It compares the end state and
# releases its live references when it closes. It never holds State or UndoRedo,
# so the undo history can keep frozen snapshots without a reference cycle.
var document: VoxelDocument
var frame: VoxelFrame
# The context captured at begin. Its selection is a read-only copy-on-write
# snapshot, so a later selection write cannot change the captured context.
var edit_context: VoxelFrame.EditContext
var _selection: VoxelSelection
var _start_chunks := {}
var _start_selection := {}
var _closed := false


# The frozen before and after snapshots of one committed edit. The history binds
# these, never the transaction.
class Change extends RefCounted:
	var frame: VoxelFrame
	var undo_chunks: Dictionary
	var undo_selection: Dictionary
	var redo_chunks: Dictionary
	var redo_selection: Dictionary


# The frozen start snapshots of one rolled-back edit.
class Rollback extends RefCounted:
	var frame: VoxelFrame
	var chunks: Dictionary
	var selection: Dictionary


static func begin(edited_document: VoxelDocument, edited_frame: VoxelFrame, edited_selection: VoxelSelection, context: VoxelFrame.EditContext) -> VoxelEditTransaction:
	var transaction := VoxelEditTransaction.new()
	transaction.document = edited_document
	transaction.frame = edited_frame
	transaction.edit_context = context
	transaction._selection = edited_selection
	# The start snapshots mark the chunks and the selection shared, so the next
	# write copies before it mutates and these snapshots stay frozen.
	transaction._start_chunks = edited_frame.capture()
	transaction._start_selection = edited_selection.capture()
	return transaction


func is_closed() -> bool:
	return _closed


# The change for one history action, or null when the frame and the selection are
# unchanged. The result owns its snapshots. This releases the live references, so
# a retained transaction cannot pin the selection or the frame.
func finish() -> Change:
	if _closed:
		return null
	_closed = true
	var end_chunks := frame.capture()
	var changed := not _chunks_equal(_start_chunks, end_chunks) or _start_selection != _selection.all_cells()
	var change: Change = null
	if changed:
		change = Change.new()
		change.frame = frame
		change.undo_chunks = _start_chunks
		change.undo_selection = _start_selection
		change.redo_chunks = end_chunks
		change.redo_selection = _selection.capture()
	_release()
	return change


# The restore triple for a rollback, or null when the transaction was already
# closed. This releases the live references.
func cancel() -> Rollback:
	if _closed:
		return null
	_closed = true
	var rollback := Rollback.new()
	rollback.frame = frame
	rollback.chunks = _start_chunks
	rollback.selection = _start_selection
	_release()
	return rollback


# Close without a restore or a history change. The owning document is replaced, so
# the captured frame must not touch the replacement.
func abandon() -> void:
	if _closed:
		return
	_closed = true
	_release()


func _release() -> void:
	document = null
	frame = null
	edit_context = null
	_selection = null
	_start_chunks = {}
	_start_selection = {}


# Compare by content. Two equal chunks can number their ids differently. This is
# static so the history compare and its measurement share one implementation.
static func _chunks_equal(first_chunks: Dictionary, second_chunks: Dictionary) -> bool:
	if first_chunks.size() != second_chunks.size():
		return false
	for chunk_location in first_chunks:
		if not second_chunks.has(chunk_location):
			return false
		var first_chunk: VoxelFrame.Chunk = first_chunks[chunk_location]
		var second_chunk: VoxelFrame.Chunk = second_chunks[chunk_location]
		if first_chunk != second_chunk and not first_chunk.equals(second_chunk):
			return false
	return true
