extends "./TransformTool.gd"

const TransformDialog := preload("./TransformDialog.gd")

var _grab_point := Vector3.ZERO
var _offset := Vector3i.ZERO
var _total_offset := Vector3i.ZERO
var _gesture_base := Vector3i.ZERO


func _begin_grab(origin: Vector3, dir: Vector3) -> void:
	_offset = Vector3i.ZERO
	if _was_pending:
		_gesture_base = _total_offset
	else:
		_total_offset = Vector3i.ZERO
		_gesture_base = Vector3i.ZERO
	_plane = _view_plane_through(_source_bbox().get_center())
	_grab_point = _plane_point(origin, dir)


func _update_params(origin: Vector3, dir: Vector3) -> bool:
	var p := _plane_point(origin, dir)
	if p.is_zero_approx():
		return false
	var off := Vector3i(
		roundi(p.x - _grab_point.x),
		roundi(p.y - _grab_point.y),
		roundi(p.z - _grab_point.z))
	if off == _offset:
		return false
	_offset = off
	_total_offset = _gesture_base + _offset
	return true


func _make_job() -> TransformJob:
	var job := TransformJob.new()
	job.offset = _offset
	return job


func _on_click_without_drag() -> bool:
	if _grab_waiting or _preview_running:
		return false
	if _was_pending and _has_base:
		_restore_grab_baseline()
		_offset = _total_offset
		_pending = true
		_open_move_dialog(Vector3(_total_offset))
		return true
	if _cells.is_empty():
		return false
	_pending = true
	_offset = Vector3i.ZERO
	_open_move_dialog(Vector3.ZERO)
	return true


func _did_restore_baseline() -> void:
	_plane = _view_plane_through(_source_bbox().get_center())


func _connect_tool_dialog() -> void:
	_dialog.connect("values_changed", _on_dialog_values)
	_dialog.connect("confirmed", _on_dialog_confirmed)
	_dialog.connect("canceled", _on_dialog_canceled)


func _open_move_dialog(offset: Vector3) -> void:
	_ensure_tool_dialog()
	_dialog.open_for_move(offset)
	_dialog.popup_centered()
	_record_dialog_open({TransformDialog.KEY_VALUES: offset, TransformDialog.KEY_AXIS: -1, TransformDialog.KEY_UNIFORM: false})


func _on_dialog_values(state: Dictionary) -> void:
	var raw: Vector3 = state[TransformDialog.KEY_VALUES]
	var off := Vector3i(roundi(raw.x), roundi(raw.y), roundi(raw.z))
	if off == _offset:
		return
	_offset = off
	_total_offset = off
	_dialog_dirty = true
	_apply_preview()


func _on_dialog_confirmed() -> void:
	if _offset == Vector3i.ZERO and not _dragged and not _was_pending:
		_cancel()


func _on_dialog_canceled() -> void:
	if _dialog_open_had_pending:
		if _dialog_dirty:
			_dialog_dirty = false
			var raw: Vector3 = _dialog_open_values[TransformDialog.KEY_VALUES]
			var open := Vector3i(roundi(raw.x), roundi(raw.y), roundi(raw.z))
			if open != _offset:
				_offset = open
				_total_offset = open
				_apply_preview()
		return
	_cancel()
