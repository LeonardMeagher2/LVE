extends "./TransformTool.gd"

const QUARTER := PI / 2.0
const DEGREE := PI / 180.0
const MAGNETIC_PULL := DEGREE * 2.0

var _axis := 1
var _axis_sign := 1.0
var _pivot := Vector3.ZERO
var _v0 := Vector3.ZERO
var _angle := 0.0

class RotateJob extends TransformJob:
	var axis := 1
	var axis_sign := 1.0
	var pivot := Vector3.ZERO
	var angle := 0.0

	func estimated_work() -> int:
		if is_equal_approx(angle / QUARTER, roundf(angle / QUARTER)):
			return source_positions.size()
		var p := (axis + 1) % 3
		var q := (axis + 2) % 3
		var span := source_bounds.size[p] + source_bounds.size[q] + 4
		return maxi(source_positions.size(), ceili(span * span * source_bounds.size[axis]))

	func compute_destination() -> void:
		if is_equal_approx(angle / QUARTER, roundf(angle / QUARTER)):
			_compute_exact()
		else:
			_compute_smooth()

	func _axis_vector() -> Vector3:
		var vector := Vector3.ZERO
		vector[axis] = axis_sign
		return vector

	func _compute_exact() -> void:
		var p := (axis + 1) % 3
		var q := (axis + 2) % 3
		var min_c := Vector3i(source_bounds.position + Vector3.ONE * 0.5)
		var max_c := Vector3i(source_bounds.end - Vector3.ONE * 0.5)
		var probe := Vector3.ZERO
		probe[p] = 1.0
		var probe_rot: Vector3 = Basis(_axis_vector(), QUARTER) * probe
		var direction := 1 if probe_rot[q] > 0.5 else -1
		var turns := int(roundf(angle / QUARTER))
		turns = ((turns % 4) + 4) % 4
		stage("Calculating rotation", source_positions.size())
		var completed := 0
		for source in source_positions:
			if source_colors.has(source):
				destination_colors[_rotate_cell(source, p, q, min_c, max_c, direction, turns)] = source_colors[source]
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return

	# Permute cell indices within the source bounds to keep cardinal rotations exact.
	func _rotate_cell(source: Vector3i, p: int, q: int, min_c: Vector3i, max_c: Vector3i, direction: int, turns: int) -> Vector3i:
		var lp := source[p] - min_c[p]
		var lq := source[q] - min_c[q]
		var wp := max_c[p] - min_c[p] + 1
		var wq := max_c[q] - min_c[q] + 1
		for _turn in turns:
			var new_lp: int
			var new_lq: int
			if direction == 1:
				new_lp = (wq - 1) - lq
				new_lq = lp
			else:
				new_lp = lq
				new_lq = (wp - 1) - lp
			lp = new_lp
			lq = new_lq
			var previous_width := wp
			wp = wq
			wq = previous_width
		var destination := source
		destination[p] = min_c[p] + lp
		destination[q] = min_c[q] + lq
		return destination

	func _compute_smooth() -> void:
		var p := (axis + 1) % 3
		var q := (axis + 2) % 3
		var probe := Vector3.ZERO
		probe[p] = 1.0
		var probe_rot: Vector3 = Basis(_axis_vector(), QUARTER) * probe
		var direction := 1.0 if probe_rot[q] > 0.5 else -1.0
		var pivot2d := Vector2(pivot[p], pivot[q])
		var layers := {}
		stage("Preparing rotation", source_positions.size())
		var completed := 0
		for source in source_positions:
			if source_colors.has(source):
				var layer: int = source[axis]
				if not layers.has(layer):
					layers[layer] = {}
				layers[layer][Vector2i(source[p], source[q])] = source_colors[source]
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return
		var layer_results := {}
		var natural_min := Vector2i.ZERO
		var first := true
		stage("Calculating rotation", layers.size())
		completed = 0
		for layer in layers:
			var sampler := RotSprite.new(layers[layer])
			var destination_layer := sampler.rotate(pivot2d, direction * angle)
			layer_results[layer] = destination_layer
			for uv: Vector2i in destination_layer:
				if first:
					natural_min = uv
					first = false
				else:
					natural_min = Vector2i(mini(natural_min.x, uv.x), mini(natural_min.y, uv.y))
			completed += 1
			if not checkpoint(completed):
				return
		if first:
			return
		# Align the occupied corner with the exact rotation convention.
		var min_c := Vector3i(source_bounds.position + Vector3.ONE * 0.5)
		var correction := Vector2i(min_c[p], min_c[q]) - natural_min
		for layer in layer_results:
			for uv: Vector2i in layer_results[layer]:
				var destination := Vector3i.ZERO
				destination[axis] = layer
				destination[p] = uv.x + correction.x
				destination[q] = uv.y + correction.y
				destination_colors[destination] = layer_results[layer][uv]
			if not checkpoint(completed):
				return


func _begin_grab(origin: Vector3, dir: Vector3) -> void:
	_pivot = _source_bbox().get_center()
	_axis = _view_axis()
	_axis_sign = _view_axis_sign()
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
		total = snapped(total, DEGREE)
		var nearest_cardinal := roundf(total / QUARTER) * QUARTER
		if absf(total - nearest_cardinal) <= MAGNETIC_PULL:
			total = nearest_cardinal
	if is_equal_approx(total, _angle):
		return false
	_angle = total
	return true


func _make_job() -> TransformJob:
	var job := RotateJob.new()
	job.axis = _axis
	job.axis_sign = _axis_sign
	job.pivot = _pivot
	job.angle = _angle
	return job


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
	var right := _in_plane(_grab_camera_right)
	if not right.is_zero_approx():
		return right.normalized()
	var v := Vector3.ZERO
	v[(_axis + 1) % 3] = 1.0
	return v
