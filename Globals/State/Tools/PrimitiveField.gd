extends RefCounted

## Pure signed-distance helpers for the primitive tools.
##
## A primitive is a field in cell units. Cell c has its center at Vector3(c),
## so a field value of zero or less marks a cell for the shape. The script reads
## no State and no Node, so a worker can call it. It holds no static state.

## The box primitive kind.
const KIND_BOX := 0
## The ellipsoid primitive kind.
const KIND_ELLIPSOID := 1
## The cone primitive kind.
const KIND_CONE := 2

## Add the primitive field to the frame.
const OP_ADD := 0
## Remove the primitive field from the frame.
const OP_SUBTRACT := 1
## Keep only the frame cells inside the primitive field and the shape box.
const OP_INTERSECT := 2

## The largest primitive count in one request.
const MAX_PRIMITIVES := 64
## The largest evaluated cell count in one request.
const MAX_PRIMITIVE_CELLS := 1_048_576
## The largest local cell box for an existing-geometry blend.
const MAX_BLEND_CELLS := 2_000_000
## The smallest guard for a division.
const EPSILON := 1e-6
## The distance that means no opposite cell was found in the local box.
const FAR_DISTANCE := 1.0e9
## The forward chamfer neighbors and their costs.
const CHAMFER_FORWARD := [
	[Vector3i(-1, 0, 0), 1.0],
	[Vector3i(0, -1, 0), 1.0],
	[Vector3i(0, 0, -1), 1.0],
	[Vector3i(-1, -1, 0), 1.41421356],
	[Vector3i(-1, 1, 0), 1.41421356],
	[Vector3i(-1, 0, -1), 1.41421356],
	[Vector3i(-1, 0, 1), 1.41421356],
	[Vector3i(0, -1, -1), 1.41421356],
	[Vector3i(0, -1, 1), 1.41421356],
	[Vector3i(-1, -1, -1), 1.73205081],
	[Vector3i(-1, -1, 1), 1.73205081],
	[Vector3i(-1, 1, -1), 1.73205081],
	[Vector3i(-1, 1, 1), 1.73205081],
]


## Returns the box field for one point.
static func sdf_box(point: Vector3, center: Vector3, half_size: Vector3) -> float:
	var q := point - center
	q = Vector3(absf(q.x) - half_size.x, absf(q.y) - half_size.y, absf(q.z) - half_size.z)
	var outside := Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0))
	return outside.length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)


## Returns a box field with rounded edges and corners. A roundness of 0 is the
## exact box. A roundness of 1 rounds the smallest half extent.
static func sdf_round_box(point: Vector3, center: Vector3, half_size: Vector3, roundness: float) -> float:
	var radius := clampf(roundness, 0.0, 1.0) * minf(half_size.x, minf(half_size.y, half_size.z))
	var inner := Vector3(
		maxf(half_size.x - radius, 0.0),
		maxf(half_size.y - radius, 0.0),
		maxf(half_size.z - radius, 0.0)
	)
	return sdf_box(point, center, inner) - radius


## Returns the approximate ellipsoid field for one point. It is exact on the
## surface and good for placement.
static func sdf_ellipsoid(point: Vector3, center: Vector3, radii: Vector3) -> float:
	var safe := Vector3(maxf(radii.x, EPSILON), maxf(radii.y, EPSILON), maxf(radii.z, EPSILON))
	var scaled := (point - center) / safe
	return (scaled.length() - 1.0) * minf(safe.x, minf(safe.y, safe.z))


## Returns the exact round-cone field for one point.
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


## Returns the exact capped-cone field for one point. The caps are flat.
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


## Returns the smooth minimum of two fields.
static func smin(first: float, second: float, blur: float) -> float:
	if blur <= 0.0:
		return minf(first, second)
	var h := maxf(blur - absf(first - second), 0.0) / blur
	return minf(first, second) - h * h * blur * 0.25


## Returns the rotation of one primitive around its center. It is identity when
## the primitive has no rotation.
static func primitive_rotation(primitive: Dictionary) -> Quaternion:
	var value: Variant = primitive.get("rotation", null)
	return value if value is Quaternion else Quaternion.IDENTITY


## Returns the field of one primitive at one point.
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


## Returns the combined field of a request at one point.
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


## Returns the smooth blend that a request uses after the extent clamp.
static func effective_smooth(request: Dictionary) -> float:
	var requested := maxf(float(request.get("smooth", 0.0)), 0.0)
	if requested <= 0.0 or int(request.get("op", OP_ADD)) != OP_ADD:
		return 0.0
	var extent := smallest_extent(request)
	if extent <= 0.0:
		return 0.0
	return minf(requested, extent * 0.5)


## Returns the smallest full extent of the primitives in a request.
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


## Returns the bounds of one primitive. The cone uses the union of its endpoint
## spheres, which is tight for the round cone and safe for the flat cone.
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


## Returns the world extent of a local box or radius vector after a rotation.
static func _rotated_extent(rotation: Quaternion, extent: Vector3) -> Vector3:
	var basis := Basis(rotation)
	return Vector3(
		absf(basis.x.x) * extent.x + absf(basis.y.x) * extent.y + absf(basis.z.x) * extent.z,
		absf(basis.x.y) * extent.x + absf(basis.y.y) * extent.y + absf(basis.z.y) * extent.z,
		absf(basis.x.z) * extent.x + absf(basis.y.z) * extent.y + absf(basis.z.z) * extent.z,
	)


## Returns the continuous shape bounds of a request after smooth and shell.
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


## Returns the integer cell bounds of the shape, without the scan padding.
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


## Returns the continuous scan bounds of a request. The scan adds one cell and
## the block step to the shape bounds.
static func field_bounds(request: Dictionary) -> AABB:
	var bounds := shape_bounds(request)
	if not bounds.has_volume():
		return AABB()
	var padding := 1.0 + float(clampi(int(request.get("step", 1)), 1, 4))
	return AABB(bounds.position - Vector3.ONE * padding, bounds.size + Vector3.ONE * padding * 2.0)


## Returns the integer scan bounds of a request as [min_cell, max_cell]. An
## empty request returns an empty array.
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


## Returns the cell count inside the scan bounds.
static func estimated_cells(request: Dictionary) -> int:
	var value := scan_bounds(request)
	if value.is_empty():
		return 0
	var min_cell: Vector3i = value[0]
	var max_cell: Vector3i = value[1]
	var extent := max_cell - min_cell + Vector3i.ONE
	return extent.x * extent.y * extent.z


## Returns an error string for an invalid request. An empty string means valid.
## [param allow_large] lets the mouse tool commit a shape that the preview
## already showed. The MCP path keeps the cell limit.
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


## Returns the warnings for one valid request.
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


## Builds the changes for one request. Returns the changes and their bounds. The
## caller supplies the frame snapshot that the job edits. A [param job] supplies
## the cancel checkpoints.
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


## Returns the capped cone field in a local frame. [param radial] is the
## distance from the axis, [param y] runs along the axis, and [param half_length]
## is half the distance between the caps.
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
	var completed := 0
	for x in range(min_cell.x, max_cell.x + 1, step):
		for y in range(min_cell.y, max_cell.y + 1, step):
			for z in range(min_cell.z, max_cell.z + 1, step):
				var sample := Vector3i(x, y, z)
				var distance := field_distance(request, Vector3(x, y, z))
				if blend_active and not frame.has(sample):
					var existing_distance := _existing_at(existing, sample)
					if existing_distance < FAR_DISTANCE * 0.5:
						distance = smin(existing_distance, distance, smooth)
				if distance <= 0.0:
					for dx in range(first_offset, last_offset + 1):
						for dy in range(first_offset, last_offset + 1):
							for dz in range(first_offset, last_offset + 1):
								var cell := Vector3i(x + dx, y + dy, z + dz)
								if frame.has(cell):
									# A blend keeps the committed cells and their
									# materials. It only adds the new fillet and the
									# empty part of the primitive.
									if blend_active or frame.matches(cell, material):
										continue
								changes[cell] = material
				completed += 1
				if job and completed % 2048 == 0 and not job.checkpoint(completed):
					changes.clear()
					return


static func _rasterize_remove(request: Dictionary, frame: VoxelFrame, min_cell: Vector3i, max_cell: Vector3i, op: int, changes: Dictionary, job: VoxelFrame.EditJob) -> void:
	# A keep operation must see every occupied cell, because the cells outside
	# the shape are the cells that it removes. A subtract only tests the shape
	# box, because a cell outside the field cannot change.
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


## Returns a bounded signed distance field for the committed cells near a
## request. The result holds [code]min[/code], [code]size[/code], and
## [code]values[/code]. Empty cells are positive and occupied cells are negative.
static func _existing_field(frame: VoxelFrame, min_cell: Vector3i, max_cell: Vector3i, smooth: float, job: VoxelFrame.EditJob) -> Dictionary:
	# The scan bounds already include the shape, smooth, and step padding. One
	# extra cell keeps the nearest opposite cell available at the edge.
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
	var to_empty := PackedFloat32Array()
	to_empty.resize(volume)
	to_empty.fill(FAR_DISTANCE)
	var to_solid := PackedFloat32Array()
	to_solid.resize(volume)
	to_solid.fill(FAR_DISTANCE)
	var has_solid := false
	var index := 0
	for z in range(blend_min.z, blend_max.z + 1):
		for y in range(blend_min.y, blend_max.y + 1):
			for x in range(blend_min.x, blend_max.x + 1):
				var cell := Vector3i(x, y, z)
				if frame.has(cell):
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
	for z in range(blend_min.z, blend_max.z + 1):
		for y in range(blend_min.y, blend_max.y + 1):
			for x in range(blend_min.x, blend_max.x + 1):
				var cell := Vector3i(x, y, z)
				if frame.has(cell):
					values[index] = -minf(maxf(to_empty[index] - 0.5, 0.0), cap)
				else:
					values[index] = minf(maxf(to_solid[index] - 0.5, 0.0), cap)
				index += 1
				if job and index % 4096 == 0 and not job.checkpoint(index):
					return {}
	return {"min": blend_min, "size": size, "values": values}


## Runs one chamfer pass over a distance grid. [param forward] selects the
## first or the second pass.
static func _chamfer(values: PackedFloat32Array, size: Vector3i, forward: bool, job: VoxelFrame.EditJob) -> bool:
	var z_start := 0
	var z_end := size.z
	var z_step := 1
	var y_start := 0
	var y_end := size.y
	var y_step := 1
	var x_start := 0
	var x_end := size.x
	var x_step := 1
	if not forward:
		z_start = size.z - 1
		z_end = -1
		z_step = -1
		y_start = size.y - 1
		y_end = -1
		y_step = -1
		x_start = size.x - 1
		x_end = -1
		x_step = -1
	var layer := 0
	for z in range(z_start, z_end, z_step):
		for y in range(y_start, y_end, y_step):
			for x in range(x_start, x_end, x_step):
				var index := x + size.x * (y + size.y * z)
				var best := values[index]
				for entry in CHAMFER_FORWARD:
					var delta: Vector3i = entry[0]
					if not forward:
						delta = -delta
					var nx := x + delta.x
					var ny := y + delta.y
					var nz := z + delta.z
					if nx < 0 or nx >= size.x or ny < 0 or ny >= size.y or nz < 0 or nz >= size.z:
						continue
					var neighbor := nx + size.x * (ny + size.y * nz)
					var candidate := values[neighbor] + float(entry[1])
					if candidate < best:
						best = candidate
				values[index] = best
		layer += 1
		if job and layer % 8 == 0 and not job.checkpoint(layer * size.x * size.y):
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
