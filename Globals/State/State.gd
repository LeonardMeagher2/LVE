extends Node

## The application singleton for editor state.
##
## State owns the current document, the current frame, the selection, the undo
## history, and the operation list. It also owns the one open edit. It is
## registered as the `State` autoload.
##
## Use the signals to observe changes. Start model changes through the edit and
## history methods, so an undo restores them.

## Emitted when the document is replaced.
signal document_changed()
## Emitted when cells in a frame change. [param frame] is the frame index.
## [param affected] lists the changed cells.
signal cells_changed(frame: int, affected: Array[Vector3i])
## Emitted when chunks in a frame need a surface rebuild. [param frame] is the
## frame index. [param affected] lists one cell per changed chunk.
signal chunks_changed(frame: int, affected: Array[Vector3i])
## Emitted when the frame list or a tag range changes.
signal frames_changed()
## Emitted when a frame property changes.
signal frame_changed()
## Emitted when playback starts or stops. [param toggled_on] is the new state.
signal is_playing_toggled(toggled_on:bool)
## Emitted when the current color changes.
signal color_changed(color: Color)
## Emitted when the current material changes.
signal material_changed()
## Emitted when the document palette changes.
signal palette_changed()
## Emitted when the default palette changes.
signal default_palette_changed()
## Emitted when the cell selection changes.
signal selection_changed()
## Emitted when the floor axis or the floor index changes.
signal floor_plane_changed()
## Emitted when the slice option changes.
signal slice_changed()
## Emitted when the symmetry axes or the symmetry origin change.
signal symmetry_changed()
## Emitted when a tag property changes.
signal tag_changed()
## Emitted when an operation starts, updates, or finishes.
signal activity_changed()
## Emitted before the edit context changes. An open edit or drag must cancel its
## work on this signal.
signal edit_context_changing()
## Emitted when a model setting changes.
signal model_settings_changed()
## Emitted after an undo or redo, and after each history commit.
signal history_changed()
## Emitted when an owned edit opens or closes. A history change is refused while
## an edit is open, so observers use this signal to refresh the history controls.
signal edit_state_changed()

## The main-thread work slice in microseconds for one pumped frame.
const WORK_SLICE_US := 3000
## The user path of the saved default palette.
const DEFAULT_PALETTE_PATH := "user://default_palette.cfg"
## The user path of the session file.
const SESSION_PATH := "user://session.cfg"
## The default symmetry origin, at the corner between eight cells.
const DEFAULT_SYMMETRY_ORIGIN := Vector3(-0.5, -0.5, -0.5)
## The image file extensions that the importer supports.
const IMAGE_EXTENSIONS := ["bmp", "dds", "exr", "hdr", "jpg", "jpeg", "ktx", "ktx2", "png", "svg", "tga", "webp"]

## The palette that the New Document action applies.
var default_palette := get_builtin_palette()

## One tracked operation for the status display.
##
## State owns the list. The owner starts an operation with
## [method State.begin_operation] and finishes it with
## [method State.finish_operation].
class Operation extends RefCounted:
	## The unique operation id.
	var id := 0
	# The artist-facing identity the owner set at begin_operation. It is stable, so
	# the status display never changes its action name while the operation runs.
	## The artist-facing action name. It stays fixed for the whole operation.
	var label := ""
	# The owner's current progress stage. It is diagnostic only: the status display
	# shows the begin label, not this stage.
	## The owner's current progress stage. It is diagnostic only.
	var phase := ""
	## A diagnostic detail line for the current stage.
	var detail := ""
	## The completed work count.
	var completed := 0
	## The total work count. A value below one means an unknown total.
	var total := -1
	## Whether the operation owns Escape and the status display.
	var foreground := false
	# Set when a cancel request was accepted. The owner finishes the operation, so
	# completion stays with finish_operation.
	## Whether a cancel request was accepted. The owner finishes the operation.
	var cancel_requested := false
	## A weak reference to the operation owner.
	var owner_ref: WeakRef
	# An operation is cancellable only when its owner registered this callback. The
	# capability is explicit, so a foreground operation without one stays visible and
	# is not cancellable.
	var _cancel_callback := Callable()

	## Returns [code]true[/code] when a cancel request can still be accepted.
	func can_cancel() -> bool:
		return not cancel_requested and _cancel_callback.is_valid()

var _operations: Dictionary[int, Operation] = {}
var _next_operation_id := 1
var _activity_started_ms := 0
var _erase_job: EraseJob
var _erase_operation_id := 0
var _erase_jobs: Array[EraseJob] = []

## One erase edit job that clears every selected cell.
##
## The job shares one transparent material across the selection. State runs it
## on the worker pool when the selection is large.
class EraseJob extends VoxelFrame.EditJob:
	## The edited frame copy. The result replaces the live frame.
	var edited_frame: VoxelFrame
	## The selected cells as a dictionary keyed by cell position.
	var selection_mask := {}
	## The chunk locations that the erase changed.
	var changed_chunks: Array[Vector3i] = []

	## Runs the erase on the calling thread. It checks the cancel flag at each
	## checkpoint.
	func run() -> void:
		stage("Preparing erase", selection_mask.size())
		var changes := {}
		# One material serves every cell. The write path only reads it, and the old
		# loop allocated a nine-float copy for each selected cell.
		var erased_material := VoxelFrame.material(Color.TRANSPARENT)
		var completed := 0
		for cell_position in selection_mask:
			changes[cell_position] = erased_material
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return
		stage("Erasing selection", changes.size())
		# The declared material lets a full-chunk batch skip the uniformity walk.
		changed_chunks = edited_frame.set_cells(changes, self, erased_material)


## The animation playback state.
var playback := AnimationPlayback.new()
## The current document. A write replaces the document and resets the history.
var document: VoxelDocument : set=set_document

## The index of the current frame.
var current_frame: int:
	get:
		return playback.current_frame
	set(value):
		playback.current_frame = value

## Whether animation playback runs.
var is_playing: bool:
	get:
		return playback.is_playing
	set(value):
		playback.is_playing = value

## The index of the active tag, or -1 when no tag is active.
var active_tag: int:
	get:
		return playback.active_tag
	set(value):
		playback.active_tag = value

## The world axis of the floor plane. Axis 0 is X, axis 1 is Y, and axis 2 is Z.
var floor_axis:Vector3.Axis = Vector3.Axis.AXIS_Y:
	set(value):
		if value == floor_axis:
			return
		floor_axis = value
		floor_plane_changed.emit()

## The cell index of the floor plane along [member floor_axis].
var floor_index := 0:
	set(value):
		if value == floor_index:
			return
		floor_index = value
		floor_plane_changed.emit()

## Whether the slice limits every edit. It is a view of [member slice_layers],
## so 0 layers means every layer is writable.
var slice_enabled: bool:
	get:
		return slice_layers > 0
	set(value):
		slice_layers = 1 if value else 0

## The largest slice layer count on each side.
const MAX_SLICE_LAYERS := 8

## The number of writable and visible layers on each side of the floor plane. 0
## shows every layer. 1 keeps one layer on each side of the plane.
var slice_layers := 0:
	set(value):
		value = clampi(value, 0, MAX_SLICE_LAYERS)
		if value == slice_layers:
			return
		slice_layers = value
		slice_changed.emit()


## Returns the first layer of the slice.
func slice_first() -> int:
	return floor_index - slice_layers


## Returns the last layer of the slice.
func slice_last() -> int:
	return floor_index + slice_layers - 1 if slice_layers > 0 else floor_index


## Returns the number of layers in the slice. The floor plane splits the slab
## evenly, so the floor layer is the first layer above it.
func slice_count() -> int:
	return slice_layers * 2 if slice_layers > 0 else 1


## Returns the world level of the slice plane.
func slice_level() -> float:
	return float(floor_index) - 0.5

## The symmetry axes as a bit mask. Bit 0 is X, bit 1 is Y, and bit 2 is Z.
var symmetry_axes := 0:
	set(value):
		value &= 7
		if value == symmetry_axes:
			return
		symmetry_axes = value
		symmetry_changed.emit()

## The symmetry origin in cell units. It snaps to half units.
var symmetry_origin := DEFAULT_SYMMETRY_ORIGIN:
	set(value):
		value = value.snapped(Vector3.ONE * 0.5)
		if value == symmetry_origin:
			return
		symmetry_origin = value
		symmetry_changed.emit()

var _current_material := VoxelFrame.material(Color.BLACK)
## The current material as nine floats. A read returns a copy. A write records a
## history action.
var current_material: PackedFloat32Array:
	get:
		return _current_material.duplicate()
	set(value):
		set_material(value)
## The palette index that matches the current material, or -1 when none matches.
var current_palette_index := -1
## The color of the current material. A write keeps the other material values.
var current_color: Color:
	get:
		return VoxelFrame.material_color(_current_material)
	set(value):
		var material := current_material
		material[0] = value.r
		material[1] = value.g
		material[2] = value.b
		material[3] = value.a
		_apply_material(material)
var _material_edit_document: VoxelDocument
var _material_edit_before := PackedFloat32Array()
## The current cell selection.
var selection := VoxelSelection.new()
## The undo and redo history of the current document.
var undo_redo := UndoRedo.new()
# The one open edit, or null. It supplies the frozen edit context to drawing and
# holds the identity a commit or a cancel must match. The owner holds the handle.
var _active_edit: VoxelEditTransaction
# The handle of the running erase selection coroutine.
var _erase_edit: VoxelEditTransaction


func _init() -> void:
	playback.frame_changing.connect(edit_context_changing.emit)
	playback.frame_changed.connect(frame_changed.emit)
	playback.is_playing_toggled.connect(is_playing_toggled.emit)
	playback.tag_changed.connect(tag_changed.emit)
	document = VoxelDocument.new()

func _ready() -> void:
	load_default_palette()
	document.palette = _copy_palette(default_palette)
	_apply_material(default_palette[0])
	edit_context_changing.connect(_interrupt_erase)
	cells_changed.connect(func(_frame, _affected): stop())
	chunks_changed.connect(func(_frame, _affected): stop())
	
	add_plugin(load("res://plugins/brush/BrushPlugin.gd").new())
	add_plugin(load("res://plugins/Eyedropper/EyedropperPlugin.gd").new())
	add_plugin(load("res://plugins/paint/PaintPlugin.gd").new())
	add_plugin(load("res://plugins/Terrain/TerrainPlugin.gd").new())
	add_plugin(load("res://plugins/selection/SelectionPlugin.gd").new())
	add_plugin(load("res://plugins/Transform/TransformPlugin.gd").new())
	add_plugin(load("res://plugins/Symmetry/SymmetryPlugin.gd").new())
	add_plugin(load("res://plugins/Plane/PlanePlugin.gd").new())
	add_plugin(load("res://plugins/Export/ExportPlugin.gd").new())
	add_plugin(load("res://plugins/Clipboard/ClipboardPlugin.gd").new())
	add_plugin(load("res://plugins/ImageImport/ImageImportPlugin.gd").new())
	


## Replaces the document and resets the history and the selection. A value that
## is not a [VoxelDocument] creates a new empty document.
func set_document(value:VoxelDocument) -> void:
	if value == document:
		return
	_material_edit_document = null
	_material_edit_before = PackedFloat32Array()
	edit_context_changing.emit()
	_operations.clear()
	_activity_started_ms = 0
	activity_changed.emit()
	# The owners cancel or finish their own edit on the signal above. An owner that
	# is not connected leaves its transaction open, so close it here. The captured
	# frame belongs to the replaced document and must not touch the replacement.
	_abandon_active_edit()
	selection.clear()
	selection_changed.emit()
	undo_redo.clear_history()
	history_changed.emit()
	if value is VoxelDocument:
		document = value
	else:
		document = VoxelDocument.new()
		document.palette = _copy_palette(default_palette)
		_apply_material(default_palette[0])
	_apply_material(_current_material)
	if document.tags.is_empty():
		document.add_tag("Default", 0, document.frames.size() - 1)
	playback.document = document
	active_tag = 0
		
	document_changed.emit()
	palette_changed.emit()
	frames_changed.emit()
	current_frame = 0
	# Emit after the replacement. A handler that opens a new edit then uses the
	# new document, not the captured frame that the abandon released.
	edit_state_changed.emit()


func _commit_history(execute: bool = true) -> void:
	undo_redo.commit_action(execute)
	history_changed.emit()


## Undoes the last history action. Returns [code]true[/code] when an action was
## undone. It returns [code]false[/code] while an edit is open: the edit captured
## a start snapshot that a history change would invalidate, so the edit must close
## first.
func undo() -> bool:
	if _active_edit != null:
		return false
	var undone := undo_redo.undo()
	if undone:
		history_changed.emit()
	return undone


## Redoes the last undone action. Returns [code]true[/code] when an action was
## redone. It returns [code]false[/code] while an edit is open, for the same
## reason as [method undo].
func redo() -> bool:
	if _active_edit != null:
		return false
	var redone := undo_redo.redo()
	if redone:
		history_changed.emit()
	return redone


## Adds one plugin under the scene root.
func add_plugin(plugin: VoxelPlugin) -> void:
	get_node("/root").add_child.call_deferred(plugin, true)
	
## Removes one plugin and frees it.
func remove_plugin(plugin: VoxelPlugin) -> void:
	get_node("/root").remove_child(plugin)
	plugin.queue_free()


## Paints one cell with the current edit context. It expands the cell through
## symmetry and maps it through the selection and the slice.
func paint(position: Vector3i, cell_material: PackedFloat32Array) -> void:
	if symmetry_axes == 0 and not slice_enabled and _active_edit == null:
		document.paint(current_frame, position, cell_material)
		return
	var context := drawing_context()
	var changes := context.expand({position: cell_material}, get_current_voxel_frame(), false, null)
	get_current_voxel_frame().set_cells(changes)
	document._bounds_dirty = true


## Returns the edit context for the current drawing. An open edit supplies its
## frozen context, so a later change cannot alter the open stroke.
func drawing_context() -> VoxelFrame.EditContext:
	# A stroke keeps the context it captured at begin, so a symmetry or selection
	# change during the stroke cannot alter the cells it writes.
	if _active_edit != null:
		return _active_edit.edit_context
	return _live_context()


func _live_context() -> VoxelFrame.EditContext:
	var context := VoxelFrame.EditContext.new()
	context.axes = symmetry_axes
	context.origin_twice = Vector3i(symmetry_origin * 2.0)
	context.selection = selection.capture()
	context.selection.make_read_only()
	if slice_enabled:
		context.slice_axis = floor_axis
		context.slice_index = slice_first()
		context.slice_count = slice_count()
	return context


## Returns the transform that mirrors a point for one symmetry mask.
func symmetry_transform(mask: int, origin: Vector3) -> Transform3D:
	var reflection := Vector3.ONE
	for axis in 3:
		if mask & (1 << axis):
			reflection[axis] = -1.0
	return Transform3D(Basis.from_scale(reflection), origin - origin * reflection)


## Returns an edit context that carries the symmetry and the slice, but not the
## selection filter.
func selection_context() -> VoxelFrame.EditContext:
	var context := drawing_context().duplicate()
	context.selection = {}
	return context


## Returns the region after the symmetry expansion. The selection filter is not
## applied.
func selection_region(region: VoxelSelection) -> VoxelSelection:
	var result := VoxelSelection.new()
	result.restore(selection_context().expand(region.capture(), get_current_voxel_frame(), false, null))
	return result


## Starts one tracked operation and returns its id. [param label] is the artist
## action. A [param total] below one means an unknown total. A [param
## cancel_callback] makes the operation cancellable.
func begin_operation(label: String, total: int = -1, foreground: bool = false, operation_owner: Node = null, cancel_callback: Callable = Callable()) -> int:
	var operation := Operation.new()
	operation.label = label
	operation.total = total
	operation.foreground = foreground
	operation._cancel_callback = cancel_callback
	if operation_owner:
		operation.owner_ref = weakref(operation_owner)
	if _operations.is_empty():
		_activity_started_ms = Time.get_ticks_msec()
	var operation_id := _next_operation_id
	_next_operation_id += 1
	operation.id = operation_id
	_operations[operation_id] = operation
	activity_changed.emit()
	return operation_id


# Request the cancellation of one operation. The owner runs its own cooperative
# cancel path, so the request marks the operation and calls its callback. A second
# request returns false, and completion stays with finish_operation. Returns true
# when the request was accepted.
## Requests the cancellation of one operation. Returns [code]true[/code] when
## the request was accepted. A second request returns [code]false[/code]. The
## owner finishes the operation.
func cancel_operation(operation_id: int) -> bool:
	var operation: Operation = _operations.get(operation_id)
	if operation == null or not operation.can_cancel():
		return false
	# Mark the request before the callback, so a repeat request is refused even when
	# the callback defers its work.
	operation.cancel_requested = true
	var callback := operation._cancel_callback
	activity_changed.emit()
	if callback.is_valid():
		callback.call()
	return true


# Cancel the cancellable foreground operation the status bar shows. Esc uses this,
# so it still reaches a tool that a tool switch detached from the tree.
## Cancels the cancellable foreground operation that the status bar shows.
## Returns [code]true[/code] when the request was accepted or already pending.
func cancel_activity() -> bool:
	var operation := get_activity()
	if operation == null or not operation.foreground:
		return false
	# A pending cancellation already owns Esc. Report it as handled, so a repeat
	# Escape is swallowed instead of reaching a tool's own cancel.
	if operation.cancel_requested:
		return true
	return cancel_operation(operation.id)


# Update the measured progress and the internal stage of one operation. The stage
# and the detail are diagnostic: the status display shows only the begin label. The
# begin label is never replaced, so a worker stage cannot change the artist action.
## Updates the measured progress of one operation. [param completed] and [param
## total] drive the percentage. [param phase] and [param detail] are diagnostic
## only.
func update_operation(operation_id: int, completed: int, total: int = -1, phase: String = "", detail: String = "") -> void:
	var operation: Operation = _operations.get(operation_id)
	if operation == null:
		return
	if operation.completed == completed and operation.total == total and operation.detail == detail and operation.phase == phase:
		return
	operation.completed = completed
	operation.total = total
	operation.detail = detail
	operation.phase = phase
	activity_changed.emit()


## Finishes one operation and removes it from the list. Does nothing when the id
## is unknown.
func finish_operation(operation_id: int) -> void:
	if not _operations.erase(operation_id):
		return
	if _operations.is_empty():
		_activity_started_ms = 0
	activity_changed.emit()


# Run one edit job on the worker pool while its progress feeds the operation.
# The caller keeps the job, the operation, the result, and its cancel policy.
# `on_frame` runs once per pumped frame before the progress update, so a caller
# can cancel the job when its context changes. The worker is always joined before
# this returns, even when the operation is removed or the caller detaches. A
# caller that waits for the worker itself retires `worker_task_id` through
# `wait_for_worker`, and this stops without a second wait. `wait_for_worker`
# clears the id after its own wait, so a later external wait never waits on a
# disposed task.
## Runs one edit job on the worker pool and pumps its progress. The worker is
## always joined before this returns. [param on_frame] runs once per pumped
## frame before the progress update.
func run_edit_job(job: VoxelFrame.EditJob, operation_id: int, task_name: String, on_frame: Callable = Callable()) -> void:
	job.worker_task_id = WorkerThreadPool.add_task(job.run, true, task_name)
	while job.worker_task_id >= 0 and not WorkerThreadPool.is_task_completed(job.worker_task_id):
		if on_frame.is_valid():
			on_frame.call()
		var progress := job.progress()
		update_operation(operation_id, progress[1], progress[2], progress[0])
		await get_tree().process_frame
	job.wait_for_worker()


## Returns [code]true[/code] when the operation id is tracked.
func has_operation(operation_id: int) -> bool:
	return _operations.has(operation_id)


## Returns the operation for the status display. A foreground operation wins. A
## background operation is the fallback.
func get_activity() -> Operation:
	var background_operation: Operation = null
	for operation in _operations.values():
		if operation.foreground:
			return operation
		if background_operation == null:
			background_operation = operation
	return background_operation


## Returns the elapsed time of the current activity in milliseconds. Returns
## zero when no operation runs.
func activity_elapsed_ms() -> int:
	return Time.get_ticks_msec() - _activity_started_ms if not _operations.is_empty() else 0


## Returns [code]true[/code] when a foreground operation blocks an edit. An
## operation that [param requester] owns does not block it.
func edit_busy(requester: Node = null) -> bool:
	for operation in _operations.values():
		if operation.foreground and (requester == null or operation.owner_ref == null or operation.owner_ref.get_ref() != requester):
			return true
	return false


# Begin one owned edit on the current frame. The transaction captures the frame,
# the selection, and the frozen edit context. Returns null when an edit is already
# active or the current frame is missing, so a caller must check before it mutates
# the model. The caller holds the returned handle for the whole edit.
## Begins one owned edit on the current frame. Returns null while another edit
## is active or the current frame is missing. The caller must check the result
## before it mutates the model.
func begin_edit() -> VoxelEditTransaction:
	if _active_edit != null:
		return null
	var frame := get_current_voxel_frame()
	if frame == null:
		return null
	_active_edit = VoxelEditTransaction.begin(document, frame, selection, _live_context())
	edit_state_changed.emit()
	return _active_edit


## Returns the open edit, or null when no edit is active.
func active_edit() -> VoxelEditTransaction:
	return _active_edit


# Close one owned edit and record its change as one history action. A stale handle
# that no longer owns the active edit does nothing, so a cancelled edit can never
# finish a newer one or roll back a newer document.
## Closes one owned edit and records its change as one history action. A stale
## handle that no longer owns the active edit does nothing. The default action
## is [code]Stroke[/code].
func finish_edit(tx: VoxelEditTransaction, action: String = "Stroke") -> void:
	if tx == null or tx != _active_edit:
		return
	# Clear the active handle before any signal, so a history handler can begin a
	# new edit without this call clearing it again.
	_active_edit = null
	var change := tx.finish()
	if change == null:
		edit_state_changed.emit()
		return
	undo_redo.create_action(action)
	undo_redo.add_undo_method(_restore_chunks.bind(change.frame, change.undo_chunks, change.undo_selection, change.undo_selection_masks))
	undo_redo.add_do_method(_restore_chunks.bind(change.frame, change.redo_chunks, change.redo_selection, change.redo_selection_masks))
	_commit_history(false)
	edit_state_changed.emit()


# Roll one owned edit back to its start snapshots. A stale handle does nothing.
## Rolls one owned edit back to its start snapshots. A stale handle does
## nothing.
func cancel_edit(tx: VoxelEditTransaction) -> void:
	if tx == null or tx != _active_edit:
		return
	# Clear the active handle before the restore signals, so a selection handler
	# can begin a new edit and this restore cannot roll it back.
	_active_edit = null
	var rollback := tx.cancel()
	if rollback == null:
		edit_state_changed.emit()
		return
	_restore_chunks(rollback.frame, rollback.chunks, rollback.selection, rollback.selection_masks)
	edit_state_changed.emit()


# Close an edit whose document is replaced. The replacement discards the captured
# frame, so the transaction releases its references without a restore.
func _abandon_active_edit() -> void:
	if _active_edit == null:
		return
	_active_edit.abandon()
	_active_edit = null


func _restore_chunks(edited_frame: VoxelFrame, chunk_snapshot: Dictionary, selection_snapshot: Dictionary, selection_snapshot_masks: Dictionary = {}) -> void:
	var frame_index := document.frames.find(edited_frame)
	if frame_index == -1:
		return
	var cells_restored := edited_frame.chunks != chunk_snapshot
	edited_frame.restore(chunk_snapshot)
	document._bounds_dirty = true
	selection.restore(selection_snapshot, selection_snapshot_masks)
	if cells_restored:
		var affected_cells: Array[Vector3i] = []
		cells_changed.emit(frame_index, affected_cells)
	selection_changed.emit()

## Returns [code]true[/code] when the current frame holds the cell.
func has_cell(position: Vector3i) -> bool:
	return document.has_cell(current_frame, position)

## Starts playback of the active tag.
func play():
	is_playing = true

## Selects one tag and starts playback.
func play_tag(i: int) -> void:
	active_tag = i
	is_playing = true

## Stops playback.
func stop():
	is_playing = false

## Selects one tag without playback.
func select_tag(i: int) -> void:
	active_tag = i

## Clears the active tag.
func deselect_tag() -> void:
	active_tag = -1


func _process(delta: float) -> void:
	for operation_id in _operations.keys():
		var operation: Operation = _operations[operation_id]
		if operation.owner_ref and operation.owner_ref.get_ref() == null:
			finish_operation(operation_id)
	playback.update(delta)

## Sets the RGB and alpha of the current material and records a history action.
func set_color(color: Color) -> void:
	var material := current_material
	material[0] = color.r
	material[1] = color.g
	material[2] = color.b
	material[3] = color.a
	set_material(material)


## Sets the current material and records a history action. An invalid material
## is ignored.
func set_material(material: PackedFloat32Array) -> void:
	if not VoxelDocument.valid_material(material):
		return
	end_material_edit()
	if material == _current_material:
		return
	undo_redo.create_action("Set Material", UndoRedo.MERGE_ENDS)
	undo_redo.add_undo_method(_apply_material.bind(current_material))
	undo_redo.add_do_method(_apply_material.bind(material.duplicate()))
	_commit_history()


func _apply_material(material: PackedFloat32Array) -> void:
	var next := material.duplicate()
	# A swatch is selected only while all its values match the current material.
	var index := document.palette.find(next) if document else -1
	var changed := next != _current_material or index != current_palette_index
	_current_material = next
	current_palette_index = index
	if changed:
		color_changed.emit(current_color)
		material_changed.emit()


## Selects a palette entry as the current material. An out-of-range index is
## ignored.
func select_palette_entry(index: int) -> void:
	if index < 0 or index >= document.palette.size():
		return
	end_material_edit()
	_apply_material(document.palette[index])


## Adds the current material to the palette. An existing equal entry is selected
## instead.
func add_material() -> void:
	if edit_busy():
		return
	end_material_edit()
	var index := document.palette.find(_current_material)
	if index >= 0:
		select_palette_entry(index)
		return
	if document.palette.size() >= VoxelDocument.MAX_PALETTE_COLORS:
		return
	var before := _palette_snapshot()
	document.palette.append(_current_material.duplicate())
	_apply_material(_current_material)
	_record_palette_action("Add Palette Material", before)


## Returns the color of one palette entry.
func get_color(index: int) -> Color:
	return document.get_color(index)
	
## Returns the color of one cell in the current frame.
func get_color_at(position: Vector3i) -> Color:
	return document.get_color_at(current_frame, position)

## Removes the selected palette entry.
func remove_palette_entry() -> void:
	if edit_busy() or current_palette_index < 0:
		return
	end_material_edit()
	var before := _palette_snapshot()
	var index := current_palette_index
	document.palette.remove_at(index)
	if document.palette.is_empty():
		_apply_material(_current_material)
	else:
		_apply_material(document.palette[mini(index, document.palette.size() - 1)])
	_record_palette_action("Remove Palette Material", before)


## Returns a copy of the document palette.
func get_palette() -> Array[PackedFloat32Array]:
	return _copy_palette(document.palette)


## Replaces the document palette and records a history action. An invalid
## palette is ignored. The default action name is [code]Replace Palette[/code].
func set_palette(materials: Array[PackedFloat32Array], action_name: String = "Replace Palette") -> void:
	if edit_busy() or not VoxelDocument.valid_palette(materials):
		return
	end_material_edit()
	var unique := _copy_palette(materials)
	if document.palette == unique:
		return
	var before := _palette_snapshot()
	document.palette = unique
	_apply_material(_current_material)
	_record_palette_action(action_name, before)


## Moves one palette entry to a new index and records a history action.
func move_palette_entry(from_index: int, to_index: int) -> void:
	if edit_busy() or from_index == to_index or from_index < 0 or to_index < 0 or from_index >= document.palette.size() or to_index >= document.palette.size():
		return
	end_material_edit()
	var before := _palette_snapshot()
	var material := document.palette[from_index]
	document.palette.remove_at(from_index)
	document.palette.insert(to_index, material)
	_apply_material(_current_material)
	_record_palette_action("Move Palette Material", before)


## Applies one material edit. A control gesture records one history step for all
## its changes.
func edit_material(material: PackedFloat32Array) -> void:
	if edit_busy() or not VoxelDocument.valid_material(material) or material == _current_material:
		return
	var before := current_material
	_apply_material(material)
	# A control gesture records one undo step for all its changes.
	if _material_edit_document != document:
		_record_material_action(before)


## Starts one material edit gesture. The gesture records one history action.
func begin_material_edit() -> void:
	if edit_busy() or _material_edit_document != null:
		return
	_material_edit_document = document
	_material_edit_before = current_material


## Ends the material edit gesture and records its history action.
func end_material_edit() -> void:
	var edited_document := _material_edit_document
	var before := _material_edit_before
	_material_edit_document = null
	_material_edit_before = PackedFloat32Array()
	if edited_document == document and not before.is_empty() and before != _current_material:
		_record_material_action(before)


## Cancels the material edit gesture and restores the start material.
func cancel_material_edit() -> void:
	var edited_document := _material_edit_document
	var before := _material_edit_before
	_material_edit_document = null
	_material_edit_before = PackedFloat32Array()
	if edited_document == document and not before.is_empty():
		_apply_material(before)


func _record_material_action(before: PackedFloat32Array) -> void:
	undo_redo.create_action("Edit Material")
	undo_redo.add_undo_method(_apply_material.bind(before))
	undo_redo.add_do_method(_apply_material.bind(current_material))
	_commit_history(false)


func _copy_palette(materials: Array) -> Array[PackedFloat32Array]:
	return VoxelDocument.unique_palette(materials)


func _palette_snapshot() -> Dictionary:
	# The index follows from the palette and the material. Store only what an undo must restore.
	return {"palette": get_palette(), "material": current_material}


func _record_palette_action(action_name: String, before: Dictionary) -> void:
	var after := _palette_snapshot()
	if before == after:
		return
	undo_redo.create_action(action_name)
	undo_redo.add_undo_method(_restore_palette.bind(document, before))
	undo_redo.add_do_method(_restore_palette.bind(document, after))
	_commit_history(false)
	palette_changed.emit()


func _restore_palette(edited_document: VoxelDocument, snapshot: Dictionary) -> void:
	if document != edited_document:
		return
	document.palette = _copy_palette(snapshot.palette)
	_apply_material(snapshot.material)
	palette_changed.emit()


## Returns the built-in default palette.
func get_builtin_palette() -> Array[PackedFloat32Array]:
	# Keep grayscale first, then vivid hues, cooler shadows, and warmer highlights.
	var colors := PackedColorArray([
		Color.BLACK, Color("808080"), Color.WHITE,
		Color("ff0000"), Color("ff8000"), Color("ffff00"), Color("80ff00"), Color("00ff00"), Color("00ff80"),
		Color("00ffff"), Color("0080ff"), Color("0000ff"), Color("8000ff"), Color("ff00ff"), Color("ff0080"),
		Color("800020"), Color("608000"), Color("008020"), Color("006080"), Color("200080"), Color("600080"),
		Color("ffb399"), Color("fffbef"), Color("bfffaa"), Color("b3ffec"), Color("b3c6ff"), Color("ffb3ec"),
	])
	var materials: Array[PackedFloat32Array] = []
	for color in colors:
		materials.append(VoxelFrame.material(color))
	return materials


## Loads the default palette from a config file. A missing or invalid file keeps
## the built-in palette. The default path is [constant DEFAULT_PALETTE_PATH].
func load_default_palette(path: String = DEFAULT_PALETTE_PATH) -> void:
	default_palette = get_builtin_palette()
	var config := ConfigFile.new()
	if config.load(path) == OK:
		var materials: Variant = config.get_value("palette", "materials") if config.has_section_key("palette", "materials") else null
		if materials == null:
			var colors: Variant = config.get_value("palette", "colors") if config.has_section_key("palette", "colors") else null
			if colors is PackedColorArray and colors.size() <= VoxelDocument.MAX_PALETTE_COLORS:
				materials = []
				for color in colors:
					materials.append(VoxelFrame.material(color))
		if VoxelDocument.valid_palette(materials) and not materials.is_empty():
			default_palette = _copy_palette(materials)
	default_palette_changed.emit()


## Saves the current palette as the default. Returns the error code.
func save_default_palette(path: String = DEFAULT_PALETTE_PATH) -> Error:
	if edit_busy():
		return ERR_BUSY
	var materials := get_palette()
	if materials.is_empty() or not VoxelDocument.valid_palette(materials):
		return ERR_INVALID_DATA
	var config := ConfigFile.new()
	config.set_value("palette", "materials", Array(materials))
	var error := config.save(path)
	if error == OK:
		default_palette = _copy_palette(materials)
		default_palette_changed.emit()
	return error


## Deletes the saved default palette and restores the built-in palette. Returns
## the error code.
func reset_default_palette(path: String = DEFAULT_PALETTE_PATH) -> Error:
	if edit_busy():
		return ERR_BUSY
	if FileAccess.file_exists(path):
		var error := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		if error != OK:
			return error
	default_palette = get_builtin_palette()
	default_palette_changed.emit()
	return OK


## Stores the last document path in the session file.
func remember_document(path: String, config_path: String = SESSION_PATH) -> void:
	var config := ConfigFile.new()
	config.load(config_path)
	config.set_value("files", "last_document", path)
	config.save(config_path)


## Removes the last document path from the session file.
func forget_document(config_path: String = SESSION_PATH) -> void:
	var config := ConfigFile.new()
	if config.load(config_path) != OK:
		return
	if config.has_section_key("files", "last_document"):
		config.erase_section_key("files", "last_document")
	config.save(config_path)


## Returns the stored last document path, or an empty string.
func last_document_path(config_path: String = SESSION_PATH) -> String:
	var config := ConfigFile.new()
	if config.load(config_path) != OK:
		return ""
	var path: Variant = config.get_value("files", "last_document", "")
	return path if path is String else ""


## Returns [code]true[/code] when the current scene is the application Main
## scene.
func is_app_session() -> bool:
	var tree := get_tree()
	return tree != null and tree.current_scene == tree.root.get_node_or_null("Main")


## Returns the file dialog filter for the supported image formats.
func get_image_file_filter() -> String:
	var patterns := PackedStringArray()
	for extension in IMAGE_EXTENSIONS:
		patterns.append("*." + extension)
	return ", ".join(patterns) + " ; Images"


## Loads an image file into [param image]. It handles DDS and KTX buffers and
## decompresses the result.
func load_image(path: String, image: Image) -> Error:
	var extension := path.get_extension().to_lower()
	var error: Error = OK
	if extension in ["dds", "ktx", "ktx2"]:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			return FileAccess.get_open_error()
		var bytes := file.get_buffer(file.get_length())
		file.close()
		error = image.load_dds_from_buffer(bytes) if extension == "dds" else image.load_ktx_from_buffer(bytes)
	else:
		error = image.load(path)
	if error != OK:
		return error
	if image.is_compressed():
		return image.decompress()
	return OK

## Returns [code]true[/code] when the cell is editable. An empty selection
## allows every cell.
func can_edit(cell: Vector3i) -> bool:
	if selection.is_empty():
		return true
	return selection.contains(cell)


## Clears the cell selection.
func clear_selection() -> void:
	if selection.is_empty():
		return
	selection.clear()
	selection_changed.emit()


## Erases every selected cell as one history action. A selection above 4096
## cells runs on the worker pool.
func erase_selection() -> void:
	if selection.is_empty() or edit_busy():
		return
	var edited_document := document
	var edited_frame := get_current_voxel_frame()
	_erase_edit = begin_edit()
	if _erase_edit == null:
		return
	var job := EraseJob.new()
	job.edited_frame = VoxelFrame.job_frame(edited_frame)
	job.selection_mask = selection.capture()
	# The erase is an edit, so the slice limits it like every other write.
	job.edit_context = _erase_edit.edit_context
	_erase_job = job
	var operation_id := begin_operation("Erasing selection", selection.count(), true, self, _interrupt_erase)
	_erase_operation_id = operation_id
	if selection.count() <= 4096:
		job.run()
	else:
		# Register the worker before the first await, so teardown can join it.
		_erase_jobs.append(job)
		await run_edit_job(job, operation_id, "Erase selection")
		_erase_jobs.erase(job)
	if _erase_job != job:
		return
	if document != edited_document or get_current_voxel_frame() != edited_frame:
		_interrupt_erase()
		return
	# Publish only the chunks the erase wrote. The erase edit owns the frame,
	# so an unchanged chunk stays as it is.
	edited_frame.apply_published(job.changed_chunks, job.edited_frame)
	document._bounds_dirty = true
	# Clear the handle, the job, and the operation before the history signals, so a
	# handler that opens a new erase keeps its own.
	var erase_tx := _erase_edit
	_erase_edit = null
	_erase_job = null
	_erase_operation_id = 0
	finish_edit(erase_tx, "Erase Selection")
	if not job.changed_chunks.is_empty():
		chunks_changed.emit(current_frame, job.changed_chunks)
	finish_operation(operation_id)


func _interrupt_erase() -> void:
	if _erase_job == null:
		return
	_erase_job.cancel()
	_erase_job = null
	# Clear the handle and capture the operation before the cancel signals, so a
	# handler that opens a new erase keeps it, and this cleanup finishes only the
	# captured operation.
	var tx := _erase_edit
	_erase_edit = null
	var operation_id := _erase_operation_id
	_erase_operation_id = 0
	cancel_edit(tx)
	finish_operation(operation_id)


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	# A cancellable operation owns Esc while it runs, so the key still cancels a job
	# whose tool a switch detached. Without one, the tools keep their own Esc.
	if cancel_activity():
		get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	for job in _erase_jobs:
		job.cancel()
		job.wait_for_worker()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		undo_redo.free()


## Moves to the next frame, wrapping at the end.
func next_frame() -> void:
	var n := document.frames.size()
	current_frame = (current_frame + 1) % n


## Moves to the previous frame, wrapping at the start.
func prev_frame() -> void:
	var n := document.frames.size()
	current_frame = (current_frame - 1) % n

## Returns the frame count.
func get_frame_count() -> int:
	return document.frames.size()


## Sets the smooth normals model option and records a history action.
func set_smooth_normals(value: bool) -> void:
	if edit_busy() or value == document.smooth_normals:
		return
	undo_redo.create_action("Set Smooth Normals")
	undo_redo.add_undo_method(_apply_smooth_normals.bind(document.smooth_normals))
	undo_redo.add_do_method(_apply_smooth_normals.bind(value))
	_commit_history(false)
	_apply_smooth_normals(value)


func _apply_smooth_normals(value: bool) -> void:
	document.smooth_normals = value
	model_settings_changed.emit()


## Returns one frame by index, or null when the index is out of range.
func get_voxel_frame(frame:int) -> VoxelFrame:
	if frame < 0 or frame >= document.frames.size():
		return null
	return document.frames[frame]

## Returns the current frame, or null when the index is out of range.
func get_current_voxel_frame() -> VoxelFrame:
	if current_frame < 0 or current_frame >= document.frames.size():
		return null
	return document.frames[current_frame]


## Adds an empty frame after the current frame and records a history action.
func add_frame() -> void:
	edit_context_changing.emit()
	is_playing = false
	var before := _frame_snapshot()
	document.add_frame()
	current_frame = document.frames.size() - 1
	_record_frame_action("Add Frame", before, _frame_snapshot())


## Duplicates the current frame and records a history action.
func duplicate_frame() -> void:
	edit_context_changing.emit()
	is_playing = false
	var before := _frame_snapshot()
	document.duplicate_frame(current_frame)
	current_frame += 1
	_record_frame_action("Duplicate Frame", before, _frame_snapshot())


## Deletes the current frame. The last remaining frame is kept.
func delete_frame() -> void:
	if document.frames.size() <= 1:
		return
	edit_context_changing.emit()
	is_playing = false
	var before := _frame_snapshot()
	document.remove_frame(current_frame)
	if current_frame >= document.frames.size():
		current_frame = document.frames.size() - 1
	_record_frame_action("Delete Frame", before, _frame_snapshot())


## Moves one frame to a new index and records a history action.
func move_frame(from: int, to: int) -> void:
	var f := clampi(from, 0, document.frames.size() - 1)
	var t := clampi(to, 0, document.frames.size() - 1)
	if f == t:
		return
	edit_context_changing.emit()
	var before := _frame_snapshot()
	document.move_frame(f, t)
	if current_frame == f:
		current_frame = t
	elif f < current_frame and current_frame <= t:
		current_frame -= 1
	elif t <= current_frame and current_frame < f:
		current_frame += 1
	_record_frame_action("Move Frame", before, _frame_snapshot())


func _frame_snapshot() -> Dictionary:
	return {
		"frames": document.frames.duplicate(),
		"ranges": _tag_ranges(),
		"current": current_frame,
	}


func _record_frame_action(action_name: String, before: Dictionary, after: Dictionary) -> void:
	undo_redo.create_action(action_name)
	undo_redo.add_undo_method(_restore_frame_layout.bind(before["frames"], before["ranges"], before["current"]))
	undo_redo.add_do_method(_restore_frame_layout.bind(after["frames"], after["ranges"], after["current"]))
	_commit_history(false)
	_restore_frame_layout(after["frames"], after["ranges"], after["current"])


func _restore_frame_layout(frames: Array[VoxelFrame], ranges: Array[Vector2i], current: int) -> void:
	edit_context_changing.emit()
	document.frames = frames
	_set_tag_ranges(ranges)
	document._bounds_dirty = true
	current_frame = clampi(current, 0, frames.size() - 1)
	frames_changed.emit()


func _tag_ranges() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for tag in document.tags:
		out.append(Vector2i(tag.from, tag.to))
	return out


func _set_tag_ranges(ranges: Array[Vector2i]) -> void:
	for i in mini(ranges.size(), document.tags.size()):
		var tag := document.tags[i]
		tag.from = ranges[i].x
		tag.to = ranges[i].y


## Sets a frame duration in milliseconds and records a history action.
func set_frame_delay(index: int, ms: int) -> void:
	if index < 0 or index >= document.frames.size():
		return
	var frame := document.frames[index]
	if frame.delay_ms == ms:
		return
	undo_redo.create_action("Set Frame Delay")
	undo_redo.add_undo_method(_apply_frame_delay.bind(index, frame.delay_ms))
	undo_redo.add_do_method(_apply_frame_delay.bind(index, ms))
	_commit_history(false)
	_apply_frame_delay(index, ms)


func _apply_frame_delay(index: int, ms: int) -> void:
	if index < 0 or index >= document.frames.size():
		return
	document.frames[index].delay_ms = ms
	frame_changed.emit()


## Adds an animation tag and records a history action. A negative [param to]
## means the last frame. The frame range is inclusive.
func add_tag(tag_name: String, from: int = 0, to: int = -1) -> void:
	var end := to
	if to < 0:
		end = document.frames.size() - 1
	var index := document.tags.size()
	var tag := AnimationTag.new()
	tag.name = tag_name
	tag.from = clampi(from, 0, document.frames.size() - 1)
	tag.to = clampi(end, tag.from, document.frames.size() - 1)
	var prev_active := active_tag
	undo_redo.create_action("Add Tag")
	undo_redo.add_undo_method(_apply_tag_removed.bind(index, prev_active))
	undo_redo.add_do_method(_apply_tag_inserted.bind(index, tag, index))
	_commit_history(false)
	_apply_tag_inserted(index, tag, index)


func _apply_tag_inserted(index: int, tag: AnimationTag, active: int) -> void:
	document.tags.insert(index, tag)
	active_tag = active
	frames_changed.emit()


func _apply_tag_removed(index: int, active: int) -> void:
	document.tags.remove_at(index)
	active_tag = active
	frames_changed.emit()


## Returns the active tag, or null when no tag is active.
func get_active_tag() -> AnimationTag:
	return document.get_tag(active_tag)
	
## Returns one tag by index, or null when the index is out of range.
func get_tag(i: int) -> AnimationTag:
	return document.get_tag(i)

## Removes the active tag. The last remaining tag is kept. An empty tag
## selection is refused: there is no tag to remove.
func remove_tag() -> void:
	if document.tags.size() <= 1 or active_tag < 0 or active_tag >= document.tags.size():
		return
	var index := active_tag
	var tag := document.get_tag(index)
	var new_active := clampi(index, -1, document.tags.size() - 2)
	undo_redo.create_action("Remove Tag")
	undo_redo.add_undo_method(_apply_tag_inserted.bind(index, tag, index))
	undo_redo.add_do_method(_apply_tag_removed.bind(index, new_active))
	_commit_history(false)
	_apply_tag_removed(index, new_active)

## Sets the active tag frame range. [param from] and [param to] are inclusive.
## Set [param record_history] to record one history action.
func set_tag_range(from: int, to: int, record_history: bool = true) -> void:
	var tag := get_active_tag()
	if tag == null:
		return
	var last := document.frames.size() - 1
	var new_from := clampi(from, 0, last)
	var new_to := clampi(to, new_from, last)
	if tag.from == new_from and tag.to == new_to:
		return
	var index := active_tag
	var previous_range := Vector2i(tag.from, tag.to)
	_apply_tag_range(index, new_from, new_to)
	if record_history:
		commit_tag_range(index, previous_range)


## Records one history action for a tag range change.
func commit_tag_range(index: int, previous_range: Vector2i) -> void:
	var tag := document.get_tag(index)
	if tag == null or previous_range == Vector2i(tag.from, tag.to):
		return
	undo_redo.create_action("Set Tag Range")
	undo_redo.add_undo_method(_apply_tag_range.bind(index, previous_range.x, previous_range.y))
	undo_redo.add_do_method(_apply_tag_range.bind(index, tag.from, tag.to))
	_commit_history(false)


func _apply_tag_range(index: int, from: int, to: int) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	tag.from = from
	tag.to = to
	if is_playing:
		current_frame = clampi(current_frame, playback.first_frame(), playback.last_frame())
	tag_changed.emit()


## Sets a tag loop mode and records a history action. See
## [enum AnimationTag.LoopMode] for the values.
func set_tag_loop_mode(index: int, mode: int) -> void:
	var tag := document.get_tag(index)
	if tag == null or tag.loop_mode == mode:
		return
	undo_redo.create_action("Set Loop Mode")
	undo_redo.add_undo_method(_apply_tag_loop_mode.bind(index, tag.loop_mode))
	undo_redo.add_do_method(_apply_tag_loop_mode.bind(index, mode))
	_commit_history(false)
	_apply_tag_loop_mode(index, mode)


func _apply_tag_loop_mode(index: int, mode: int) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	tag.loop_mode = mode as AnimationTag.LoopMode
	tag_changed.emit()


## Sets a tag repeat count and records a history action. Zero means continuous
## playback.
func set_tag_repeats(index: int, value: int) -> void:
	var tag := document.get_tag(index)
	if tag == null or tag.repeats == value:
		return
	undo_redo.create_action("Set Repeats")
	undo_redo.add_undo_method(_apply_tag_repeats.bind(index, tag.repeats))
	undo_redo.add_do_method(_apply_tag_repeats.bind(index, value))
	_commit_history(false)
	_apply_tag_repeats(index, value)


func _apply_tag_repeats(index: int, value: int) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	tag.repeats = value
	tag_changed.emit()


## Sets a tag name and records a history action.
func set_tag_name(index: int, tag_name: String) -> void:
	var tag := document.get_tag(index)
	if tag == null or tag.name == tag_name:
		return
	undo_redo.create_action("Set Tag Name")
	undo_redo.add_undo_method(_apply_tag_name.bind(index, tag.name))
	undo_redo.add_do_method(_apply_tag_name.bind(index, tag_name))
	_commit_history(false)
	_apply_tag_name(index, tag_name)


func _apply_tag_name(index: int, tag_name: String) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	tag.name = tag_name
	tag_changed.emit()


## Moves to the first frame of the active tag. It moves to frame zero when no
## tag is active.
func to_start() -> void:
	var tag := get_active_tag()
	if tag:
		current_frame = maxi(tag.from, 0)
	else:
		current_frame = 0

## Moves to the last frame of the active tag. It moves to the last frame when
## no tag is active.
func to_end() -> void:
	var tag = get_active_tag()
	if tag:
		current_frame = mini(tag.to, document.frames.size() - 1)
	else:
		current_frame = document.frames.size() - 1
