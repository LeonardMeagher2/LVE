extends VoxelPlugin

## The primitive plugin.
##
## It owns three tools: Box, Ellipsoid, and Cylinder. It also exposes the one
## commit path that the mouse tools and the MCP server call, so both paths share
## the SDF evaluator, the undo scope, and the publication rules.

## The stable id of the primitive toolbar. The persisted active tool uses it.
const TOOL_ID := "primitive"
## The work below which the shape runs inline. A larger shape uses a worker.
const INLINE_CELLS := 4096

const PrimitiveField := preload("res://Globals/State/Tools/PrimitiveField.gd")
const PrimitiveJob := preload("res://Globals/State/Tools/PrimitiveJob.gd")

@onready var _toolbar := preload("./Toolbar.tscn").instantiate()
@onready var _options := preload("./Options.tscn").instantiate()
@onready var _box_tool := preload("./BoxTool.tscn").instantiate()
@onready var _ellipsoid_tool := preload("./EllipsoidTool.tscn").instantiate()
@onready var _cylinder_tool := preload("./CylinderTool.tscn").instantiate()
var _settings := preload("./PrimitiveSettings.tres")
var _active_tool: Node3D = null
var _active := false
var _active_job: PrimitiveJob = null
var _active_tx: VoxelEditTransaction = null


func _ready() -> void:
	name = "PrimitivePlugin"
	if not State.edit_context_changing.is_connected(_on_edit_context_changing):
		State.edit_context_changing.connect(_on_edit_context_changing)
	if not _settings.tool_changed.is_connected(_on_tool_changed):
		_settings.tool_changed.connect(_on_tool_changed)
	add_tool_bar_item(_toolbar, _settings, TOOL_ID)


func _exit_tree() -> void:
	if State.edit_context_changing.is_connected(_on_edit_context_changing):
		State.edit_context_changing.disconnect(_on_edit_context_changing)
	if _settings.tool_changed.is_connected(_on_tool_changed):
		_settings.tool_changed.disconnect(_on_tool_changed)
	_cancel_pending()
	if is_instance_valid(_active_tool):
		_active_tool.cancel_pending()
		remove_editor_node(_active_tool)
	remove_option_bar_item(_options)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	_cancel_pending()
	for node in [_toolbar, _options, _box_tool, _ellipsoid_tool, _cylinder_tool]:
		if is_instance_valid(node):
			node.free()


## Activates the selected primitive tool and shows the option bar.
func activate_tool() -> void:
	if not _toolbar.button_pressed:
		_toolbar.button_pressed = true
		return
	_active = true
	add_option_bar_item(_options)
	_on_tool_changed(_settings.tool)


## Deactivates the active primitive tool. A pending primitive commits like a
## transform, before the tool leaves the viewport.
func _end_deactivation() -> void:
	_active = false
	remove_option_bar_item(_options)
	if is_instance_valid(_active_tool):
		_active_tool.finish_on_switch()
		remove_editor_node(_active_tool)
	_active_tool = null


## Switches the mounted tool when the toolbar selects another shape.
func _on_tool_changed(tool: PrimitiveToolSettings.Tools) -> void:
	if not _active:
		return
	var next: Node3D = _box_tool
	match tool:
		PrimitiveToolSettings.Tools.ELLIPSOID:
			next = _ellipsoid_tool
		PrimitiveToolSettings.Tools.CYLINDER:
			next = _cylinder_tool
		_:
			next = _box_tool
	if next == _active_tool:
		return
	if is_instance_valid(_active_tool):
		_active_tool.finish_on_switch()
		remove_editor_node(_active_tool)
	_active_tool = next
	add_editor_node(_active_tool)


## Builds one primitive request. This is the shared commit path for the mouse
## tools and the MCP server. [param allow_large] skips the cell limit for a
## mouse commit, which already showed the shape in the preview. Returns the
## applied count, the scan bounds, the changed bounds, the chunk count, and the
## warnings. A failure returns an [code]error[/code] key.
func build_shape(request: Dictionary, allow_large := false) -> Dictionary:
	var validation := PrimitiveField.validate_request(request, allow_large)
	if not validation.is_empty():
		return {"error": validation}
	if State.active_edit() != null or State.edit_busy():
		return {"error": "The editor is busy with another edit. Retry."}
	var document := State.document
	if document == null:
		return {"error": "No document is open."}
	var frame_index := State.current_frame
	var frame: VoxelFrame = State.get_current_voxel_frame()
	if frame == null:
		return {"error": "The current frame is missing."}
	var tx := State.begin_edit(frame_index)
	if tx == null:
		return {"error": "The editor is busy with another edit. Retry."}
	var job := PrimitiveJob.new()
	job.request = request.duplicate(true)
	job.edit_context = tx.edit_context
	job.edited_frame = VoxelFrame.job_frame(frame)
	_active_job = job
	_active_tx = tx
	var total := PrimitiveField.estimated_cells(job.request)
	if total <= INLINE_CELLS:
		job.run()
	else:
		var operation := State.begin_operation("Building shape", total, true, self, job.cancel)
		await State.run_edit_job(job, operation, "Build shape")
		State.finish_operation(operation)
	# Clear the pending fields before the signals, so a handler can start a new
	# edit on this plugin without this call clearing it.
	_active_job = null
	_active_tx = null
	if State.active_edit() != tx:
		State.cancel_edit(tx)
		return {"error": "The edit context changed before the shape finished."}
	if not job.checkpoint(0):
		State.cancel_edit(tx)
		return {"error": "The shape was cancelled."}
	if State.document != document or State.get_current_voxel_frame() != frame:
		State.cancel_edit(tx)
		return {"error": "The document or frame changed before the shape finished."}
	frame.apply_published(job.changed_chunks, job.edited_frame)
	document._bounds_dirty = true
	if not job.changed_chunks.is_empty():
		State.chunks_changed.emit(frame_index, job.changed_chunks)
	var applied: Array[Vector3i] = []
	applied.assign(job.applied_cells.keys())
	if not applied.is_empty():
		State.cells_changed.emit(frame_index, applied)
	var label := str(request.get("label", "Build Shape"))
	if label.is_empty():
		label = "Build Shape"
	State.finish_edit(tx, label)
	var warnings := PrimitiveField.warnings(job.request)
	if job.blend_skipped:
		warnings.append("Existing geometry blend was skipped because the local region is too large.")
	var result := {
		"applied": job.applied_cells.size(),
		"chunks": job.changed_chunks.size(),
		"bounds_min": job.bounds_min,
		"bounds_max": job.bounds_max,
		"changed_min": job.changed_min,
		"changed_max": job.changed_max,
		"warnings": warnings,
		"action": label,
	}
	return result


func _on_edit_context_changing() -> void:
	if _active_job != null:
		_active_job.cancel()


func _cancel_pending() -> void:
	var job := _active_job
	_active_job = null
	if job != null:
		job.cancel()
		job.wait_for_worker()
	var tx := _active_tx
	_active_tx = null
	if tx != null and State.active_edit() == tx:
		State.cancel_edit(tx)
