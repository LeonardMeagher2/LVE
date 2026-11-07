extends VoxelPlugin

## The clipboard plugin.
##
## It copies voxels to the system clipboard as JSON, and it pastes them with
## the paste tool. It also cuts and deletes the selection. The clipboard text
## holds the cells and their full materials.

## The prefix that marks a voxel clipboard record.
const CLIPBOARD_PREFIX := '{"voxel_voxels":'
# One clipboard record holds the cell and its nine material floats.
## The field count of one clipboard voxel record.
const VOXEL_RECORD_SIZE := 3 + VoxelFrame.MATERIAL_STRIDE
## The largest copy or cut source that runs on the main thread.
const INLINE_EDIT_LIMIT := 4096

@onready var _options := preload("./Options.tscn").instantiate()
@onready var _paste_tool := preload("./PasteTool.tscn").instantiate()
var _button_group := preload("res://plugins/ToolBarButtonGroup.tres")
var _pattern := {}
var _selection_pattern := {}
var _material_pattern := {}
var _center := Vector3i.ZERO
var _clipboard_text := ""
var _copy_job: ClipboardCopyJob
var _import_job: ClipboardImportJob
var _clipboard_poll_ms := 0
var _has_clipboard_voxels := false
var _shutting_down := false

## One cancellable copy or cut job.
##
## The job builds the clipboard JSON from a frame snapshot. A cut also erases
## the source cells. [method BrushToolSettings.CopyJob.run] is the base worker
## body.
class ClipboardCopyJob extends BrushToolSettings.CopyJob:
	## The clipboard JSON text.
	var text := ""
	## The selected offsets relative to the pattern center.
	var selection_pattern := {}
	## Whether the job also erases the source cells.
	var cut_source := false
	## The chunk locations that a cut changed.
	var changed_chunks: Array[Vector3i] = []

	## Builds the clipboard text and applies a cut. This is the worker body.
	func run() -> void:
		super.run()
		if not checkpoint(0):
			return
		stage("Writing voxel clipboard", pattern.size())
		var records := []
		for cell_position: Vector3i in pattern:
			var cell_material: PackedFloat32Array = pattern_materials[cell_position]
			var record := [cell_position.x, cell_position.y, cell_position.z]
			for value in cell_material:
				record.append(value)
			records.append(record)
			if records.size() % 4096 == 0 and not checkpoint(records.size()):
				return
		stage("Writing clipboard selection", selection_mask.size())
		var selected_records := []
		for cell_position: Vector3i in selection_mask:
			var offset := cell_position - center
			selection_pattern[offset] = true
			selected_records.append([offset.x, offset.y, offset.z])
			if selected_records.size() % 4096 == 0 and not checkpoint(selected_records.size()):
				return
		text = JSON.stringify({"voxel_voxels": records, "voxel_selection": selected_records}, "", false, true)
		if cut_source and checkpoint(0):
			stage("Cutting voxels", _colors.size())
			var changes := {}
			for cell_position in _colors:
				changes[cell_position] = VoxelFrame.material(Color.TRANSPARENT)
				if changes.size() % 4096 == 0 and not checkpoint(changes.size()):
					return
			changed_chunks = source_frame.set_cells(changes, self)

## One cancellable clipboard import job.
##
## The job parses the clipboard JSON into a pattern. It rejects a malformed
## record. [method VoxelFrame.EditJob.run] is the worker body.
class ClipboardImportJob extends VoxelFrame.EditJob:
	## The clipboard JSON text to parse.
	var text := ""
	## The parsed colors, keyed by offset from the pattern center.
	var pattern := {}
	## The parsed full materials, keyed by offset from the pattern center.
	var pattern_materials := {}
	## The parsed selection offsets.
	var selection_pattern := {}

	## Parses the clipboard text. This is the worker body.
	func run() -> void:
		stage("Reading voxel clipboard", -1)
		var data = JSON.parse_string(text)
		if not data is Dictionary or not data.get("voxel_voxels") is Array:
			return
		stage("Reading voxel clipboard", data.voxel_voxels.size())
		var completed := 0
		for record in data.voxel_voxels:
			if not record is Array or record.size() != VOXEL_RECORD_SIZE:
				pattern = {}
				pattern_materials = {}
				return
			for value in record:
				if not (value is float or value is int):
					pattern = {}
					pattern_materials = {}
					return
			var cell_position := Vector3i(int(record[0]), int(record[1]), int(record[2]))
			var cell_material := PackedFloat32Array()
			for index in range(3, VOXEL_RECORD_SIZE):
				var value := float(record[index])
				if value < 0.0 or value > 1.0:
					pattern = {}
					pattern_materials = {}
					return
				cell_material.append(value)
			pattern[cell_position] = VoxelFrame.material_color(cell_material)
			pattern_materials[cell_position] = cell_material
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return
		var selected_records = data.get("voxel_selection", [])
		if not selected_records is Array:
			pattern = {}
			return
		stage("Reading clipboard selection", selected_records.size())
		completed = 0
		for record in selected_records:
			if not record is Array or record.size() != 3:
				pattern = {}
				return
			for value in record:
				if not (value is float or value is int):
					pattern = {}
					return
			selection_pattern[Vector3i(int(record[0]), int(record[1]), int(record[2]))] = true
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return


func _ready() -> void:
	name = "ClipboardPlugin"
	_options.get_node("Cut").pressed.connect(cut_voxels)
	_options.get_node("Copy").pressed.connect(copy_voxels)
	_options.get_node("Paste").pressed.connect(paste_voxels)
	_options.get_node("Delete").pressed.connect(delete_voxels)
	_options.get_node("CancelPaste").pressed.connect(cancel_paste)
	_paste_tool.finished.connect(_on_paste_finished)
	for button in _button_group.get_buttons():
		button.toggled.connect(_on_tool_toggled)
	State.cells_changed.connect(_on_cells_changed)
	State.chunks_changed.connect(_on_cells_changed)
	State.selection_changed.connect(_sync_buttons)
	State.frame_changed.connect(_sync_buttons)
	State.activity_changed.connect(_sync_buttons)
	_sync_options.call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node in [_options, _paste_tool]:
			if is_instance_valid(node):
				node.free()


func _on_tool_toggled(on: bool) -> void:
	if on and _paste_tool.is_inside_tree():
		_paste_tool._cancel_edit()
	_sync_options.call_deferred()


func _sync_options() -> void:
	var target: Control
	var pressed_button := _button_group.get_pressed_button()
	for plugin_name in ["BrushPlugin", "PaintPlugin", "SelectionPlugin", "TransformPlugin"]:
		var plugin := get_node("/root/" + plugin_name)
		if plugin._toolbar == pressed_button:
			target = plugin._options
			break
	if target:
		_safe_add(target, _options)
	elif _options.get_parent():
		_options.get_parent().remove_child(_options)
	_sync_buttons()


func _sync_buttons() -> void:
	var frame := State.get_current_voxel_frame()
	var busy := State.edit_busy()
	_options.get_node("Copy").disabled = busy or frame == null or frame.count() == 0
	_options.get_node("Cut").disabled = _options.get_node("Copy").disabled
	_options.get_node("Paste").disabled = busy or not _has_clipboard_voxels
	_options.get_node("Delete").disabled = busy or State.selection.is_empty()
	_options.get_node("CancelPaste").visible = _import_job != null or _paste_tool._active


func _on_cells_changed(_frame: int, _affected: Array[Vector3i]) -> void:
	_sync_buttons()


func _process(_delta: float) -> void:
	if _options.is_inside_tree() and Time.get_ticks_msec() >= _clipboard_poll_ms:
		_clipboard_poll_ms = Time.get_ticks_msec() + 500
		_has_clipboard_voxels = _read_clipboard().begins_with(CLIPBOARD_PREFIX)
		_sync_buttons()


func _read_clipboard() -> String:
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		return DisplayServer.clipboard_get()
	return _clipboard_text


## Copies the selection, or the whole frame, to the clipboard.
func copy_voxels() -> void:
	_copy_voxels(false)


## Copies the selection, or the whole frame, to the clipboard and erases it.
func cut_voxels() -> void:
	_copy_voxels(true)


func _copy_voxels(cut_source: bool) -> void:
	if State.edit_busy() or _copy_job:
		return
	State.edit_context_changing.emit()
	var document := State.document
	var frame := State.get_current_voxel_frame()
	var job := ClipboardCopyJob.new()
	job.source_frame = frame.copy_frame()
	job.selection_mask = State.selection.capture()
	job.cut_source = cut_source
	# A cut is an edit, so the slice limits its writes. The document size does
	# not: a selected voxel outside the size can still be cut.
	job.edit_context = State.drawing_context()
	if cut_source:
		job.edit_context = job.edit_context.duplicate()
		job.edit_context.bounded_axes = 0
	_copy_job = job
	var source_count := job.selection_mask.size() if not job.selection_mask.is_empty() else frame.count()
	var operation_id := State.begin_operation("Cutting voxels" if cut_source else "Copying voxels", source_count, true, self)
	if source_count <= INLINE_EDIT_LIMIT:
		job.run()
	else:
		# The runner pumps the progress and joins the worker. The frame check
		# cancels the job when its document or frame changes.
		await State.run_edit_job(job, operation_id, "Copy voxels", func() -> void:
			if State.document != document or State.get_current_voxel_frame() != frame:
				job.cancel()
		)
	# A shutdown or a newer job owns the fields now, so this job cannot install.
	if _copy_job != job:
		State.finish_operation(operation_id)
		return
	_copy_job = null
	if not _shutting_down and State.document == document and State.get_current_voxel_frame() == frame and job.checkpoint(0) and not job.pattern.is_empty():
		_pattern = job.pattern
		_pattern.make_read_only()
		_selection_pattern = job.selection_pattern
		_material_pattern = job.pattern_materials
		_material_pattern.make_read_only()
		_center = job.center
		_clipboard_text = job.text
		_has_clipboard_voxels = true
		if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
			DisplayServer.clipboard_set(job.text)
		if cut_source:
			var tx := State.begin_edit()
			if tx != null:
				frame.apply_published(job.changed_chunks, job.source_frame)
				State.document._bounds_dirty = true
				State.clear_selection()
				State.finish_edit(tx, "Cut")
				if not job.changed_chunks.is_empty():
					State.chunks_changed.emit(State.current_frame, job.changed_chunks)
	State.finish_operation(operation_id)
	_sync_buttons()


## Erases the selection as one history action.
func delete_voxels() -> void:
	if State.edit_busy() or State.selection.is_empty():
		return
	State.edit_context_changing.emit()
	State.erase_selection()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and cancel_paste():
		get_viewport().set_input_as_handled()
		return


## Cancels a running paste. Returns [code]true[/code] when a paste was canceled.
func cancel_paste() -> bool:
	if _import_job:
		_import_job.cancel()
		return true
	if _paste_tool._active:
		_paste_tool._cancel_edit()
		return true
	return false


## Starts a paste from the clipboard. It parses the clipboard text when it
## changed, then places the paste tool.
func paste_voxels() -> void:
	if State.edit_busy() or _import_job:
		return
	var text := _read_clipboard()
	if not text.begins_with(CLIPBOARD_PREFIX):
		return
	State.edit_context_changing.emit()
	State.stop()
	if text != _clipboard_text or _pattern.is_empty():
		var document := State.document
		var frame := State.get_current_voxel_frame()
		var job := ClipboardImportJob.new()
		job.text = text
		_import_job = job
		var operation_id := State.begin_operation("Reading voxel clipboard", -1, true, self)
		# The runner pumps the progress and joins the worker. The frame check
		# cancels the job when its document or frame changes.
		await State.run_edit_job(job, operation_id, "Read voxel clipboard", func() -> void:
			if State.document != document or State.get_current_voxel_frame() != frame:
				job.cancel()
		)
		# A shutdown or a newer job owns the fields now, so this job cannot start
		# a paste.
		if _import_job != job:
			State.finish_operation(operation_id)
			return
		_import_job = null
		State.finish_operation(operation_id)
		if _shutting_down or State.document != document or State.get_current_voxel_frame() != frame or not job.checkpoint(0) or job.pattern.is_empty():
			return
		_pattern = job.pattern
		_pattern.make_read_only()
		_selection_pattern = job.selection_pattern
		_material_pattern = job.pattern_materials
		_material_pattern.make_read_only()
		_center = Vector3i.ZERO
		_clipboard_text = text
	add_editor_node(_paste_tool)
	_paste_tool.begin_paste(_pattern, _selection_pattern, _center, _material_pattern)


func _on_paste_finished() -> void:
	if not _shutting_down:
		_remove_paste_preview.call_deferred()
	_sync_buttons()


func _remove_paste_preview() -> void:
	if not _paste_tool._active:
		remove_editor_node(_paste_tool)


func _exit_tree() -> void:
	_shutting_down = true
	# The runner owns the join and retires the task id. This wait is the same
	# exactly-once join, so a second wait never touches a disposed task.
	for job in [_copy_job, _import_job]:
		if job:
			job.cancel()
			job.wait_for_worker()
