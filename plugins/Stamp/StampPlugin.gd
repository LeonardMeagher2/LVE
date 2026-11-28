extends VoxelPlugin


const TOOL_ID := "stamp"
const INLINE_SOURCE_LIMIT := 4096
const StampCopyJob := preload("res://plugins/brush/StampCopyJob.gd")

@onready var _toolbar := preload("./Toolbar.tscn").instantiate()
@onready var _options := preload("./Options.tscn").instantiate()
@onready var _frame_panel := preload("./FramePanel.tscn").instantiate()
@onready var _tool := preload("./StampTool.tscn").instantiate()
var _settings := preload("./StampSettings.tres")
var _source_job: VoxelFrame.EditJob
var _operation_id := 0
var _file_document: VoxelDocument
var _file_path := ""
var _frame_index := -1
var _source_label := "No stamp source"
var _center_on_cursor := false
var _selection_source_frame: VoxelFrame
var _selection_source_mask := {}
var _selection_label := ""
var _pending_recenter := false
var _state_document: VoxelDocument
var _shutting_down := false


func _ready() -> void:
	name = "StampPlugin"
	_options.file_chosen.connect(_on_file_chosen)
	_options.selection_requested.connect(use_current_selection)
	_options.center_changed.connect(_on_center_changed)
	_options.clear_requested.connect(clear_source)
	_frame_panel.frame_selected.connect(_on_frame_selected)
	_state_document = State.document
	State.document_deactivating.connect(_save_state)
	State.document_changed.connect(_restore_state)
	add_tool_bar_item(_toolbar, null, TOOL_ID)
	add_option_bar_item(_options)
	activate_tool()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	for node in [_toolbar, _options, _frame_panel, _tool]:
		if is_instance_valid(node):
			node.free()


func _exit_tree() -> void:
	if State.document_deactivating.is_connected(_save_state):
		State.document_deactivating.disconnect(_save_state)
	if State.document_changed.is_connected(_restore_state):
		State.document_changed.disconnect(_restore_state)
	_shutting_down = true
	_unmount_frame_panel()
	if _source_job:
		_source_job.cancel()
		_source_job.wait_for_worker()
		_source_job = null
	State.finish_operation(_operation_id)
	_operation_id = 0


func activate_tool() -> void:
	if not _toolbar.button_pressed:
		_toolbar.button_pressed = true
		return
	add_editor_node(_tool)
	add_option_bar_item(_options)
	_mount_frame_panel()
	_sync_options()


func _end_deactivation() -> void:
	_tool.finish_on_switch()
	remove_editor_node(_tool)
	remove_option_bar_item(_options)
	_unmount_frame_panel()


func open_source_file(path: String) -> void:
	if _shutting_down or _source_job:
		return
	var document := VoxelDocument.load_file(path)
	if document == null:
		_options.set_error("Cannot read this LVE file.")
		return
	_file_document = document
	_file_path = path
	_frame_index = -1
	_selection_source_frame = null
	_selection_source_mask = {}
	_selection_label = ""
	_pending_recenter = false
	_settings.clear_stamp()
	_options.set_error("")
	_source_label = "File: %s" % path.get_file()
	if not _toolbar.button_pressed:
		_toolbar.button_pressed = true
	else:
		_mount_frame_panel()
	_frame_panel.show_frames(document.active_layer().frames)
	if not document.active_layer().frames.is_empty():
		_frame_panel.select_frame(0)
		_on_frame_selected(0)
	_sync_options()


func use_current_selection() -> void:
	if _shutting_down or _source_job:
		return
	var document := State.document
	var frame := State.get_current_voxel_frame()
	if frame == null or frame.count() == 0:
		return
	var mask := State.selection.capture()
	if mask.is_empty():
		return
	_options.set_error("")
	if _frame_panel.is_node_ready():
		_frame_panel.clear_selection()
	_selection_source_frame = frame.copy_frame()
	_selection_source_mask = mask.duplicate()
	_selection_label = "Selection: %d cells" % mask.size()
	State.clear_selection()
	_prepare_stamp(_selection_source_frame, _selection_source_mask, _selection_label, -1, document, frame)


func _on_file_chosen(path: String) -> void:
	open_source_file(path)


func clear_source() -> void:
	if _source_job:
		return
	_clear_runtime_state()
	_options.set_error("")
	_frame_panel.clear()
	_unmount_frame_panel()
	_sync_options()


func _on_center_changed(on: bool) -> void:
	if on == _center_on_cursor:
		return
	_center_on_cursor = on
	if _source_job:
		_pending_recenter = true
		return
	_recenter_current()


func _recenter_current() -> void:
	if _source_job:
		return
	if _frame_index >= 0 and _file_document != null and _frame_index < _file_document.active_layer().frames.size():
		var label := "File: %s / Frame %d" % [_file_path.get_file(), _frame_index + 1]
		_prepare_stamp(_file_document.active_layer().frames[_frame_index], {}, label, _frame_index)
	elif _selection_source_frame != null and not _selection_source_mask.is_empty():
		_prepare_stamp(_selection_source_frame, _selection_source_mask, _selection_label, -1)


func _on_frame_selected(index: int) -> void:
	if _source_job or _file_document == null:
		return
	if index < 0 or index >= _file_document.active_layer().frames.size():
		return
	_options.set_error("")
	var label := "File: %s / Frame %d" % [_file_path.get_file(), index + 1]
	_prepare_stamp(_file_document.active_layer().frames[index], {}, label, index)


func _prepare_stamp(source_frame: VoxelFrame, mask: Dictionary, label: String, frame_index: int, source_document: VoxelDocument = null, live_frame: VoxelFrame = null) -> void:
	if _source_job:
		return
	var previous_label := _source_label
	var previous_frame := _frame_index
	_frame_index = frame_index
	_source_label = "Preparing stamp..."
	if source_frame.count() == 0:
		_settings.clear_stamp()
		_source_label = label
		if frame_index >= 0 and _frame_panel.is_node_ready():
			_frame_panel.select_frame(frame_index)
		_sync_options()
		return
	var job := StampCopyJob.new()
	job.source_frame = source_frame.copy_frame()
	job.selection_mask = mask
	job.center_pattern = _center_on_cursor
	_source_job = job
	_sync_options()
	var source_count := mask.size() if not mask.is_empty() else source_frame.count()
	var operation_id := State.begin_operation("Preparing stamp", source_count, true, self)
	_operation_id = operation_id
	if source_count <= INLINE_SOURCE_LIMIT:
		job.run()
	else:
		await State.run_edit_job(job, operation_id, "Stamp source", func() -> void:
			if _shutting_down:
				job.cancel()
			elif source_document != null and (State.document != source_document or State.get_current_voxel_frame() != live_frame):
				job.cancel()
		)
	State.finish_operation(operation_id)
	if _operation_id == operation_id:
		_operation_id = 0
	if _shutting_down or not is_inside_tree():
		_source_job = null
		return
	var installed := _source_job == job and job.checkpoint(0) and _source_is_current(source_document, live_frame)
	if _source_job == job:
		_source_job = null
	if installed:
		if job.pattern.is_empty():
			_settings.clear_stamp()
		else:
			_settings.use_stamp(job.pattern, job.pattern_materials)
		_source_label = label
		_frame_index = frame_index
		if frame_index >= 0 and _frame_panel.is_node_ready():
			_frame_panel.select_frame(frame_index)
	else:
		_source_label = previous_label
		_frame_index = previous_frame
		if _frame_panel.is_node_ready():
			if previous_frame >= 0:
				_frame_panel.select_frame(previous_frame)
			else:
				_frame_panel.clear_selection()
	_sync_options()
	if _pending_recenter and not _source_job:
		_pending_recenter = false
		_recenter_current()


func _source_is_current(source_document: VoxelDocument, live_frame: VoxelFrame) -> bool:
	if source_document == null:
		return true
	return State.document == source_document and State.get_current_voxel_frame() == live_frame


func _capture_state() -> Dictionary:
	return {
		"file_document": _file_document,
		"file_path": _file_path,
		"frame_index": _frame_index,
		"selection_frame": _selection_source_frame,
		"selection_mask": _selection_source_mask,
		"selection_label": _selection_label,
		"center_on_cursor": _center_on_cursor,
		"source_label": _source_label,
		"pattern": _settings.stamp_pattern,
		"pattern_materials": _settings.stamp_material_pattern,
	}


func _save_state() -> void:
	if _state_document != null:
		_state_document.edit_stamp = _capture_state()


func _restore_state() -> void:
	_state_document = State.document
	_clear_runtime_state()
	_center_on_cursor = false
	_options.set_error("")
	if _state_document == null:
		_sync_options()
		return
	var state: Variant = _state_document.edit_stamp
	if not state is Dictionary or state.is_empty():
		_frame_panel.clear()
		_unmount_frame_panel()
		_sync_options()
		return
	_file_document = state.get("file_document")
	_file_path = String(state.get("file_path", ""))
	_frame_index = int(state.get("frame_index", -1))
	_selection_source_frame = state.get("selection_frame")
	_selection_source_mask = state.get("selection_mask", {})
	_selection_label = String(state.get("selection_label", ""))
	_center_on_cursor = bool(state.get("center_on_cursor", false))
	_source_label = String(state.get("source_label", "No stamp source"))
	var pattern: Variant = state.get("pattern")
	var materials: Variant = state.get("pattern_materials")
	if pattern is Dictionary and materials is Dictionary and not pattern.is_empty():
		_settings.use_stamp(pattern, materials)
	else:
		_settings.clear_stamp()
	_options.set_center(_center_on_cursor)
	if _file_document != null:
		_frame_panel.show_frames(_file_document.active_layer().frames)
		if _frame_index >= 0:
			_frame_panel.select_frame(_frame_index)
		if _toolbar.button_pressed:
			_mount_frame_panel()
	else:
		_frame_panel.clear()
		_unmount_frame_panel()
	_sync_options()


func _clear_runtime_state() -> void:
	_file_document = null
	_file_path = ""
	_frame_index = -1
	_selection_source_frame = null
	_selection_source_mask = {}
	_selection_label = ""
	_source_label = "No stamp source"
	_pending_recenter = false
	_settings.clear_stamp()


func _has_source() -> bool:
	return _file_document != null or _selection_source_frame != null or not _settings.stamp_pattern.is_empty()


func _mount_frame_panel() -> void:
	if _file_document == null or context == null or context.viewport == null:
		return
	if _frame_panel.get_parent() != context.viewport:
		_safe_add(context.viewport, _frame_panel)
	_frame_panel.visible = true


func _unmount_frame_panel() -> void:
	if context == null or context.viewport == null:
		return
	if _frame_panel.get_parent() == context.viewport:
		context.viewport.remove_child(_frame_panel)


func _sync_options() -> void:
	if is_instance_valid(_options) and _options.is_node_ready():
		_options.set_source(_source_label)
		_options.set_center(_center_on_cursor)
		_options.set_clear_enabled(_has_source())
		_options.set_busy(_source_job != null)
	if is_instance_valid(_frame_panel) and _frame_panel.is_node_ready():
		_frame_panel.set_busy(_source_job != null)
