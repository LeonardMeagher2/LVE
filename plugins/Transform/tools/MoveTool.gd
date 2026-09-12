extends "./TransformTool.gd"

var _grab_point := Vector3.ZERO
var _base_offset := Vector3i.ZERO
var _offset := Vector3i.ZERO


func _pivot_point() -> Vector3:
	return _source_bbox().get_center() + Vector3(_offset)


func _begin_grab(origin: Vector3, dir: Vector3) -> void:
	_offset = Vector3i.ZERO
	_base_offset = Vector3i.ZERO
	_plane = _view_plane_through(_pivot_point())
	_grab_point = _plane_point(origin, dir)


func _regrab(origin: Vector3, dir: Vector3) -> void:
	_plane = _view_plane_through(_pivot_point())
	_grab_point = _plane_point(origin, dir)
	_base_offset = _offset


func _update_params(origin: Vector3, dir: Vector3) -> bool:
	var p := _plane_point(origin, dir)
	if p.is_zero_approx():
		return false
	var delta := Vector3i(
		roundi(p.x - _grab_point.x),
		roundi(p.y - _grab_point.y),
		roundi(p.z - _grab_point.z))
	var off := _base_offset + delta
	if off == _offset:
		return false
	_offset = off
	return true


func _map_dest(s: Vector3i) -> Vector3i:
	return s + _offset