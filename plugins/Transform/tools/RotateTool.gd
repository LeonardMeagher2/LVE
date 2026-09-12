extends "./TransformTool.gd"

const QUARTER := PI / 2.0
const DEGREE := PI / 180.0
const MAGNETIC_PULL := DEGREE * 2.0

var _axis := 1
var _axis_sign := 1.0
var _pivot := Vector3.ZERO
var _v0 := Vector3.ZERO
var _angle := 0.0


func _begin_grab(origin: Vector3, dir: Vector3) -> void:
	_pivot = _source_bbox().get_center()
	_set_view_axis()
	_plane = _view_plane_through(_pivot)
	var v := _cursor_vec(origin, dir)
	if v.is_zero_approx():
		v = _fallback_vec()
	_v0 = v.normalized()
	_angle = 0.0


func _update_params(origin: Vector3, dir: Vector3) -> bool:
	var v := _cursor_vec(origin, dir)
	if v.is_zero_approx():
		return false
	var total := _signed_angle(_v0, v)
	if _settings.snap:
		total = roundf(total / QUARTER) * QUARTER
	else:
		# A whole-degree floor keeps the live angle from drifting on float noise. Within a couple
		# degrees of a cardinal angle, pull to it exactly: a careful near-cardinal drag should
		# still land on the clean, hole-free integer rotation instead of the softer RotSprite one.
		total = snapped(total, DEGREE)
		var nearest_cardinal := roundf(total / QUARTER) * QUARTER
		if absf(total - nearest_cardinal) <= MAGNETIC_PULL:
			total = nearest_cardinal
	if is_equal_approx(total, _angle):
		return false
	_angle = total
	return true


func _set_view_axis() -> void:
	_axis = _view_axis()
	_axis_sign = _view_axis_sign()


func _compute_new_dest() -> Dictionary:
	if _is_cardinal_angle():
		return _compute_new_dest_exact()
	return _compute_new_dest_smooth()


func _is_cardinal_angle() -> bool:
	var k := _angle / QUARTER
	return is_equal_approx(k, roundf(k))


# Exact, hole-free rotation for angles that are a multiple of 90 degrees. Cell rotation must
# work on integer cell indices, not on continuous cell-center points: rotating points around a
# pivot and flooring the result only produces a clean bijection when the pivot's two in-plane
# coordinates share the same "grid parity" (NOTES.md). That parity depends on the selection's own
# size and is not guaranteed, so this method never rotates a point at all. It permutes the local
# (0-based) cell indices within the selection's own bounding box, which is always a bijection.
func _compute_new_dest_exact() -> Dictionary:
	var p := (_axis + 1) % 3
	var q := (_axis + 2) % 3
	var bounds := _cell_bounds()
	var min_c: Vector3i = bounds[0]
	var max_c: Vector3i = bounds[1]

	var probe := Vector3.ZERO
	probe[p] = 1.0
	var probe_rot: Vector3 = Basis(_axis_vec(), QUARTER) * probe
	var dir := 1 if probe_rot[q] > 0.5 else -1
	var k := int(roundf(_angle / QUARTER))
	k = ((k % 4) + 4) % 4

	var out: Dictionary = {}
	for s in _cells:
		if _colors.has(s):
			out[_rotate_cell_exact(s, p, q, min_c, max_c, dir, k)] = _colors[s]
	return out


func _cell_bounds() -> Array:
	var min_c := _cells[0]
	var max_c := _cells[0]
	for c in _cells:
		min_c = Vector3i(mini(min_c.x, c.x), mini(min_c.y, c.y), mini(min_c.z, c.z))
		max_c = Vector3i(maxi(max_c.x, c.x), maxi(max_c.y, c.y), maxi(max_c.z, c.z))
	return [min_c, max_c]


func _rotate_cell_exact(s: Vector3i, p: int, q: int, min_c: Vector3i, max_c: Vector3i, dir: int, k: int) -> Vector3i:
	var lp := s[p] - min_c[p]
	var lq := s[q] - min_c[q]
	var wp := max_c[p] - min_c[p] + 1
	var wq := max_c[q] - min_c[q] + 1
	for _i in k:
		var new_lp: int
		var new_lq: int
		if dir == 1:
			new_lp = (wq - 1) - lq
			new_lq = lp
		else:
			new_lp = lq
			new_lq = (wp - 1) - lp
		lp = new_lp
		lq = new_lq
		var tmp := wp
		wp = wq
		wq = tmp
	# The bounding box's own min corner stays fixed. It never depends on the rotated result, so
	# repeated 90 degree rotations never drift: four of them always return the exact original.
	var dest := s
	dest[p] = min_c[p] + lp
	dest[q] = min_c[q] + lq
	return dest


# Approximate rotation for an arbitrary (non-cardinal) angle, used only for the live preview
# while the user free-rotates with snap off. A voxel grid cannot rotate cleanly at an arbitrary
# angle, so this uses the RotSprite technique (Xenowhirl): upscale each layer with a Scale2x-style
# pass, then rotate and downscale together by nearest-neighbor sampling at the finer resolution.
# That produces a much cleaner silhouette than rotating and sampling at native resolution.
func _compute_new_dest_smooth() -> Dictionary:
	var p := (_axis + 1) % 3
	var q := (_axis + 2) % 3
	var probe := Vector3.ZERO
	probe[p] = 1.0
	var probe_rot: Vector3 = Basis(_axis_vec(), QUARTER) * probe
	var dir := 1.0 if probe_rot[q] > 0.5 else -1.0
	var pivot2d := Vector2(_pivot[p], _pivot[q])
	var angle2d := dir * _angle

	# Split the selection into 2D layers along the rotation axis; a single-axis rotation never
	# moves a cell out of its own layer.
	var layers: Dictionary = {}
	for s in _cells:
		if not _colors.has(s):
			continue
		var w: int = s[_axis]
		if not layers.has(w):
			layers[w] = {}
		layers[w][Vector2i(s[p], s[q])] = _colors[s]

	# Rotate every layer first and measure where the combined result actually landed, rather than
	# predicting it from the source bounding box: RotSprite's own candidate scan range is padded
	# wider than the shape it actually finds (the same way a plain bounding-box estimate always is),
	# so the true occupied corner only exists after the empty candidates have been sampled out.
	var layer_results: Dictionary = {}
	var natural_min := Vector2i(0, 0)
	var first := true
	for w in layers:
		var sampler := RotSprite.new(layers[w])
		var dest_layer := sampler.rotate(pivot2d, angle2d)
		layer_results[w] = dest_layer
		for uv in dest_layer:
			if first:
				natural_min = uv
				first = false
			else:
				natural_min = Vector2i(mini(natural_min.x, uv.x), mini(natural_min.y, uv.y))

	if first:
		return {}

	# RotSprite rotates around the selection's continuous center, which only lands back on the
	# exact algorithm's own convention (the original bounding box's min corner held fixed) at 0
	# and 180 degrees; at 90 and 270 it lands somewhere else. This closes that gap, so the smooth
	# preview always agrees with the exact result at every cardinal angle, with nothing
	# special-cased near the boundary.
	var min_c: Vector3i = _cell_bounds()[0]
	var correction := Vector2i(min_c[p], min_c[q]) - natural_min

	var out: Dictionary = {}
	for w in layer_results:
		var dest_layer: Dictionary = layer_results[w]
		for uv in dest_layer:
			var dest := Vector3i.ZERO
			dest[_axis] = w
			dest[p] = uv.x + correction.x
			dest[q] = uv.y + correction.y
			out[dest] = dest_layer[uv]
	return out


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


# Used only when the initial press lands exactly on the pivot's own screen position, so there is
# no real cursor vector to start measuring the angle from. A fixed world axis is a poor stand-in:
# depending on which axis is being rotated, it can land parallel (or opposite) to the screen
# direction the user actually drags in, making the very same drag read as 0 degrees on one view
# and 180 on another. The camera's own screen-right direction, projected into the rotation plane,
# stays roughly perpendicular to a vertical drag (and vice versa) no matter which axis is active.
func _fallback_vec() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var right := _in_plane(cam.basis.x)
		if not right.is_zero_approx():
			return right.normalized()
	var v := Vector3.ZERO
	v[(_axis + 1) % 3] = 1.0
	return v
