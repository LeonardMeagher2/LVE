extends "./TransformTool.gd"

var _axis := 1
var _p := 0
var _q := 2
var _pivot := Vector3.ZERO
var _ref_p := 1.0
var _ref_q := 1.0
var _ref_dir := Vector2.RIGHT
var _ref_dist := 1.0
var _scale_p := 1.0
var _scale_q := 1.0

const MIN_REF := 0.5
const MIN_SCALE := 0.05


func _begin_grab(origin: Vector3, dir: Vector3) -> void:
	_pivot = _source_bbox().get_center()
	_axis = _view_axis()
	_p = (_axis + 1) % 3
	_q = (_axis + 2) % 3
	_plane = _view_plane_through(_pivot)

	var bbox := _source_bbox()
	var min_p: float = maxf(bbox.size[_p] * 0.5, MIN_REF)
	var min_q: float = maxf(bbox.size[_q] * 0.5, MIN_REF)

	var v := _cursor_vec_pq(origin, dir)
	_ref_p = _safe_ref(v.x, min_p)
	_ref_q = _safe_ref(v.y, min_q)
	var ref_vec := Vector2(_ref_p, _ref_q)
	_ref_dir = ref_vec.normalized()
	_ref_dist = ref_vec.length()

	_scale_p = 1.0
	_scale_q = 1.0


func _update_params(origin: Vector3, dir: Vector3) -> bool:
	var v := _cursor_vec_pq(origin, dir)
	var sp: float
	var sq: float
	if _settings.uniform:
		var ratio := v.dot(_ref_dir) / _ref_dist
		sp = ratio
		sq = ratio
	else:
		sp = v.x / _ref_p
		sq = v.y / _ref_q
	# The camera ray round-trip and the reference-vector normalization both lose a little
	# precision, on the order of 1e-6. A factor the user drags to "exactly" 2x can land at
	# 1.9999993 instead, which tips a boundary cell to the wrong side in _compute_new_dest.
	# Snapping erases that noise without meaningfully rounding an intentionally fractional drag.
	sp = snapped(sp, 0.0001)
	sq = snapped(sq, 0.0001)
	if is_equal_approx(sp, _scale_p) and is_equal_approx(sq, _scale_q):
		return false
	_scale_p = sp
	_scale_q = sq
	return true


func _cursor_vec_pq(origin: Vector3, dir: Vector3) -> Vector2:
	var rel := _plane_point(origin, dir) - _pivot
	return Vector2(rel[_p], rel[_q])


func _safe_ref(value: float, min_abs: float) -> float:
	if absf(value) >= min_abs:
		return value
	return min_abs if value >= 0.0 else -min_abs


func _safe_scale(s: float) -> float:
	if absf(s) < MIN_SCALE:
		return MIN_SCALE if s >= 0.0 else -MIN_SCALE
	return s


# Scaling cannot forward-map one source cell to one destination cell the way Move and Rotate do:
# scaling up must turn a single source voxel into a block of several destination voxels, and
# scaling down must merge several into one. So this works backward from the destination instead:
# for every candidate destination cell, scale its center back into source space and sample the
# nearest source cell. That gives crisp N-cell blocks when scaling up, and a clean, no-blend pick
# per cell when scaling down, for any positive or negative (mirrored) factor.
func _compute_new_dest() -> Dictionary:
	if _cells.is_empty():
		return {}
	var sp := _safe_scale(_scale_p)
	var sq := _safe_scale(_scale_q)

	var src_min := _cells[0]
	var src_max := _cells[0]
	var layers: Dictionary = {}
	for c in _cells:
		src_min = Vector3i(mini(src_min.x, c.x), mini(src_min.y, c.y), mini(src_min.z, c.z))
		src_max = Vector3i(maxi(src_max.x, c.x), maxi(src_max.y, c.y), maxi(src_max.z, c.z))
		layers[c[_axis]] = true

	# Uniform scale is a true 3D scale: the depth axis moves by the same factor as the two
	# in-plane ones, even though the mouse only ever drags in 2D. Non-uniform stays confined to
	# the 2 in-plane axes (there is no way to drive a 3rd axis independently from a 2D drag), and
	# only samples the layers the source actually occupies rather than padding to a full range.
	if _settings.uniform:
		return _compute_new_dest_3d(sp, sq, sp, src_min, src_max)
	return _compute_new_dest_2d(sp, sq, src_min, src_max, layers)


func _compute_new_dest_2d(sp: float, sq: float, src_min: Vector3i, src_max: Vector3i, layers: Dictionary) -> Dictionary:
	var pivot_pq := Vector2(_pivot[_p], _pivot[_q])
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in 4:
		var corner := Vector2(
			src_min[_p] if i & 1 == 0 else src_max[_p] + 1,
			src_min[_q] if i & 2 == 0 else src_max[_q] + 1)
		var scaled: Vector2 = (corner - pivot_pq) * Vector2(sp, sq) + pivot_pq
		lo = lo.min(scaled)
		hi = hi.max(scaled)
	var min_dp := floori(lo.x)
	var min_dq := floori(lo.y)
	var max_dp := ceili(hi.x) - 1
	var max_dq := ceili(hi.y) - 1

	var out: Dictionary = {}
	for w in layers:
		for dp in range(min_dp, max_dp + 1):
			for dq in range(min_dq, max_dq + 1):
				var dest_center := Vector2(dp + 0.5, dq + 0.5)
				var src_point: Vector2 = (dest_center - pivot_pq) / Vector2(sp, sq) + pivot_pq
				var s := Vector3i.ZERO
				s[_axis] = w
				s[_p] = floori(src_point.x)
				s[_q] = floori(src_point.y)
				if _colors.has(s):
					var d := Vector3i.ZERO
					d[_axis] = w
					d[_p] = dp
					d[_q] = dq
					out[d] = _colors[s]
	return out


func _compute_new_dest_3d(sp: float, sq: float, sr: float, src_min: Vector3i, src_max: Vector3i) -> Dictionary:
	var scale3 := Vector3.ONE
	scale3[_p] = sp
	scale3[_q] = sq
	scale3[_axis] = sr

	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for i in 8:
		var corner := Vector3(
			src_min.x if i & 1 == 0 else src_max.x + 1,
			src_min.y if i & 2 == 0 else src_max.y + 1,
			src_min.z if i & 4 == 0 else src_max.z + 1)
		var scaled: Vector3 = (corner - _pivot) * scale3 + _pivot
		lo = lo.min(scaled)
		hi = hi.max(scaled)
	var min_d := Vector3i(floori(lo.x), floori(lo.y), floori(lo.z))
	var max_d := Vector3i(ceili(hi.x) - 1, ceili(hi.y) - 1, ceili(hi.z) - 1)

	var out: Dictionary = {}
	for dx in range(min_d.x, max_d.x + 1):
		for dy in range(min_d.y, max_d.y + 1):
			for dz in range(min_d.z, max_d.z + 1):
				var d := Vector3i(dx, dy, dz)
				var dest_center := Vector3(d) + Vector3(0.5, 0.5, 0.5)
				var src_point: Vector3 = (dest_center - _pivot) / scale3 + _pivot
				var s := Vector3i(floori(src_point.x), floori(src_point.y), floori(src_point.z))
				if _colors.has(s):
					out[d] = _colors[s]
	return out