class_name MoveTool
extends TransformTool

var _grab_target := VoxelPicking.NONE
var _offset := Vector3i.ZERO


func _begin_grab(pick: PickResult, _origin: Vector3, _dir: Vector3) -> void:
	_grab_target = pick.target
	_offset = Vector3i.ZERO


func _regrab(pick: PickResult, _origin: Vector3, _dir: Vector3) -> void:
	_grab_target = pick.target - _offset


func _update_params(pick: PickResult, _origin: Vector3, _dir: Vector3) -> bool:
	if pick.target == VoxelPicking.NONE:
		return false
	var off: Vector3i = pick.target - _grab_target
	if off == _offset:
		return false
	_offset = off
	return true


func _dest_bbox() -> AABB:
	var b := _source_bbox()
	b.position += Vector3(_offset)
	return b


func _map_source(d: Vector3i) -> Vector3i:
	return d - _offset


func _key_action(event: InputEventKey) -> bool:
	if event.is_action_pressed("ui_left"):
		_nudge(Vector3i(-1, 0, 0))
		return true
	if event.is_action_pressed("ui_right"):
		_nudge(Vector3i(1, 0, 0))
		return true
	if event.is_action_pressed("ui_up"):
		_nudge(Vector3i(0, 1, 0))
		return true
	if event.is_action_pressed("ui_down"):
		_nudge(Vector3i(0, -1, 0))
		return true
	return false


func _nudge(offset: Vector3i) -> void:
	if State.selection.is_empty():
		return
	begin_stroke()
	var sel := State.selection.to_array()
	var moved: Dictionary = {}
	for c in sel:
		if State.document.has_cell(State.current_frame, c):
			moved[c] = State.document.frames[State.current_frame].cells[c]
	for c in moved:
		State.document.erase(State.current_frame, c)
	for c in moved:
		State.document.set_cell(State.current_frame, c + offset, moved[c])
	if not moved.is_empty():
		State.cells_changed.emit()
	_end()
