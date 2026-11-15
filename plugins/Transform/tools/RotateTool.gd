extends "./TransformTool.gd"

## The rotate transform tool.
##
## A drag rotates the source around its bounds center. The axis is the view
## normal or the nearest world axis. A smooth angle turns around the centre. An
## exact quarter turn permutes from the source low corner, then recentres on the
## pivot. Smooth and exact turns round a half-cell tie toward zero, so the snap
## keeps the same anchor. A click opens the rotate dialog for exact angles. Any
## other angle uses [RotSprite].

const TransformDialog := preload("./TransformDialog.gd")

## One quarter turn in radians.
const QUARTER := PI / 2.0
## One degree in radians.
const DEGREE := PI / 180.0
## The magnetic pull to the nearest quarter turn, in radians.
const MAGNETIC_PULL := DEGREE * 2.0

var _view_normal := Vector3.BACK
var _pivot := Vector3.ZERO
var _v0 := Vector3.ZERO
var _angle := 0.0
var _euler := Vector3.ZERO
var _total_basis := Basis.IDENTITY
var _gesture_base_basis := Basis.IDENTITY
var _job_axis := Vector3.ZERO
var _job_angle := 0.0

## One cancellable rotate transform job.
##
## A quarter turn permutes the cell indices, so no voxel is lost. Any other
## angle samples the source with [RotSprite].
## [method TransformJob.compute_destination] is overridden.
class RotateJob extends TransformJob:
	## The rotation axis.
	var axis := 1
	## The rotation direction on the axis.
	var axis_sign := 1.0
	## A rotation axis that is not a world axis. A zero vector uses [member euler].
	var axis_vector := Vector3.ZERO
	## The rotation angle in radians about [member axis_vector].
	var angle_radians := 0.0
	## The pivot in cell units.
	var pivot := Vector3.ZERO
	## The single-axis angle in radians.
	var angle := 0.0
	# Total rotation as XYZ Euler angles in radians. Applies Z first, then Y, then X.
	## The total rotation as XYZ Euler angles in radians. It applies Z first, then
	## Y, then X.
	var euler := Vector3.ZERO
	## The dot product above which an axis counts as a world axis. It matches the
	## tool dead zone of about two degrees.
	const AXIS_DOT := 0.99939
	var _candidate_total := 0
	var _candidate_completed := 0

	func estimated_work() -> int:
		if not axis_vector.is_zero_approx():
			return _axis_estimated_work()
		var single := _euler_single()
		if not single[0]:
			if _is_cardinal():
				return source_positions.size()
			var extent := source_bounds.size.x + source_bounds.size.y + source_bounds.size.z + 6.0
			return maxi(source_positions.size(), ceili(extent * extent * extent))
		return _single_estimated_work(single[1], single[2])

	func _axis_estimated_work() -> int:
		var normal := axis_vector.normalized()
		var world_axis := _world_axis(normal)
		if world_axis >= 0:
			var magnitude := absf(angle_radians)
			if is_equal_approx(magnitude / QUARTER, roundf(magnitude / QUARTER)):
				return source_positions.size()
			return _single_estimated_work(magnitude, world_axis)
		var extent := source_bounds.size.x + source_bounds.size.y + source_bounds.size.z + 6.0
		return maxi(source_positions.size(), ceili(extent * extent * extent))

	# Returns the world axis that a unit normal faces, or -1 when it is not close.
	func _world_axis(normal: Vector3) -> int:
		var index := normal.abs().max_axis_index()
		if absf(normal[index]) >= AXIS_DOT:
			return index
		return -1

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
		if not axis_vector.is_zero_approx():
			_compute_axis_angle()
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

	func _compute_axis_angle() -> void:
		var normal := axis_vector.normalized()
		var world_axis := _world_axis(normal)
		if world_axis >= 0:
			axis = world_axis
			# The axis sign carries the drag direction, so a negative angle
			# turns the shape the other way.
			axis_sign = (1.0 if normal[world_axis] > 0.0 else -1.0) * (1.0 if angle_radians >= 0.0 else -1.0)
			angle = absf(angle_radians)
			if is_equal_approx(angle / QUARTER, roundf(angle / QUARTER)):
				_compute_exact()
			else:
				_compute_smooth()
			return
		_compute_basis(Basis(normal, angle_radians))

	func _compute_euler_3d() -> void:
		if _is_cardinal():
			_compute_euler_cardinal()
			return
		_compute_basis(Basis(Vector3.RIGHT, euler.x) * Basis(Vector3.UP, euler.y) * Basis(Vector3.BACK, euler.z))

	func _compute_basis(basis: Basis) -> void:
		var selected := {}
		if track_selection:
			stage("Preparing rotation selection", source_positions.size())
			for cell_position in source_positions:
				selected[cell_position] = true
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
		_recenter_exact()

	# The exact permutation starts at the source low corner. Move the whole
	# result so its bounds centre sits on the pivot. The shift is whole cells.
	func _recenter_exact() -> void:
		var keys: Array = destination_selection.keys() if track_selection else destination_colors.keys()
		if keys.is_empty():
			return
		var low := Vector3i.MAX
		var high := Vector3i.MIN
		for key in keys:
			low = low.min(key)
			high = high.max(key)
		var center := (Vector3(low) + Vector3(high)) * 0.5
		var offset := Vector3i(
			_round_half_to_zero(pivot.x - center.x),
			_round_half_to_zero(pivot.y - center.y),
			_round_half_to_zero(pivot.z - center.z))
		if offset == Vector3i.ZERO:
			return
		destination_colors = _shift_keys(destination_colors, offset)
		destination_materials = _shift_keys(destination_materials, offset)
		destination_selection = _shift_keys(destination_selection, offset)

	func _shift_keys(source: Dictionary, offset: Vector3i) -> Dictionary:
		var shifted := {}
		for key in source:
			shifted[key + offset] = source[key]
		return shifted

	# Rounds a half towards zero. The smooth and exact paths use the same rule,
	# so the snap at a cardinal angle does not move the model by one cell.
	func _round_half_to_zero(value: float) -> int:
		var lower := floorf(value)
		var fraction := value - lower
		if fraction < 0.5:
			return int(lower)
		if fraction > 0.5:
			return int(lower + 1.0)
		return int(lower) if value > 0.0 else int(lower + 1.0)

	# Permute cell indices with the source low corner as the origin to keep
	# cardinal rotations exact. The caller recentres the result on the pivot.
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
		var low := Vector2i.MAX
		var high := Vector2i.MIN
		var has_output := false
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
				has_output = true
				low = low.min(uv)
				high = high.max(uv)
			completed += 1
			if not checkpoint(completed):
				return
		if not has_output:
			return
		# Match the exact turn's recentre so the snap at a cardinal angle does
		# not move the model.
		var center := Vector2((low.x + high.x) * 0.5, (low.y + high.y) * 0.5)
		var correction := Vector2i(
			_round_half_to_zero(pivot2d.x - center.x),
			_round_half_to_zero(pivot2d.y - center.y))
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
	_view_normal = _drag_normal()
	_plane = _drag_plane_through(_pivot)
	var v := _cursor_vec(origin, dir)
	if v.is_zero_approx():
		v = _fallback_vec()
	_v0 = v.normalized()
	_angle = 0.0
	_job_axis = Vector3.ZERO
	_job_angle = 0.0
	if _was_pending:
		_gesture_base_basis = _total_basis
	else:
		_euler = Vector3.ZERO
		_total_basis = Basis.IDENTITY
		_gesture_base_basis = Basis.IDENTITY


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
	# The gesture turns the cells as they are now. The job rotates about the
	# captured normal, so any axis works.
	_job_axis = _view_normal
	_job_angle = _angle
	# The dialog reports a running total. Compose the gesture with the base
	# rotation so the total stays right across grabs and view changes.
	_total_basis = Basis(_view_normal, _angle) * _gesture_base_basis
	_euler = _total_basis.get_euler(EULER_ORDER_XYZ)
	return true


func _make_job() -> TransformJob:
	var job := RotateJob.new()
	job.pivot = _pivot
	if not _job_axis.is_zero_approx():
		job.axis_vector = _job_axis
		job.angle_radians = _job_angle
	else:
		job.euler = _euler
	return job


func _on_click_without_drag() -> bool:
	if _grab_waiting or _preview_running:
		return false
	if _was_pending and _has_base:
		_restore_grab_baseline()
		_pending = true
		_job_axis = Vector3.ZERO
		_job_angle = 0.0
		_total_basis = Basis.from_euler(_euler, EULER_ORDER_XYZ)
		_open_rotate_dialog(_euler_degrees())
		return true
	if _cells.is_empty():
		return false
	_pending = true
	_euler = Vector3.ZERO
	_total_basis = Basis.IDENTITY
	_job_axis = Vector3.ZERO
	_job_angle = 0.0
	_open_rotate_dialog(Vector3.ZERO)
	return true


func _euler_degrees() -> Vector3:
	return Vector3(rad_to_deg(_euler.x), rad_to_deg(_euler.y), rad_to_deg(_euler.z))


func _did_restore_baseline() -> void:
	_pivot = _source_bbox().get_center()
	_total_basis = Basis.from_euler(_euler, EULER_ORDER_XYZ)


func _clear_grab() -> void:
	_view_normal = Vector3.BACK
	_euler = Vector3.ZERO
	_job_axis = Vector3.ZERO
	_job_angle = 0.0
	_total_basis = Basis.IDENTITY
	_gesture_base_basis = Basis.IDENTITY
	super._clear_grab()


func _gizmo_pivot() -> Vector3:
	if _gizmo_grab_ready and (_dragging or _pending):
		return _pivot
	return super._gizmo_pivot()


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
	_total_basis = Basis.from_euler(angles, EULER_ORDER_XYZ)
	_job_axis = Vector3.ZERO
	_job_angle = 0.0
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
				_total_basis = Basis.from_euler(open, EULER_ORDER_XYZ)
				_job_axis = Vector3.ZERO
				_job_angle = 0.0
				_apply_preview()
		return
	_cancel()


func _cursor_vec(origin: Vector3, dir: Vector3) -> Vector3:
	var rel := _plane_point(origin, dir) - _pivot
	return rel - _view_normal * rel.dot(_view_normal)


func _signed_angle(a: Vector3, b: Vector3) -> float:
	return atan2(a.cross(b).dot(_view_normal), a.dot(b))


func _fallback_vec() -> Vector3:
	var right := _grab_camera_right - _view_normal * _grab_camera_right.dot(_view_normal)
	if not right.is_zero_approx():
		return right.normalized()
	var fallback := Vector3.ZERO
	fallback[(_view_normal.abs().max_axis_index() + 1) % 3] = 1.0
	return fallback
