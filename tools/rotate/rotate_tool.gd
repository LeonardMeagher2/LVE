class_name RotateTool
extends TransformTool

const QUARTER := PI / 2.0

var option:ToolOption
var group:String

var _axis := 1
var _axis_sign := 1.0
var _pivot := Vector3.ZERO
var _v0 := Vector3.ZERO
var _base_angle := 0.0
var _angle := 0.0


func _begin_grab(_pick: PickResult, origin: Vector3, dir: Vector3) -> void:
	_pivot = _source_bbox().get_center()
	_set_view_axis()
	_plane = _rotation_plane()
	var v := _cursor_vec(origin, dir)
	if v.is_zero_approx():
		v = _fallback_vec()
	_v0 = v.normalized()
	_base_angle = 0.0
	_angle = 0.0


func _regrab(_pick: PickResult, origin: Vector3, dir: Vector3) -> void:
	_set_view_axis()
	_plane = _rotation_plane()
	var v := _cursor_vec(origin, dir)
	if not v.is_zero_approx():
		_v0 = v.normalized()
	_base_angle = _angle


func _update_params(_pick: PickResult, origin: Vector3, dir: Vector3) -> bool:
	var v := _cursor_vec(origin, dir)
	if v.is_zero_approx():
		return false
	var total := _base_angle + _signed_angle(_v0, v)
	if State.get_tool_option(info, "snap") == true:
		total = roundf(total / QUARTER) * QUARTER
	if is_equal_approx(total, _angle):
		return false
	_angle = total
	return true


func _set_view_axis() -> void:
	var toward := -_forward()
	var fx: float = absf(toward.x)
	var fy: float = absf(toward.y)
	var fz: float = absf(toward.z)
	if fy >= fx and fy >= fz:
		_axis = 1
	elif fz >= fx:
		_axis = 2
	else:
		_axis = 0
	_axis_sign = 1.0 if toward[_axis] >= 0.0 else -1.0


func _rotation_plane() -> StrokePlane:
	var p := StrokePlane.new()
	p.axis = _axis
	p.idx = 0
	p.point = _pivot
	var n := Vector3.ZERO
	n[_axis] = 1.0
	p.normal = n
	return p


func _dest_bbox() -> AABB:
	var src := _source_bbox()
	if src.size == Vector3.ZERO:
		return AABB()
	var rot := Basis(_axis_vec(), _angle)
	var lo := Vector3.INF
	var hi := -Vector3.INF
	for i in 8:
		var corner := Vector3(
			src.position.x + (src.size.x if i & 1 else 0.0),
			src.position.y + (src.size.y if i & 2 else 0.0),
			src.position.z + (src.size.z if i & 4 else 0.0))
		var c := rot * (corner - _pivot) + _pivot
		lo = lo.min(c)
		hi = hi.max(c)
	return AABB(lo - Vector3.ONE * 0.5, hi - lo + Vector3.ONE)


func _map_source(d: Vector3i) -> Vector3i:
	var inv := Basis(_axis_vec(), -_angle)
	var p := inv * (Vector3(d) + Vector3(0.5, 0.5, 0.5) - _pivot) + _pivot
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
