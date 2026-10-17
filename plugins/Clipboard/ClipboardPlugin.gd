extends VoxelPlugin

const CLIPBOARD_PREFIX := '{"voxel_voxels":'
# One clipboard record holds the cell and its nine material floats.
const VOXEL_RECORD_SIZE := 3 + VoxelFrame.MATERIAL_STRIDE

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

class ClipboardCopyJob extends BrushToolSettings.CopyJob:
	var text := ""
	var selection_pattern := {}
	var cut_source := false
	var changed_chunks: Array[Vector3i] = []

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

class ClipboardImportJob extends VoxelFrame.EditJob:
	var text := ""
	var pattern := {}
	var pattern_materials := {}
	var selection_pattern := {}

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
	for plugin_name in ["BrushPlugin", "SelectionPlugin", "TransformPlugin"]:
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


func copy_voxels() -> void:
	_copy_voxels(false)


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
	_copy_job = job
	var source_count := job.selection_mask.size() if not job.selection_mask.is_empty() else frame.count()
	var operation_id := State.begin_operation("Cutting voxels" if cut_source else "Copying voxels", source_count, true, self)
	if source_count <= 4096:
		job.run()
	else:
		job.worker_task_id = WorkerThreadPool.add_task(job.run, true, "Copy voxels")
		while not WorkerThreadPool.is_task_completed(job.worker_task_id):
			if State.document != document or State.get_current_voxel_frame() != frame:
				job.cancel()
			_report_job(operation_id, job)
			await State.get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
	_copy_job = null
	if State.document == document and State.get_current_voxel_frame() == frame and job.checkpoint(0) and not job.pattern.is_empty():
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
			State.begin_stroke()
			frame.restore(job.source_frame.capture())
			State.document._bounds_dirty = true
			State.clear_selection()
			State.end_stroke("Cut")
			if not job.changed_chunks.is_empty():
				State.chunks_changed.emit(State.current_frame, job.changed_chunks)
	State.finish_operation(operation_id)
	_sync_buttons()


func delete_voxels() -> void:
	if State.edit_busy() or State.selection.is_empty():
		return
	State.edit_context_changing.emit()
	State.erase_selection()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and cancel_paste():
		get_viewport().set_input_as_handled()
		return


func cancel_paste() -> bool:
	if _import_job:
		_import_job.cancel()
		return true
	if _paste_tool._active:
		_paste_tool._cancel_edit()
		return true
	return false


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
		job.worker_task_id = WorkerThreadPool.add_task(job.run, true, "Read voxel clipboard")
		while not WorkerThreadPool.is_task_completed(job.worker_task_id):
			if State.document != document or State.get_current_voxel_frame() != frame:
				job.cancel()
			_report_job(operation_id, job)
			await State.get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
		_import_job = null
		State.finish_operation(operation_id)
		if State.document != document or State.get_current_voxel_frame() != frame or not job.checkpoint(0) or job.pattern.is_empty():
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


func _report_job(operation_id: int, job: VoxelFrame.EditJob) -> void:
	var progress := job.progress()
	State.update_operation(operation_id, progress[1], progress[2], progress[0])


func _on_paste_finished() -> void:
	if not _shutting_down:
		_remove_paste_preview.call_deferred()
	_sync_buttons()


func _remove_paste_preview() -> void:
	if not _paste_tool._active:
		remove_editor_node(_paste_tool)


func _exit_tree() -> void:
	_shutting_down = true
	for job in [_copy_job, _import_job]:
		if job:
			job.cancel()
			if job.worker_task_id != -1:
				WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
