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

class ScaleJob extends TransformJob:
	var axis := 1
	var p := 0
	var q := 2
	var pivot := Vector3.ZERO
	var scale_p := 1.0
	var scale_q := 1.0
	var uniform := true
	var _candidate_total := 0
	var _candidate_completed := 0
	var _source_selection := {}

	func estimated_work() -> int:
		var depth := absf(scale_p) if uniform else 1.0
		return maxi(source_positions.size(), ceili((source_bounds.size[p] * absf(scale_p) + 2) * (source_bounds.size[q] * absf(scale_q) + 2) * (source_bounds.size[axis] * depth + 2)))

	func compute_destination() -> void:
		if source_positions.is_empty():
			return
		if track_selection:
			stage("Preparing scale selection", source_positions.size())
			for cell_position in source_positions:
				_source_selection[cell_position] = true
				if _source_selection.size() % 4096 == 0 and not checkpoint(_source_selection.size()):
					return
		var scale3 := Vector3.ONE
		scale3[p] = scale_p
		scale3[q] = scale_q
		scale3[axis] = scale_p if uniform else 1.0
		var regions: Array[AABB] = [source_bounds]
		var source_volume := source_bounds.size.x * source_bounds.size.y * source_bounds.size.z
		if source_volume > source_positions.size() * 4:
			regions = _occupied_regions()
		var layers := {}
		if not uniform:
			for cell_position in source_positions:
				layers[cell_position[axis]] = true
		var candidate_ranges := []
		for region in regions:
			var destination_range := _destination_range(region, scale3)
			var min_d: Vector3i = destination_range[0]
			var max_d: Vector3i = destination_range[1]
			var region_layers := {}
			if uniform:
				_candidate_total += (max_d.x - min_d.x + 1) * (max_d.y - min_d.y + 1) * (max_d.z - min_d.z + 1)
			else:
				for layer in layers:
					if layer >= region.position[axis] + 0.5 and layer <= region.end[axis] - 0.5:
						region_layers[layer] = true
				_candidate_total += region_layers.size() * (max_d[p] - min_d[p] + 1) * (max_d[q] - min_d[q] + 1)
			candidate_ranges.append([min_d, max_d, region_layers])
		stage("Calculating scale", _candidate_total)
		for candidate_range in candidate_ranges:
			if not checkpoint(_candidate_completed):
				return
			if uniform:
				_compute_3d(candidate_range[0], candidate_range[1], scale3)
			else:
				_compute_2d(candidate_range[0], candidate_range[1], candidate_range[2])

	func _occupied_regions() -> Array[AABB]:
		stage("Preparing scale", source_positions.size())
		var bounds_by_chunk := {}
		var completed := 0
		for cell_position in source_positions:
			var chunk_location := VoxelFrame.chunk_position(cell_position)
			var cell_bounds := AABB(Vector3(cell_position) - Vector3.ONE * 0.5, Vector3.ONE)
			var bounds: AABB = bounds_by_chunk.get(chunk_location, cell_bounds)
			bounds_by_chunk[chunk_location] = bounds.merge(cell_bounds)
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return []
		var regions: Array[AABB] = []
		for bounds in bounds_by_chunk.values():
			regions.append(bounds)
		return regions

	func _destination_range(region: AABB, scale3: Vector3) -> Array:
		var src_min := Vector3i(region.position + Vector3.ONE * 0.5)
		var src_max := Vector3i(region.end - Vector3.ONE * 0.5)
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for i in 8:
			var corner := Vector3(
				src_min.x if i & 1 == 0 else src_max.x + 1,
				src_min.y if i & 2 == 0 else src_max.y + 1,
				src_min.z if i & 4 == 0 else src_max.z + 1)
			var scaled := (corner - pivot) * scale3 + pivot
			lo = lo.min(scaled)
			hi = hi.max(scaled)
		var min_d := Vector3i(floori(lo.x), floori(lo.y), floori(lo.z))
		var max_d := Vector3i(ceili(hi.x) - 1, ceili(hi.y) - 1, ceili(hi.z) - 1)
		return [min_d, max_d]

	func _samples(first: int, last: int, pivot_coordinate: float, scale: float) -> PackedInt32Array:
		var samples := PackedInt32Array()
		samples.resize(last - first + 1)
		for coordinate in range(first, last + 1):
			samples[coordinate - first] = floori((coordinate + 0.5 - pivot_coordinate) / scale + pivot_coordinate)
		return samples

	func _compute_3d(min_d: Vector3i, max_d: Vector3i, scale3: Vector3) -> void:
		var samples_x := _samples(min_d.x, max_d.x, pivot.x, scale3.x)
		var samples_y := _samples(min_d.y, max_d.y, pivot.y, scale3.y)
		var samples_z := _samples(min_d.z, max_d.z, pivot.z, scale3.z)
		for dx in range(min_d.x, max_d.x + 1):
			var sx := samples_x[dx - min_d.x]
			for dy in range(min_d.y, max_d.y + 1):
				var sy := samples_y[dy - min_d.y]
				for dz in range(min_d.z, max_d.z + 1):
					var source := Vector3i(sx, sy, samples_z[dz - min_d.z])
					var destination := Vector3i(dx, dy, dz)
					var color: Color = source_colors.get(source, Color.TRANSPARENT)
					if color != Color.TRANSPARENT:
						destination_colors[destination] = color
					if track_selection and _source_selection.has(source):
						destination_selection[destination] = true
					_candidate_completed += 1
					if _candidate_completed % 4096 == 0 and not checkpoint(_candidate_completed):
						return

	func _compute_2d(min_d: Vector3i, max_d: Vector3i, layers: Dictionary) -> void:
		var samples_p := _samples(min_d[p], max_d[p], pivot[p], scale_p)
		var samples_q := _samples(min_d[q], max_d[q], pivot[q], scale_q)
		for layer in layers:
			for dp in range(min_d[p], max_d[p] + 1):
				for dq in range(min_d[q], max_d[q] + 1):
					var source := Vector3i.ZERO
					source[axis] = layer
					source[p] = samples_p[dp - min_d[p]]
					source[q] = samples_q[dq - min_d[q]]
					var color: Color = source_colors.get(source, Color.TRANSPARENT)
					var destination := Vector3i.ZERO
					destination[axis] = layer
					destination[p] = dp
					destination[q] = dq
					if color != Color.TRANSPARENT:
						destination_colors[destination] = color
					if track_selection and _source_selection.has(source):
						destination_selection[destination] = true
					_candidate_completed += 1
					if _candidate_completed % 4096 == 0 and not checkpoint(_candidate_completed):
						return


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


func _make_job() -> TransformJob:
	var job := ScaleJob.new()
	job.axis = _axis
	job.p = _p
	job.q = _q
	job.pivot = _pivot
	job.scale_p = _safe_scale(_scale_p)
	job.scale_q = _safe_scale(_scale_q)
	job.uniform = _settings.uniform
	return job
