extends RefCounted


const KIND_BOX := 0
const KIND_ELLIPSOID := 1
const KIND_CONE := 2

const OP_ADD := 0
const OP_SUBTRACT := 1
const OP_INTERSECT := 2

const MAX_PRIMITIVES := 64
const MAX_PRIMITIVE_CELLS := 1_048_576
const MAX_BLEND_CELLS := 2_000_000
const EPSILON := 1e-6
const FAR_DISTANCE := 1.0e9
const SQRT_2 := 1.41421356
const SQRT_3 := 1.73205081


static func sdf_box(point: Vector3, center: Vector3, half_size: Vector3) -> float:
	var q := point - center
	q = Vector3(absf(q.x) - half_size.x, absf(q.y) - half_size.y, absf(q.z) - half_size.z)
	var outside := Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0))
	return outside.length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)


static func sdf_round_box(point: Vector3, center: Vector3, half_size: Vector3, roundness: float) -> float:
	var radius := clampf(roundness, 0.0, 1.0) * minf(half_size.x, minf(half_size.y, half_size.z))
	var inner := Vector3(
		maxf(half_size.x - radius, 0.0),
		maxf(half_size.y - radius, 0.0),
		maxf(half_size.z - radius, 0.0)
	)
	return sdf_box(point, center, inner) - radius


static func sdf_ellipsoid(point: Vector3, center: Vector3, radii: Vector3) -> float:
	var safe := Vector3(maxf(radii.x, EPSILON), maxf(radii.y, EPSILON), maxf(radii.z, EPSILON))
	var scaled := (point - center) / safe
	return (scaled.length() - 1.0) * minf(safe.x, minf(safe.y, safe.z))


static func sdf_cone_round(point: Vector3, a: Vector3, b: Vector3, r1: float, r2: float) -> float:
	var ba := b - a
	var l2 := ba.length_squared()
	if l2 <= EPSILON:
		return point.distance_to(a) - maxf(r1, r2)
	var rr := r1 - r2
	var a2 := l2 - rr * rr
	if a2 <= 0.0:
		return minf(point.distance_to(a) - r1, point.distance_to(b) - r2)
	var il2 := 1.0 / l2
	var pa := point - a
	var y := pa.dot(ba)
	var z := y - l2
	var xv := pa * l2 - ba * y
	var x2 := xv.length_squared()
	var y2 := y * y * l2
	var z2 := z * z * l2
	var k := signf(rr) * rr * rr * x2
	if signf(z) * a2 * z2 > k:
		return sqrt(x2 + z2) * il2 - r2
	if signf(y) * a2 * y2 < k:
		return sqrt(x2 + y2) * il2 - r1
	return (sqrt(x2 * a2 * il2) + y * rr) * il2 - r1


static func sdf_cone_flat(point: Vector3, a: Vector3, b: Vector3, r1: float, r2: float) -> float:
	var ba := b - a
	var l2 := ba.length_squared()
	if l2 <= EPSILON:
		return point.distance_to(a) - maxf(r1, r2)
	var length := sqrt(l2)
	var axis := ba / length
	var center := (a + b) * 0.5
	var half_length := length * 0.5
	var local := point - center
	var y := local.dot(axis)
	var radial := (local - axis * y).length()
	return _sdf_capped_cone(radial, y, half_length, r1, r2)


static func smin(first: float, second: float, blur: float) -> float:
	if blur <= 0.0:
		return minf(first, second)
	var h := maxf(blur - absf(first - second), 0.0) / blur
	return minf(first, second) - h * h * blur * 0.25


static func primitive_rotation(primitive: Dictionary) -> Quaternion:
	var value: Variant = primitive.get("rotation", null)
	return value if value is Quaternion else Quaternion.IDENTITY


static func primitive_distance(primitive: Dictionary, point: Vector3) -> float:
	var kind := int(primitive.get("kind", KIND_BOX))
	var rotation := primitive_rotation(primitive)
	match kind:
		KIND_ELLIPSOID:
			var center: Vector3 = primitive.get("center", Vector3.ZERO)
			var radii: Vector3 = primitive.get("radii", Vector3.ONE)
			var local := rotation.inverse() * (point - center)
			return sdf_ellipsoid(local, Vector3.ZERO, radii)
		KIND_CONE:
			var a: Vector3 = primitive.get("a", Vector3.ZERO)
			var b: Vector3 = primitive.get("b", Vector3.ZERO)
			var mid := (a + b) * 0.5
			a = mid + rotation * (a - mid)
			b = mid + rotation * (b - mid)
			var r1 := float(primitive.get("r1", 0.0))
			var r2 := float(primitive.get("r2", 0.0))
			var roundness := float(primitive.get("roundness", 1.0 if bool(primitive.get("round", false)) else 0.0))
			roundness = clampf(roundness, 0.0, 1.0)
			var flat := sdf_cone_flat(point, a, b, r1, r2)
			if roundness <= 0.0:
				return flat
			var round := sdf_cone_round(point, a, b, r1, r2)
			if roundness >= 1.0:
				return round
			return lerpf(flat, round, roundness)
		_:
			var center: Vector3 = primitive.get("center", Vector3.ZERO)
			var half_size: Vector3 = primitive.get("half_size", Vector3.ONE)
			var roundness := float(primitive.get("roundness", 0.0))
			var local := rotation.inverse() * (point - center)
			return sdf_round_box(local, Vector3.ZERO, half_size, roundness)


static func field_distance(request: Dictionary, point: Vector3) -> float:
	var primitives_value: Variant = request.get("primitives", [])
	if not (primitives_value is Array):
		return 1.0
	var primitives: Array = primitives_value
	if primitives.is_empty():
		return 1.0
	var smooth := effective_smooth(request)
	var distance := primitive_distance(primitives[0], point)
	for index in range(1, primitives.size()):
		var next := primitive_distance(primitives[index], point)
		distance = smin(distance, next, smooth) if smooth > 0.0 else minf(distance, next)
	var shell := maxf(float(request.get("shell", 0.0)), 0.0)
	if shell > 0.0:
		distance = maxf(absf(distance) - shell, distance)
	return distance


static func _prepare_distance(request: Dictionary) -> Dictionary:
	var primitives_value: Variant = request.get("primitives", [])
	var prepared: Array = []
	if primitives_value is Array:
		var primitives: Array = primitives_value
		for index in range(primitives.size()):
			var value: Variant = primitives[index]
			if value is Dictionary:
				prepared.append(_prepare_primitive(value))
	var smooth := effective_smooth(request)
	var shell := maxf(float(request.get("shell", 0.0)), 0.0)
	return {"primitives": prepared, "smooth": smooth, "shell": shell}


static func _prepare_primitive(primitive: Dictionary) -> Dictionary:
	var kind := int(primitive.get("kind", KIND_BOX))
	var rotation := primitive_rotation(primitive)
	match kind:
		KIND_ELLIPSOID:
			var center: Vector3 = primitive.get("center", Vector3.ZERO)
			var radii: Vector3 = primitive.get("radii", Vector3.ONE)
			var safe := Vector3(maxf(radii.x, EPSILON), maxf(radii.y, EPSILON), maxf(radii.z, EPSILON))
			return {
				"kind": KIND_ELLIPSOID,
				"inverse": rotation.inverse(),
				"center": center,
				"safe": safe,
				"smallest": minf(safe.x, minf(safe.y, safe.z)),
			}
		KIND_CONE:
			var a: Vector3 = primitive.get("a", Vector3.ZERO)
			var b: Vector3 = primitive.get("b", Vector3.ZERO)
			var mid := (a + b) * 0.5
			a = mid + rotation * (a - mid)
			b = mid + rotation * (b - mid)
			var r1 := float(primitive.get("r1", 0.0))
			var r2 := float(primitive.get("r2", 0.0))
			var roundness := float(primitive.get("roundness", 1.0 if bool(primitive.get("round", false)) else 0.0))
			roundness = clampf(roundness, 0.0, 1.0)
			return {
				"kind": KIND_CONE,
				"a": a,
				"b": b,
				"r1": r1,
				"r2": r2,
				"roundness": roundness,
			}
		_:
			var center: Vector3 = primitive.get("center", Vector3.ZERO)
			var half_size: Vector3 = primitive.get("half_size", Vector3.ONE)
			var roundness := float(primitive.get("roundness", 0.0))
			var radius := clampf(roundness, 0.0, 1.0) * minf(half_size.x, minf(half_size.y, half_size.z))
			var inner := Vector3(
				maxf(half_size.x - radius, 0.0),
				maxf(half_size.y - radius, 0.0),
				maxf(half_size.z - radius, 0.0)
			)
			return {
				"kind": KIND_BOX,
				"inverse": rotation.inverse(),
				"center": center,
				"inner": inner,
				"radius": radius,
			}


static func _prepared_field_distance(prepared: Dictionary, point: Vector3) -> float:
	var primitives: Array = prepared["primitives"]
	if primitives.is_empty():
		return 1.0
	var smooth: float = prepared["smooth"]
	var first: Dictionary = primitives[0]
	var distance := _prepared_primitive_distance(first, point)
	for index in range(1, primitives.size()):
		var next: Dictionary = primitives[index]
		var next_distance := _prepared_primitive_distance(next, point)
		distance = smin(distance, next_distance, smooth) if smooth > 0.0 else minf(distance, next_distance)
	var shell: float = prepared["shell"]
	if shell > 0.0:
		distance = maxf(absf(distance) - shell, distance)
	return distance


static func _prepared_primitive_distance(primitive: Dictionary, point: Vector3) -> float:
	var kind: int = primitive["kind"]
	match kind:
		KIND_ELLIPSOID:
			var safe: Vector3 = primitive["safe"]
			var smallest: float = primitive["smallest"]
			var local: Vector3 = primitive["inverse"] * (point - primitive["center"])
			var scaled := local / safe
			return (scaled.length() - 1.0) * smallest
		KIND_CONE:
			var a: Vector3 = primitive["a"]
			var b: Vector3 = primitive["b"]
			var r1: float = primitive["r1"]
			var r2: float = primitive["r2"]
			var roundness: float = primitive["roundness"]
			var flat := sdf_cone_flat(point, a, b, r1, r2)
			if roundness <= 0.0:
				return flat
			var round := sdf_cone_round(point, a, b, r1, r2)
			if roundness >= 1.0:
				return round
			return lerpf(flat, round, roundness)
		_:
			var inner: Vector3 = primitive["inner"]
			var radius: float = primitive["radius"]
			var local: Vector3 = primitive["inverse"] * (point - primitive["center"])
			var q := Vector3(absf(local.x) - inner.x, absf(local.y) - inner.y, absf(local.z) - inner.z)
			var outside := Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0))
			return outside.length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0) - radius


static func effective_smooth(request: Dictionary) -> float:
	var requested := maxf(float(request.get("smooth", 0.0)), 0.0)
	if requested <= 0.0 or int(request.get("op", OP_ADD)) != OP_ADD:
		return 0.0
	var extent := smallest_extent(request)
	if extent <= 0.0:
		return 0.0
	return minf(requested, extent * 0.5)


static func smallest_extent(request: Dictionary) -> float:
	var primitives_value: Variant = request.get("primitives", [])
	if not (primitives_value is Array):
		return 0.0
	var primitives: Array = primitives_value
	var result := INF
	for value in primitives:
		var primitive: Dictionary = value
		var kind := int(primitive.get("kind", KIND_BOX))
		var extent := 0.0
		match kind:
			KIND_ELLIPSOID:
				var radii: Vector3 = primitive.get("radii", Vector3.ONE)
				extent = minf(radii.x, minf(radii.y, radii.z)) * 2.0
			KIND_CONE:
				var a: Vector3 = primitive.get("a", Vector3.ZERO)
				var b: Vector3 = primitive.get("b", Vector3.ZERO)
				var r1 := float(primitive.get("r1", 0.0))
				var r2 := float(primitive.get("r2", 0.0))
				extent = minf(a.distance_to(b), maxf(r1, r2) * 2.0)
			_:
				var half_size: Vector3 = primitive.get("half_size", Vector3.ONE)
				extent = minf(half_size.x, minf(half_size.y, half_size.z)) * 2.0
		if extent > 0.0:
			result = minf(result, extent)
	return 0.0 if result == INF else result


static func primitive_bounds(primitive: Dictionary) -> AABB:
	var kind := int(primitive.get("kind", KIND_BOX))
	var rotation := primitive_rotation(primitive)
	match kind:
		KIND_ELLIPSOID:
			var center: Vector3 = primitive.get("center", Vector3.ZERO)
			var radii: Vector3 = primitive.get("radii", Vector3.ONE)
			var extent := _rotated_extent(rotation, radii)
			return AABB(center - extent, extent * 2.0)
		KIND_CONE:
			var a: Vector3 = primitive.get("a", Vector3.ZERO)
			var b: Vector3 = primitive.get("b", Vector3.ZERO)
			var mid := (a + b) * 0.5
			a = mid + rotation * (a - mid)
			b = mid + rotation * (b - mid)
			var r1 := maxf(float(primitive.get("r1", 0.0)), 0.0)
			var r2 := maxf(float(primitive.get("r2", 0.0)), 0.0)
			var low := Vector3(minf(a.x - r1, b.x - r2), minf(a.y - r1, b.y - r2), minf(a.z - r1, b.z - r2))
			var high := Vector3(maxf(a.x + r1, b.x + r2), maxf(a.y + r1, b.y + r2), maxf(a.z + r1, b.z + r2))
			return AABB(low, high - low)
		_:
			var center: Vector3 = primitive.get("center", Vector3.ZERO)
			var half_size: Vector3 = primitive.get("half_size", Vector3.ONE)
			var extent := _rotated_extent(rotation, half_size)
			return AABB(center - extent, extent * 2.0)


static func _rotated_extent(rotation: Quaternion, extent: Vector3) -> Vector3:
	var basis := Basis(rotation)
	return Vector3(
		absf(basis.x.x) * extent.x + absf(basis.y.x) * extent.y + absf(basis.z.x) * extent.z,
		absf(basis.x.y) * extent.x + absf(basis.y.y) * extent.y + absf(basis.z.y) * extent.z,
		absf(basis.x.z) * extent.x + absf(basis.y.z) * extent.y + absf(basis.z.z) * extent.z,
	)


static func shape_bounds(request: Dictionary) -> AABB:
	var primitives_value: Variant = request.get("primitives", [])
	if not (primitives_value is Array):
		return AABB()
	var primitives: Array = primitives_value
	var bounds := AABB()
	for value in primitives:
		var primitive: Dictionary = value
		var primitive_box := primitive_bounds(primitive)
		bounds = primitive_box if not bounds.has_volume() else bounds.merge(primitive_box)
	if not bounds.has_volume():
		return AABB()
	var padding := effective_smooth(request)
	padding += maxf(float(request.get("shell", 0.0)), 0.0)
	return AABB(bounds.position - Vector3.ONE * padding, bounds.size + Vector3.ONE * padding * 2.0)


static func shape_cell_bounds(request: Dictionary) -> Array:
	var bounds := shape_bounds(request)
	if not bounds.has_volume():
		return []
	var limit := VoxelFrame.MAX_CHUNK_COORDINATE * VoxelFrame.CHUNK_SIZE
	var min_cell := Vector3i(ceili(bounds.position.x), ceili(bounds.position.y), ceili(bounds.position.z))
	var max_cell := Vector3i(floori(bounds.end.x), floori(bounds.end.y), floori(bounds.end.z))
	min_cell = Vector3i(
		clampi(min_cell.x, -limit, limit),
		clampi(min_cell.y, -limit, limit),
		clampi(min_cell.z, -limit, limit)
	)
	max_cell = Vector3i(
		clampi(max_cell.x, -limit, limit),
		clampi(max_cell.y, -limit, limit),
		clampi(max_cell.z, -limit, limit)
	)
	if min_cell.x > max_cell.x or min_cell.y > max_cell.y or min_cell.z > max_cell.z:
		return []
	return [min_cell, max_cell]


static func field_bounds(request: Dictionary) -> AABB:
	var bounds := shape_bounds(request)
	if not bounds.has_volume():
		return AABB()
	var padding := 1.0 + float(clampi(int(request.get("step", 1)), 1, 4))
	return AABB(bounds.position - Vector3.ONE * padding, bounds.size + Vector3.ONE * padding * 2.0)


static func scan_bounds(request: Dictionary) -> Array:
	var bounds := field_bounds(request)
	if not bounds.has_volume():
		return []
	var limit := VoxelFrame.MAX_CHUNK_COORDINATE * VoxelFrame.CHUNK_SIZE
	var min_cell := Vector3i(floori(bounds.position.x), floori(bounds.position.y), floori(bounds.position.z))
	var max_cell := Vector3i(ceili(bounds.end.x), ceili(bounds.end.y), ceili(bounds.end.z))
	min_cell = Vector3i(
		clampi(min_cell.x, -limit, limit),
		clampi(min_cell.y, -limit, limit),
		clampi(min_cell.z, -limit, limit)
	)
	max_cell = Vector3i(
		clampi(max_cell.x, -limit, limit),
		clampi(max_cell.y, -limit, limit),
		clampi(max_cell.z, -limit, limit)
	)
	if min_cell.x > max_cell.x or min_cell.y > max_cell.y or min_cell.z > max_cell.z:
		return []
	return [min_cell, max_cell]


static func estimated_cells(request: Dictionary) -> int:
	var value := scan_bounds(request)
	if value.is_empty():
		return 0
	var min_cell: Vector3i = value[0]
	var max_cell: Vector3i = value[1]
	var extent := max_cell - min_cell + Vector3i.ONE
	return extent.x * extent.y * extent.z


static func validate_request(request: Dictionary, allow_large := false) -> String:
	var primitives_value: Variant = request.get("primitives", null)
	if not (primitives_value is Array):
		return "primitives must be an array."
	var primitives: Array = primitives_value
	if primitives.is_empty() or primitives.size() > MAX_PRIMITIVES:
		return "primitives must hold 1 to %d entries." % MAX_PRIMITIVES
	for index in range(primitives.size()):
		var value: Variant = primitives[index]
		if not (value is Dictionary):
			return "primitives[%d] must be an object." % index
		var primitive: Dictionary = value
		var kind := int(primitive.get("kind", -1))
		match kind:
			KIND_BOX:
				var center: Variant = primitive.get("center", null)
				var half_size: Variant = primitive.get("half_size", null)
				if not _valid_vector(center) or not _valid_vector(half_size):
					return "primitives[%d] needs center and half_size." % index
				var half: Vector3 = half_size
				if half.x <= 0.0 or half.y <= 0.0 or half.z <= 0.0:
					return "primitives[%d] half_size values must be above zero." % index
				var roundness_value: Variant = primitive.get("roundness", null)
				if roundness_value != null:
					if not (roundness_value is int or roundness_value is float):
						return "primitives[%d] roundness must be a number from 0 to 1." % index
					var roundness := float(roundness_value)
					if not is_finite(roundness) or roundness < 0.0 or roundness > 1.0:
						return "primitives[%d] roundness must be a number from 0 to 1." % index
			KIND_ELLIPSOID:
				var center: Variant = primitive.get("center", null)
				var radii: Variant = primitive.get("radii", null)
				if not _valid_vector(center) or not _valid_vector(radii):
					return "primitives[%d] needs center and radii." % index
				var radius: Vector3 = radii
				if radius.x <= 0.0 or radius.y <= 0.0 or radius.z <= 0.0:
					return "primitives[%d] radii must be above zero." % index
			KIND_CONE:
				var a: Variant = primitive.get("a", null)
				var b: Variant = primitive.get("b", null)
				if not _valid_vector(a) or not _valid_vector(b):
					return "primitives[%d] needs a and b." % index
				var r1_value: Variant = primitive.get("r1", null)
				var r2_value: Variant = primitive.get("r2", null)
				if not (r1_value is int or r1_value is float) or not (r2_value is int or r2_value is float):
					return "primitives[%d] needs r1 and r2." % index
				var r1 := float(r1_value)
				var r2 := float(r2_value)
				if not is_finite(r1) or not is_finite(r2) or r1 < 0.0 or r2 < 0.0:
					return "primitives[%d] radii must be zero or above." % index
				if r1 <= 0.0 and r2 <= 0.0:
					return "primitives[%d] needs at least one radius above zero." % index
				var roundness_value: Variant = primitive.get("roundness", null)
				if roundness_value != null:
					if not (roundness_value is int or roundness_value is float):
						return "primitives[%d] roundness must be a number from 0 to 1." % index
					var roundness := float(roundness_value)
					if not is_finite(roundness) or roundness < 0.0 or roundness > 1.0:
						return "primitives[%d] roundness must be a number from 0 to 1." % index
				var round_value: Variant = primitive.get("round", null)
				if round_value != null and not (round_value is bool):
					return "primitives[%d] round must be a boolean." % index
			_:
				return "primitives[%d] kind must be box, ellipsoid, or cone." % index
	var op_value: Variant = request.get("op", OP_ADD)
	if not (op_value is int or op_value is float):
		return "op must be add, subtract, or intersect."
	var op := int(op_value)
	if op < OP_ADD or op > OP_INTERSECT:
		return "op must be add, subtract, or intersect."
	var smooth_value: Variant = request.get("smooth", 0.0)
	var shell_value: Variant = request.get("shell", 0.0)
	if not (smooth_value is int or smooth_value is float) or not (shell_value is int or shell_value is float):
		return "smooth and shell must be numbers."
	if float(smooth_value) < 0.0 or float(shell_value) < 0.0:
		return "smooth and shell must be zero or above."
	var step_value: Variant = request.get("step", 1)
	if not (step_value is int or step_value is float):
		return "step must be an integer from 1 to 4."
	var step := int(step_value)
	if step < 1 or step > 4:
		return "step must be an integer from 1 to 4."
	var material_value: Variant = request.get("material", null)
	if not (material_value is PackedFloat32Array):
		return "material must be a nine-float material."
	var material: PackedFloat32Array = material_value
	if material.size() != VoxelFrame.MATERIAL_STRIDE:
		return "material must be a nine-float material."
	for value in material:
		if not is_finite(value):
			return "material values must be finite."
	var volume := estimated_cells(request)
	if volume <= 0:
		return "The shape has no volume."
	if not allow_large and volume > MAX_PRIMITIVE_CELLS:
		return "The shape exceeds %d cells. Use step 2 or larger." % MAX_PRIMITIVE_CELLS
	return ""


static func warnings(request: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var step := clampi(int(request.get("step", 1)), 1, 4)
	var primitives_value: Variant = request.get("primitives", [])
	if primitives_value is Array:
		var primitives: Array = primitives_value
		var small := false
		for value in primitives:
			var primitive: Dictionary = value
			if _smallest_radius(primitive) < 2.0 * float(step):
				small = true
				break
		if small:
			result.append("A primitive radius is below %d cells at step %d. Increase step or the radius." % [2 * step, step])
	var requested_smooth := maxf(float(request.get("smooth", 0.0)), 0.0)
	var effective := effective_smooth(request)
	if requested_smooth > 0.0 and int(request.get("op", OP_ADD)) != OP_ADD:
		result.append("Smooth blending applies to add only.")
	elif requested_smooth > effective + EPSILON:
		result.append("Smooth blend clamped from %.1f to %.1f cells." % [requested_smooth, effective])
	if step > 1:
		result.append("Step %d writes %d-cell blocks." % [step, step])
	var shell := maxf(float(request.get("shell", 0.0)), 0.0)
	if shell > 0.0 and shell < float(step):
		result.append("Shell thickness is below the step size.")
	return result


static func rasterize(request: Dictionary, frame: VoxelFrame, job: VoxelFrame.EditJob = null) -> Dictionary:
	var value := scan_bounds(request)
	if value.is_empty():
		return _empty_result()
	var min_cell: Vector3i = value[0]
	var max_cell: Vector3i = value[1]
	var op := int(request.get("op", OP_ADD))
	var material: PackedFloat32Array = request.get("material", VoxelFrame.material(Color.WHITE))
	var changes := {}
	var blend_skipped := false
	if op == OP_ADD:
		var existing := {}
		var smooth := effective_smooth(request)
		if smooth > 0.0 and frame.count() > 0:
			existing = _existing_field(frame, min_cell, max_cell, smooth, job)
			if existing.has("too_large"):
				blend_skipped = true
				existing = {}
		_rasterize_add(request, frame, min_cell, max_cell, material, changes, job, existing, smooth)
	else:
		_rasterize_remove(request, frame, min_cell, max_cell, op, changes, job)
	if not changes.is_empty():
		var bounds := _changes_bounds(changes)
		return {
			"changes": changes,
			"applied": changes.size(),
			"bounds_min": min_cell,
			"bounds_max": max_cell,
			"changed_min": bounds[0],
			"changed_max": bounds[1],
			"blend_skipped": blend_skipped,
		}
	return {
		"changes": {},
		"applied": 0,
		"bounds_min": min_cell,
		"bounds_max": max_cell,
		"changed_min": Vector3i.MAX,
		"changed_max": Vector3i.MIN,
		"blend_skipped": blend_skipped,
	}


static func _sdf_capped_cone(radial: float, y: float, half_length: float, r1: float, r2: float) -> float:
	var qx := radial
	var qy := y
	var cap_radius := r1 if qy < 0.0 else r2
	var cax := qx - minf(qx, cap_radius)
	var cay := absf(qy) - half_length
	var k1x := r2
	var k1y := half_length
	var k2x := r2 - r1
	var k2y := 2.0 * half_length
	var denominator := k2x * k2x + k2y * k2y
	var amount := 0.0
	if denominator > EPSILON:
		amount = clampf(((k1x - qx) * k2x + (k1y - qy) * k2y) / denominator, 0.0, 1.0)
	var cbx := qx - k1x + k2x * amount
	var cby := qy - k1y + k2y * amount
	var sign_value := -1.0 if cbx < 0.0 and cay < 0.0 else 1.0
	var ca_distance := cax * cax + cay * cay
	var cb_distance := cbx * cbx + cby * cby
	return sign_value * sqrt(minf(ca_distance, cb_distance))


static func _rasterize_add(request: Dictionary, frame: VoxelFrame, min_cell: Vector3i, max_cell: Vector3i, material: PackedFloat32Array, changes: Dictionary, job: VoxelFrame.EditJob, existing: Dictionary, smooth: float) -> void:
	var step := clampi(int(request.get("step", 1)), 1, 4)
	var first_offset := -((step - 1) >> 1)
	var last_offset := step >> 1
	var blend_active := not existing.is_empty()
	var existing_min := Vector3i.ZERO
	var existing_size := Vector3i.ZERO
	var existing_values := PackedFloat32Array()
	var existing_occupied := PackedByteArray()
	if blend_active:
		existing_min = existing["min"]
		existing_size = existing["size"]
		existing_values = existing["values"]
		existing_occupied = existing.get("occupied", PackedByteArray())
		blend_active = not existing_values.is_empty()
	var stride_y := existing_size.x
	var stride_z := existing_size.x * existing_size.y
	var prepared := _prepare_distance(request)
	var completed := 0
	for x in range(min_cell.x, max_cell.x + 1, step):
		for y in range(min_cell.y, max_cell.y + 1, step):
			for z in range(min_cell.z, max_cell.z + 1, step):
				var sample := Vector3i(x, y, z)
				var distance := _prepared_field_distance(prepared, Vector3(x, y, z))
				var solid := false
				var local := sample - existing_min
				var in_field := blend_active and local.x >= 0 and local.y >= 0 and local.z >= 0 and local.x < existing_size.x and local.y < existing_size.y and local.z < existing_size.z
				if in_field:
					var index := local.x + stride_y * local.y + stride_z * local.z
					solid = existing_occupied[index] > 0
					if not solid:
						var existing_distance := existing_values[index]
						if existing_distance < FAR_DISTANCE * 0.5:
							distance = smin(existing_distance, distance, smooth)
				else:
					solid = frame.has(sample)
				if distance <= 0.0:
					if step == 1:
						if solid and (blend_active or frame.matches(sample, material)):
							pass
						else:
							changes[sample] = material
					else:
						for dx in range(first_offset, last_offset + 1):
							for dy in range(first_offset, last_offset + 1):
								for dz in range(first_offset, last_offset + 1):
									var cell := Vector3i(x + dx, y + dy, z + dz)
									if frame.has(cell):
										if blend_active or frame.matches(cell, material):
											continue
									changes[cell] = material
				completed += 1
				if job and completed % 2048 == 0 and not job.checkpoint(completed):
					changes.clear()
					return


static func _rasterize_remove(request: Dictionary, frame: VoxelFrame, min_cell: Vector3i, max_cell: Vector3i, op: int, changes: Dictionary, job: VoxelFrame.EditJob) -> void:
	var cells := _occupied_cells(frame, job) if op == OP_INTERSECT else _occupied_cells_in_box(frame, min_cell, max_cell, job)
	var erased := VoxelFrame.material(Color.TRANSPARENT)
	var completed := 0
	for cell: Vector3i in cells:
		var distance := field_distance(request, Vector3(cell))
		if (op == OP_SUBTRACT and distance <= 0.0) or (op == OP_INTERSECT and distance > 0.0):
			changes[cell] = erased
		completed += 1
		if job and completed % 2048 == 0 and not job.checkpoint(completed):
			changes.clear()
			return


static func _existing_field(frame: VoxelFrame, min_cell: Vector3i, max_cell: Vector3i, smooth: float, job: VoxelFrame.EditJob) -> Dictionary:
	var padding := 1
	var limit := VoxelFrame.MAX_CHUNK_COORDINATE * VoxelFrame.CHUNK_SIZE
	var blend_min := min_cell - Vector3i.ONE * padding
	var blend_max := max_cell + Vector3i.ONE * padding
	blend_min = Vector3i(
		clampi(blend_min.x, -limit, limit),
		clampi(blend_min.y, -limit, limit),
		clampi(blend_min.z, -limit, limit)
	)
	blend_max = Vector3i(
		clampi(blend_max.x, -limit, limit),
		clampi(blend_max.y, -limit, limit),
		clampi(blend_max.z, -limit, limit)
	)
	var size := blend_max - blend_min + Vector3i.ONE
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		return {}
	var volume := size.x * size.y * size.z
	if volume > MAX_BLEND_CELLS:
		return {"too_large": true}
	var occupied := PackedByteArray()
	occupied.resize(volume)
	if not _fill_occupied(frame, blend_min, size, occupied, job):
		return {}
	var to_empty := PackedFloat32Array()
	to_empty.resize(volume)
	to_empty.fill(FAR_DISTANCE)
	var to_solid := PackedFloat32Array()
	to_solid.resize(volume)
	to_solid.fill(FAR_DISTANCE)
	var has_solid := false
	var index := 0
	for value: int in occupied:
		if value:
			to_solid[index] = 0.0
			has_solid = true
		else:
			to_empty[index] = 0.0
		index += 1
		if job and index % 4096 == 0 and not job.checkpoint(index):
			return {}
	if not has_solid:
		return {}
	if not _chamfer(to_empty, size, true, job):
		return {}
	if not _chamfer(to_empty, size, false, job):
		return {}
	if not _chamfer(to_solid, size, true, job):
		return {}
	if not _chamfer(to_solid, size, false, job):
		return {}
	var values := PackedFloat32Array()
	values.resize(volume)
	var cap := smooth + 2.0
	index = 0
	for value: int in occupied:
		if value:
			values[index] = -minf(maxf(to_empty[index] - 0.5, 0.0), cap)
		else:
			values[index] = minf(maxf(to_solid[index] - 0.5, 0.0), cap)
		index += 1
		if job and index % 4096 == 0 and not job.checkpoint(index):
			return {}
	return {"min": blend_min, "size": size, "values": values, "occupied": occupied}


static func _fill_occupied(frame: VoxelFrame, blend_min: Vector3i, size: Vector3i, occupied: PackedByteArray, job: VoxelFrame.EditJob) -> bool:
	var chunk_size := VoxelFrame.CHUNK_SIZE
	var shift := VoxelFrame.CHUNK_SHIFT
	var first_chunk_x := blend_min.x >> shift
	var first_chunk_y := blend_min.y >> shift
	var first_chunk_z := blend_min.z >> shift
	var last_cell_x := blend_min.x + size.x - 1
	var last_cell_y := blend_min.y + size.y - 1
	var last_cell_z := blend_min.z + size.z - 1
	var last_chunk_x := last_cell_x >> shift
	var last_chunk_y := last_cell_y >> shift
	var last_chunk_z := last_cell_z >> shift
	var end_x := blend_min.x + size.x
	var end_y := blend_min.y + size.y
	var end_z := blend_min.z + size.z
	var checked := 0
	for chunk_z in range(first_chunk_z, last_chunk_z + 1):
		for chunk_y in range(first_chunk_y, last_chunk_y + 1):
			for chunk_x in range(first_chunk_x, last_chunk_x + 1):
				var origin := Vector3i(chunk_x, chunk_y, chunk_z) * chunk_size
				var chunk: VoxelFrame.Chunk = frame.chunks.get(Vector3i(chunk_x, chunk_y, chunk_z))
				if chunk == null:
					continue
				var local_min_x := maxi(blend_min.x - origin.x, 0)
				var local_max_x := mini(end_x - origin.x, chunk_size)
				var local_min_y := maxi(blend_min.y - origin.y, 0)
				var local_max_y := mini(end_y - origin.y, chunk_size)
				var local_min_z := maxi(blend_min.z - origin.z, 0)
				var local_max_z := mini(end_z - origin.z, chunk_size)
				var flat_base := (origin.x - blend_min.x) + size.x * (origin.y - blend_min.y) + size.x * size.y * (origin.z - blend_min.z)
				if chunk.grid.is_empty():
					for slot: int in chunk._sparse_slots:
						var local_x := slot % chunk_size
						var local_y := (slot / chunk_size) % chunk_size
						var local_z := slot / (chunk_size * chunk_size)
						if local_x < local_min_x or local_x >= local_max_x or local_y < local_min_y or local_y >= local_max_y or local_z < local_min_z or local_z >= local_max_z:
							continue
						occupied[flat_base + local_x + size.x * local_y + size.x * size.y * local_z] = 1
					continue
				var grid := chunk.grid
				for local_z in range(local_min_z, local_max_z):
					var z_slot_base := local_z * chunk_size * chunk_size
					var flat_z_base := flat_base + size.x * size.y * local_z
					for local_y in range(local_min_y, local_max_y):
						var slot_base := z_slot_base + local_y * chunk_size
						var flat_row_base := flat_z_base + size.x * local_y
						for local_x in range(local_min_x, local_max_x):
							if grid[slot_base + local_x] > 0:
								occupied[flat_row_base + local_x] = 1
							checked += 1
							if job and checked % 4096 == 0 and not job.checkpoint(checked):
								return false
	return true


static func _chamfer(values: PackedFloat32Array, size: Vector3i, forward: bool, job: VoxelFrame.EditJob) -> bool:
	if forward:
		return _chamfer_forward(values, size, job)
	return _chamfer_backward(values, size, job)


static func _chamfer_forward(values: PackedFloat32Array, size: Vector3i, job: VoxelFrame.EditJob) -> bool:
	var sx := size.x
	var sy := size.y
	var sz := size.z
	var layer_size := sx * sy
	var layer := 0
	for z in range(sz):
		var z_base := layer_size * z
		for y in range(sy):
			var row_base := z_base + sx * y
			for x in range(sx):
				var index := row_base + x
				var best := values[index]
				var candidate := 0.0
				if x > 0:
					candidate = values[index - 1] + 1.0
					if candidate < best:
						best = candidate
					if y > 0:
						candidate = values[index - 1 - sx] + SQRT_2
						if candidate < best:
							best = candidate
						if z > 0:
							candidate = values[index - 1 - sx - layer_size] + SQRT_3
							if candidate < best:
								best = candidate
						if z < sz - 1:
							candidate = values[index - 1 - sx + layer_size] + SQRT_3
							if candidate < best:
								best = candidate
					if y < sy - 1:
						candidate = values[index - 1 + sx] + SQRT_2
						if candidate < best:
							best = candidate
						if z > 0:
							candidate = values[index - 1 + sx - layer_size] + SQRT_3
							if candidate < best:
								best = candidate
						if z < sz - 1:
							candidate = values[index - 1 + sx + layer_size] + SQRT_3
							if candidate < best:
								best = candidate
					if z > 0:
						candidate = values[index - 1 - layer_size] + SQRT_2
						if candidate < best:
							best = candidate
					if z < sz - 1:
						candidate = values[index - 1 + layer_size] + SQRT_2
						if candidate < best:
							best = candidate
				if y > 0:
					candidate = values[index - sx] + 1.0
					if candidate < best:
						best = candidate
					if z > 0:
						candidate = values[index - sx - layer_size] + SQRT_2
						if candidate < best:
							best = candidate
					if z < sz - 1:
						candidate = values[index - sx + layer_size] + SQRT_2
						if candidate < best:
							best = candidate
				if z > 0:
					candidate = values[index - layer_size] + 1.0
					if candidate < best:
						best = candidate
				values[index] = best
		layer += 1
		if job and layer % 8 == 0 and not job.checkpoint(layer * sx * sy):
			return false
	return true


static func _chamfer_backward(values: PackedFloat32Array, size: Vector3i, job: VoxelFrame.EditJob) -> bool:
	var sx := size.x
	var sy := size.y
	var sz := size.z
	var layer_size := sx * sy
	var layer := 0
	for z in range(sz - 1, -1, -1):
		var z_base := layer_size * z
		for y in range(sy - 1, -1, -1):
			var row_base := z_base + sx * y
			for x in range(sx - 1, -1, -1):
				var index := row_base + x
				var best := values[index]
				var candidate := 0.0
				if x < sx - 1:
					candidate = values[index + 1] + 1.0
					if candidate < best:
						best = candidate
					if y < sy - 1:
						candidate = values[index + 1 + sx] + SQRT_2
						if candidate < best:
							best = candidate
						if z < sz - 1:
							candidate = values[index + 1 + sx + layer_size] + SQRT_3
							if candidate < best:
								best = candidate
						if z > 0:
							candidate = values[index + 1 + sx - layer_size] + SQRT_3
							if candidate < best:
								best = candidate
					if y > 0:
						candidate = values[index + 1 - sx] + SQRT_2
						if candidate < best:
							best = candidate
						if z < sz - 1:
							candidate = values[index + 1 - sx + layer_size] + SQRT_3
							if candidate < best:
								best = candidate
						if z > 0:
							candidate = values[index + 1 - sx - layer_size] + SQRT_3
							if candidate < best:
								best = candidate
					if z > 0:
						candidate = values[index + 1 - layer_size] + SQRT_2
						if candidate < best:
							best = candidate
					if z < sz - 1:
						candidate = values[index + 1 + layer_size] + SQRT_2
						if candidate < best:
							best = candidate
				if y < sy - 1:
					candidate = values[index + sx] + 1.0
					if candidate < best:
						best = candidate
					if z < sz - 1:
						candidate = values[index + sx + layer_size] + SQRT_2
						if candidate < best:
							best = candidate
					if z > 0:
						candidate = values[index + sx - layer_size] + SQRT_2
						if candidate < best:
							best = candidate
				if z < sz - 1:
					candidate = values[index + layer_size] + 1.0
					if candidate < best:
						best = candidate
				values[index] = best
		layer += 1
		if job and layer % 8 == 0 and not job.checkpoint(layer * sx * sy):
			return false
	return true


static func _existing_at(field: Dictionary, cell: Vector3i) -> float:
	var min_cell: Vector3i = field["min"]
	var size: Vector3i = field["size"]
	var local := cell - min_cell
	if local.x < 0 or local.y < 0 or local.z < 0 or local.x >= size.x or local.y >= size.y or local.z >= size.z:
		return FAR_DISTANCE
	var values: PackedFloat32Array = field["values"]
	return values[local.x + size.x * (local.y + size.y * local.z)]


static func _occupied_cells(frame: VoxelFrame, job: VoxelFrame.EditJob) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var completed := 0
	for chunk_value in frame.chunks.values():
		var chunk: VoxelFrame.Chunk = chunk_value
		for cell: Vector3i in chunk.world_cells():
			cells.append(cell)
			completed += 1
			if job and completed % 2048 == 0 and not job.checkpoint(completed):
				return cells
	return cells


static func _occupied_cells_in_box(frame: VoxelFrame, min_cell: Vector3i, max_cell: Vector3i, job: VoxelFrame.EditJob) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var completed := 0
	for chunk_value in frame.chunks.values():
		var chunk: VoxelFrame.Chunk = chunk_value
		var chunk_bounds := chunk.get_bounds()
		if not chunk_bounds.has_volume():
			continue
		var chunk_min := Vector3i(
			roundi(chunk_bounds.position.x + 0.5),
			roundi(chunk_bounds.position.y + 0.5),
			roundi(chunk_bounds.position.z + 0.5)
		)
		var chunk_max := Vector3i(
			roundi(chunk_bounds.end.x - 0.5),
			roundi(chunk_bounds.end.y - 0.5),
			roundi(chunk_bounds.end.z - 0.5)
		)
		if chunk_max.x < min_cell.x or chunk_min.x > max_cell.x:
			continue
		if chunk_max.y < min_cell.y or chunk_min.y > max_cell.y:
			continue
		if chunk_max.z < min_cell.z or chunk_min.z > max_cell.z:
			continue
		for cell: Vector3i in chunk.world_cells():
			if cell.x < min_cell.x or cell.x > max_cell.x:
				continue
			if cell.y < min_cell.y or cell.y > max_cell.y:
				continue
			if cell.z < min_cell.z or cell.z > max_cell.z:
				continue
			cells.append(cell)
			completed += 1
			if job and completed % 2048 == 0 and not job.checkpoint(completed):
				return cells
	return cells


static func _smallest_radius(primitive: Dictionary) -> float:
	var kind := int(primitive.get("kind", KIND_BOX))
	match kind:
		KIND_ELLIPSOID:
			var radii: Vector3 = primitive.get("radii", Vector3.ONE)
			return minf(radii.x, minf(radii.y, radii.z))
		KIND_CONE:
			var r1 := float(primitive.get("r1", 0.0))
			var r2 := float(primitive.get("r2", 0.0))
			return minf(r1, r2)
		_:
			var half_size: Vector3 = primitive.get("half_size", Vector3.ONE)
			return minf(half_size.x, minf(half_size.y, half_size.z))


static func _changes_bounds(changes: Dictionary) -> Array:
	var min_cell := Vector3i.MAX
	var max_cell := Vector3i.MIN
	for cell: Vector3i in changes:
		min_cell = Vector3i(mini(min_cell.x, cell.x), mini(min_cell.y, cell.y), mini(min_cell.z, cell.z))
		max_cell = Vector3i(maxi(max_cell.x, cell.x), maxi(max_cell.y, cell.y), maxi(max_cell.z, cell.z))
	return [min_cell, max_cell]


static func _valid_vector(value: Variant) -> bool:
	if not (value is Vector3):
		return false
	var vector: Vector3 = value
	return is_finite(vector.x) and is_finite(vector.y) and is_finite(vector.z)


static func _empty_result() -> Dictionary:
	return {
		"changes": {},
		"applied": 0,
		"bounds_min": Vector3i.ZERO,
		"bounds_max": Vector3i.ZERO,
		"changed_min": Vector3i.MAX,
		"changed_max": Vector3i.MIN,
		"blend_skipped": false,
	}
