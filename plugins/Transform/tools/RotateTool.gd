extends "./TransformTool.gd"

const QUARTER := PI / 2.0

var _axis := 1
var _axis_sign := 1.0
var _pivot := Vector3.ZERO
var _v0 := Vector3.ZERO
var _base_angle := 0.0
var _angle := 0.0


func _pivot_point() -> Vector3:
	return _pivot


func _begin_grab(origin: Vector3, dir: Vector3) -> void:
	_pivot = _source_bbox().get_center()
	_set_view_axis()
	_plane = _view_plane_through(_pivot)
	var v := _cursor_vec(origin, dir)
	if v.is_zero_approx():
		v = _fallback_vec()
	_v0 = v.normalized()
	_base_angle = 0.0
	_angle = 0.0


func _regrab(origin: Vector3, dir: Vector3) -> void:
	_set_view_axis()
	_plane = _view_plane_through(_pivot)
	var v := _cursor_vec(origin, dir)
	if not v.is_zero_approx():
		_v0 = v.normalized()
	_base_angle = _angle


func _update_params(origin: Vector3, dir: Vector3) -> bool:
	var v := _cursor_vec(origin, dir)
	if v.is_zero_approx():
		return false
	var total := _base_angle + _signed_angle(_v0, v)
	if _settings.snap:
		total = roundf(total / QUARTER) * QUARTER
	if is_equal_approx(total, _angle):
		return false
	_angle = total
	return true


func _set_view_axis() -> void:
	_axis = _view_axis()
	_axis_sign = _view_axis_sign()


func _map_dest(s: Vector3i) -> Vector3i:
	var rot := Basis(_axis_vec(), _angle)
	var p := rot * (Vector3(s) + Vector3(0.5, 0.5, 0.5) - _pivot) + _pivot
	return Vector3i(floorf(p.x), floorf(p.y), floorf(p.z))


func _axis_vec() -> Vector3:
	var v := Vector3.ZERO
	v[_axis] = _axis_sign
	return v


func _in_plane(v: Vector3) -> Vector3:
	v[_axis] = 0.0
	return v


func _cursor_vec(origin: Vector3, dir: Vector3) -> Vector3:
	return _in_plane(_plane_point(origin, dir) - _pivot)


func _signed_angle(a: Vector3, b: Vector3) -> float:
	return atan2(a.cross(b).dot(_axis_vec()), a.dot(b))


func _fallback_vec() -> Vector3:
	var v := Vector3.ZERO
	v[(_axis + 1) % 3] = 1.0
	return v