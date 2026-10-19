extends "./TransformTool.gd"

const TransformDialog := preload("./TransformDialog.gd")

const QUARTER := PI / 2.0
const DEGREE := PI / 180.0
const MAGNETIC_PULL := DEGREE * 2.0

var _axis := 1
var _axis_sign := 1.0
var _pivot := Vector3.ZERO
var _v0 := Vector3.ZERO
var _angle := 0.0
var _euler := Vector3.ZERO
var _gesture_base_euler := Vector3.ZERO
var _job_euler := Vector3.ZERO

class RotateJob extends TransformJob:
	var axis := 1
	var axis_sign := 1.0
	var pivot := Vector3.ZERO
	var angle := 0.0
	# Total rotation as XYZ Euler angles in radians. Applies Z first, then Y, then X.
	var euler := Vector3.ZERO
	var _candidate_total := 0
	var _candidate_completed := 0

	func estimated_work() -> int:
		var single := _euler_single()
		if not single[0]:
			if _is_cardinal():
				return source_positions.size()
			var extent := source_bounds.size.x + source_bounds.size.y + source_bounds.size.z + 6.0
			return maxi(source_positions.size(), ceili(extent * extent * extent))
		return _single_estimated_work(single[1], single[2])

	# True when every Euler component is a whole quarter turn.
	func _is_cardinal() -> bool:
		for i in 3:
			var turns: float = euler[i] / QUARTER
			if not is_equal_approx(turns, roundf(turns)):
				return false
		return true

	func _single_estimated_work(single_angle: float, single_axis: int) -> int:
		if is_equal_approx(single_angle / QUARTER, roundf(single_angle / QUARTER)):
			return source_positions.size()
		var p := (single_axis + 1) % 3
		var q := (single_axis + 2) % 3
		var span := source_bounds.size[p] + source_bounds.size[q] + 4
		return maxi(source_positions.size(), ceili(span * span * source_bounds.size[single_axis]))

	# Splits the Euler triple into one single-axis rotation when only one
	# component turns. Returns [is_single, angle, axis, axis_sign].
	func _euler_single() -> Array:
		var count := 0
		var index := 0
		for i in 3:
			if absf(euler[i]) > 0.000000001:
				count += 1
				index = i
		if count > 1:
			return [false, 0.0, 0, 1.0]
		if count == 0:
			return [true, 0.0, axis, 1.0]
		var component: float = euler[index]
		return [true, absf(component), index, signf(component)]

	func compute_destination() -> void:
		if source_positions.is_empty():
			return
		var single := _euler_single()
		if not single[0]:
			_compute_euler_3d()
			return
		angle = single[1]
		axis = single[2]
		axis_sign = single[3]
		if is_equal_approx(angle / QUARTER, roundf(angle / QUARTER)):
			_compute_exact()
		else:
			_compute_smooth()

	func _compute_euler_3d() -> void:
		if _is_cardinal():
			_compute_euler_cardinal()
			return
		var selected := {}
		if track_selection:
			stage("Preparing rotation selection", source_positions.size())
			for cell_position in source_positions:
				selected[cell_position] = true
		var basis := Basis(Vector3.RIGHT, euler.x) * Basis(Vector3.UP, euler.y) * Basis(Vector3.BACK, euler.z)
		var inverse := basis.inverse()
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for i in 8:
			var corner := Vector3(
				source_bounds.position.x if i & 1 == 0 else source_bounds.end.x,
				source_bounds.position.y if i & 2 == 0 else source_bounds.end.y,
				source_bounds.position.z if i & 4 == 0 else source_bounds.end.z)
			var rotated := pivot + basis * (corner - pivot)
			lo = lo.min(rotated)
			hi = hi.max(rotated)
		var min_d := Vector3i(ceili(lo.x - 0.5), ceili(lo.y - 0.5), ceili(lo.z - 0.5))
		var max_d := Vector3i(floori(hi.x + 0.5), floori(hi.y + 0.5), floori(hi.z + 0.5))
		_candidate_total = (max_d.x - min_d.x + 1) * (max_d.y - min_d.y + 1) * (max_d.z - min_d.z + 1)
		stage("Calculating rotation", _candidate_total)
		for dz in range(min_d.z, max_d.z + 1):
			for dy in range(min_d.y, max_d.y + 1):
				for dx in range(min_d.x, max_d.x + 1):
					var destination := Vector3i(dx, dy, dz)
					var source_point := inverse * (Vector3(destination) - pivot) + pivot
					var source := Vector3i(roundi(source_point.x), roundi(source_point.y), roundi(source_point.z))
					var color: Color = source_colors.get(source, Color.TRANSPARENT)
					if color != Color.TRANSPARENT:
						destination_colors[destination] = color
						if source_materials.has(source):
							destination_materials[destination] = source_materials[source]
					if track_selection and selected.has(source):
						destination_selection[destination] = true
					_candidate_completed += 1
					if _candidate_completed % 4096 == 0 and not checkpoint(_candidate_completed):
						return

	# Cardinal multi-axis rotation. The rotation matrix rounds to a signed
	# permutation, so cells permute within the source box. No voxel is lost.
	func _compute_euler_cardinal() -> void:
		var min_c := Vector3i(source_bounds.position + Vector3.ONE * 0.5)
		var max_c := Vector3i(source_bounds.end - Vector3.ONE * 0.5)
		var widths := max_c - min_c + Vector3i.ONE
		var basis := Basis(Vector3.RIGHT, euler.x) * Basis(Vector3.UP, euler.y) * Basis(Vector3.BACK, euler.z)
		var perm := Vector3i(-1, -1, -1)
		var axis_signs := Vector3i(1, 1, 1)
		for source_axis in 3:
			var image: Vector3 = basis[source_axis]
			for dest_axis in 3:
				if absf(image[dest_axis]) > 0.5:
					perm[dest_axis] = source_axis
					axis_signs[dest_axis] = 1 if image[dest_axis] > 0.0 else -1
		stage("Calculating rotation", source_positions.size())
		var completed := 0
		for source in source_positions:
			var local := source - min_c
			var mapped := Vector3i.ZERO
			for dest_axis in 3:
				var source_axis: int = perm[dest_axis]
				if axis_signs[dest_axis] > 0:
					mapped[dest_axis] = local[source_axis]
				else:
					mapped[dest_axis] = (widths[source_axis] - 1) - local[source_axis]
			var destination := min_c + mapped
			if source_colors.has(source):
				destination_colors[destination] = source_colors[source]
				if source_materials.has(source):
					destination_materials[destination] = source_materials[source]
			if track_selection:
				destination_selection[destination] = true
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return

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
			var destination := _rotate_cell(source, p, q, min_c, max_c, direction, turns)
			if source_colors.has(source):
				destination_colors[destination] = source_colors[source]
				if source_materials.has(source):
					destination_materials[destination] = source_materials[source]
			if track_selection:
				destination_selection[destination] = true
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
		var material_layers := {}
		var selection_layers := {}
		stage("Preparing rotation", source_positions.size())
		var completed := 0
		for source in source_positions:
			var layer: int = source[axis]
			if track_selection:
				if not selection_layers.has(layer):
					selection_layers[layer] = {}
				selection_layers[layer][Vector2i(source[p], source[q])] = Color.WHITE
				if not layers.has(layer):
					layers[layer] = {}
			if source_colors.has(source):
				if not layers.has(layer):
					layers[layer] = {}
				layers[layer][Vector2i(source[p], source[q])] = source_colors[source]
				if not material_layers.has(layer):
					material_layers[layer] = {}
				material_layers[layer][Vector2i(source[p], source[q])] = source_materials[source]
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return
		var layer_results := {}
		var selection_results := {}
		var natural_min := Vector2i.ZERO
		var first := true
		stage("Calculating rotation", layers.size())
		completed = 0
		for layer in layers:
			var destination_layer := {}
			if not layers[layer].is_empty():
				var sampler := RotSprite.new(layers[layer])
				destination_layer = sampler.rotate(pivot2d, direction * angle)
			layer_results[layer] = destination_layer
			var alignment_layer := destination_layer
			if track_selection:
				var sampler := RotSprite.new(selection_layers[layer])
				selection_results[layer] = sampler.rotate(pivot2d, direction * angle)
				alignment_layer = selection_results[layer]
			for uv: Vector2i in alignment_layer:
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
				var source_uv := _source_cell(uv, pivot2d, direction * angle)
				var layer_materials: Dictionary = material_layers.get(layer, {})
				var cell_material: PackedFloat32Array = layer_materials.get(source_uv, VoxelFrame.material(layer_results[layer][uv]))
				cell_material = cell_material.duplicate()
				# Scale2x can select a neighbor's color. Keep that sampled color.
				var color: Color = layer_results[layer][uv]
				cell_material[VoxelFrame.MATERIAL_COLOR] = color.r
				cell_material[VoxelFrame.MATERIAL_COLOR + 1] = color.g
				cell_material[VoxelFrame.MATERIAL_COLOR + 2] = color.b
				cell_material[VoxelFrame.MATERIAL_COLOR + 3] = color.a
				destination_materials[destination] = cell_material
				if track_selection:
					destination_selection[destination] = true
			if track_selection:
				for uv: Vector2i in selection_results[layer]:
					var destination := Vector3i.ZERO
					destination[axis] = layer
					destination[p] = uv.x + correction.x
					destination[q] = uv.y + correction.y
					destination_selection[destination] = true
			if not checkpoint(completed):
				return

	# The source cell that a rotated cell samples. A material follows the nearest source cell.
	func _source_cell(cell: Vector2i, pivot2d: Vector2, angle: float) -> Vector2i:
		var center := Vector2(cell) + Vector2(0.5, 0.5)
		var back := (center - pivot2d).rotated(-angle) + pivot2d
		return Vector2i(floori(back.x), floori(back.y))


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
	_job_euler = Vector3.ZERO
	if _was_pending:
		_gesture_base_euler = _euler
	else:
		_euler = Vector3.ZERO
		_gesture_base_euler = Vector3.ZERO


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
	var single := Vector3.ZERO
	single[_axis] = _axis_sign * _angle
	# The gesture turns the cells as they are now, so the job uses one axis only.
	_job_euler = single
	# The dialog reports a running total. It adds up while the view axis stays the same.
	if _base_matches_axis(_gesture_base_euler, _axis):
		var running := _gesture_base_euler
		running[_axis] = _gesture_base_euler[_axis] + _axis_sign * _angle
		_euler = running
	else:
		_euler = single
	return true


# True when the base rotation is zero or turns about this axis alone.
func _base_matches_axis(base: Vector3, axis: int) -> bool:
	for i in 3:
		if i != axis and absf(base[i]) > 0.000000001:
			return false
	return true


func _make_job() -> TransformJob:
	var job := RotateJob.new()
	job.pivot = _pivot
	job.euler = _job_euler
	return job


func _on_click_without_drag() -> bool:
	if _grab_waiting or _preview_running:
		return false
	if _was_pending and _has_base:
		_restore_grab_baseline()
		_pending = true
		_job_euler = _euler
		_open_rotate_dialog(_euler_degrees())
		return true
	if _cells.is_empty():
		return false
	_pending = true
	_euler = Vector3.ZERO
	_job_euler = Vector3.ZERO
	_open_rotate_dialog(Vector3.ZERO)
	return true


func _euler_degrees() -> Vector3:
	return Vector3(rad_to_deg(_euler.x), rad_to_deg(_euler.y), rad_to_deg(_euler.z))


func _did_restore_baseline() -> void:
	_pivot = _source_bbox().get_center()


func _connect_tool_dialog() -> void:
	_dialog.connect("values_changed", _on_dialog_values)
	_dialog.connect("confirmed", _on_dialog_confirmed)
	_dialog.connect("canceled", _on_dialog_canceled)


func _open_rotate_dialog(angles_deg: Vector3) -> void:
	_ensure_tool_dialog()
	_dialog.open_for_rotate(angles_deg)
	_dialog.popup_centered()
	_record_dialog_open({TransformDialog.KEY_VALUES: angles_deg, TransformDialog.KEY_AXIS: -1, TransformDialog.KEY_UNIFORM: false})


func _on_dialog_values(state: Dictionary) -> void:
	var raw: Vector3 = state[TransformDialog.KEY_VALUES]
	var angles := Vector3(deg_to_rad(raw.x), deg_to_rad(raw.y), deg_to_rad(raw.z))
	if angles.is_equal_approx(_euler):
		return
	_euler = angles
	_job_euler = angles
	_dialog_dirty = true
	_apply_preview()


func _on_dialog_confirmed() -> void:
	if _euler.is_zero_approx() and not _dragged and not _was_pending:
		_cancel()


func _on_dialog_canceled() -> void:
	if _dialog_open_had_pending:
		if _dialog_dirty:
			_dialog_dirty = false
			var raw: Vector3 = _dialog_open_values[TransformDialog.KEY_VALUES]
			var open := Vector3(deg_to_rad(raw.x), deg_to_rad(raw.y), deg_to_rad(raw.z))
			if not open.is_equal_approx(_euler):
				_euler = open
				_job_euler = open
				_apply_preview()
		return
	_cancel()


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
