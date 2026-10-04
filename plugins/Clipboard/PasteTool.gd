extends "res://Plugins/Brush/LineTool.gd"

signal finished()

var _active := false
var _placement_operation_id := 0


func begin_paste(pattern: Dictionary, center: Vector3i) -> void:
	_active = true
	_source_document = State.document
	_source_frame = State.get_current_voxel_frame()
	_line_snapshot = _source_frame.copy_frame()
	_anchor = center
	_endpoint = VoxelPicking.NONE
	_stroke_pattern = pattern
	_stroke_shape = _settings.BrushShape.SELECTION
	_stroke_pattern_size = pattern.size()
	_selection_mask = {}
	_placement_operation_id = State.begin_operation("Placing pasted voxels", -1, true, self)
	_update_endpoint(center)


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if not _active:
		return false
	if event.is_action_pressed("ui_cancel"):
		_cancel_edit()
		return true
	if event.is_action_pressed("ui_accept"):
		_request_commit()
		return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_cancel_edit()
		return true
	if event is InputEventMouseMotion or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed):
		if _commit_requested:
			return true
		var ray := _ray(pos)
		var pick := _pick_start(ray[0], ray[1])
		if pick.target != VoxelPicking.NONE:
			_update_endpoint(pick.target)
			if event is InputEventMouseButton:
				_request_commit()
		return true
	return event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT


func _preview_centers() -> Array[Vector3i]:
	return [_endpoint]


func _commit_line() -> void:
	if _preview_result == null:
		return
	var job := _preview_result
	var frame := _source_frame
	var context_valid := State.document == _source_document and State.get_current_voxel_frame() == frame
	_cancel_edit()
	if not context_valid:
		return
	State.begin_stroke()
	frame.restore(job.edited_frame.capture())
	State.document._bounds_dirty = true
	State.selection.restore(job.cell_colors)
	State.end_stroke("Paste")
	if not job.changed_chunks.is_empty():
		State.chunks_changed.emit(State.current_frame, job.changed_chunks)
	State.selection_changed.emit()


func _cancel_edit() -> void:
	var was_active := _active
	_active = false
	State.finish_operation(_placement_operation_id)
	_placement_operation_id = 0
	super._cancel_edit()
	if was_active:
		finished.emit()


func _on_settings_changed() -> void:
	pass
