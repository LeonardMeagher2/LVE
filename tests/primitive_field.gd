extends "res://tests/test.gd"

## Pure checks for the primitive signed-distance fields and their rasterizer.

const PrimitiveField := preload("res://Globals/State/Tools/PrimitiveField.gd")


func _ready() -> void:
	test("a box field is negative inside, zero on the surface, and positive outside", _box, "box")
	test("an ellipsoid field is negative inside, zero on the surface, and positive outside", _ellipsoid, "ellipsoid")
	test("a round cone with equal radii is a capsule", _cone_round_capsule, "cone_round")
	test("a flat cone with equal radii is a cylinder", _cone_flat_cylinder, "cone_flat")
	test("a flat cone with a zero tip keeps its point", _cone_tip, "cone_tip")
	test("a cone with equal endpoints is a sphere", _cone_sphere, "cone_sphere")
	test("roundness rounds a cube and blends a cone end", _roundness, "roundness")
	test("a zero shell is solid and a shell removes the core", _shell, "shell")
	test("a smooth union fills the join between two primitives", _smooth, "smooth")
	test("the scan bounds grow with smooth and shell", _bounds, "bounds")
	test("a small radius warns at a coarse step", _warnings, "warnings")
	test("invalid cones are refused", _validation, "validation")
	test("a rotated box keeps its local field and bounds", _rotation, "rotation")
	test("a rasterized box writes the expected cells", _rasterize, "rasterize")
	test("the same request produces the same cells", _determinism, "determinism")


func _box() -> void:
	var half := Vector3(2.0, 3.0, 4.0)
	step("Then the box center is inside by the nearest half extent", func():
		expect(is_equal_approx(PrimitiveField.sdf_box(Vector3.ZERO, Vector3.ZERO, half), -2.0), "the center distance is -2")
	)
	step("Then the face is the zero surface and the point beyond it is outside", func():
		expect(is_equal_approx(PrimitiveField.sdf_box(Vector3(2.0, 0.0, 0.0), Vector3.ZERO, half), 0.0), "the x face is on the surface")
		expect(is_equal_approx(PrimitiveField.sdf_box(Vector3(2.5, 0.0, 0.0), Vector3.ZERO, half), 0.5), "the point beyond the face is 0.5 outside")
	)
	step("Then a corner reads the exact diagonal distance", func():
		expect(is_equal_approx(PrimitiveField.sdf_box(Vector3(3.0, 4.0, 5.0), Vector3.ZERO, half), sqrt(3.0)), "the corner distance is sqrt(3)")
	)


func _ellipsoid() -> void:
	var radii := Vector3(2.0, 3.0, 4.0)
	step("Then the ellipsoid center is inside by the smallest radius", func():
		expect(is_equal_approx(PrimitiveField.sdf_ellipsoid(Vector3.ZERO, Vector3.ZERO, radii), -2.0), "the center distance is -2")
	)
	step("Then each axis point is on the surface", func():
		expect(is_equal_approx(PrimitiveField.sdf_ellipsoid(Vector3(2.0, 0.0, 0.0), Vector3.ZERO, radii), 0.0), "the x axis point is on the surface")
		expect(is_equal_approx(PrimitiveField.sdf_ellipsoid(Vector3(0.0, 3.0, 0.0), Vector3.ZERO, radii), 0.0), "the y axis point is on the surface")
		expect(is_equal_approx(PrimitiveField.sdf_ellipsoid(Vector3(0.0, 0.0, 4.0), Vector3.ZERO, radii), 0.0), "the z axis point is on the surface")
	)
	step("Then a point beyond the x radius is outside", func():
		expect(PrimitiveField.sdf_ellipsoid(Vector3(3.0, 0.0, 0.0), Vector3.ZERO, radii) > 0.0, "the outside point is positive")
	)


func _cone_round_capsule() -> void:
	var a := Vector3(0.0, -10.0, 0.0)
	var b := Vector3(0.0, 10.0, 0.0)
	step("Then the middle of the capsule is inside", func():
		expect(is_equal_approx(PrimitiveField.sdf_cone_round(Vector3.ZERO, a, b, 3.0, 3.0), -3.0), "the middle distance is -3")
	)
	step("Then the side is on the surface", func():
		expect(is_equal_approx(PrimitiveField.sdf_cone_round(Vector3(3.0, 0.0, 0.0), a, b, 3.0, 3.0), 0.0), "the side point is on the surface")
	)
	step("Then the rounded end extends past the flat endpoint", func():
		expect(PrimitiveField.sdf_cone_round(Vector3(0.0, 12.0, 0.0), a, b, 3.0, 3.0) < 0.0, "the point inside the end sphere is inside")
		expect(is_equal_approx(PrimitiveField.sdf_cone_round(Vector3(0.0, 13.0, 0.0), a, b, 3.0, 3.0), 0.0), "the end sphere is on the surface")
	)


func _cone_flat_cylinder() -> void:
	var a := Vector3(0.0, -10.0, 0.0)
	var b := Vector3(0.0, 10.0, 0.0)
	step("Then the flat cone closes at the endpoints", func():
		expect(is_equal_approx(PrimitiveField.sdf_cone_flat(Vector3(0.0, 9.5, 0.0), a, b, 3.0, 3.0), -0.5), "the point below the cap is inside")
		expect(is_equal_approx(PrimitiveField.sdf_cone_flat(Vector3(0.0, 10.0, 0.0), a, b, 3.0, 3.0), 0.0), "the cap center is on the surface")
		expect(is_equal_approx(PrimitiveField.sdf_cone_flat(Vector3(0.0, 10.5, 0.0), a, b, 3.0, 3.0), 0.5), "the point above the cap is 0.5 outside")
	)
	step("Then the side is a cylinder", func():
		expect(is_equal_approx(PrimitiveField.sdf_cone_flat(Vector3(3.0, 0.0, 0.0), a, b, 3.0, 3.0), 0.0), "the side point is on the surface")
	)


func _cone_tip() -> void:
	var a := Vector3(0.0, 0.0, 0.0)
	var b := Vector3(0.0, 10.0, 0.0)
	step("Then the zero tip is on the surface", func():
		expect(is_equal_approx(PrimitiveField.sdf_cone_flat(b, a, b, 3.0, 0.0), 0.0), "the tip point is on the surface")
	)
	step("Then the tip is a point and not a hole", func():
		expect(PrimitiveField.sdf_cone_flat(Vector3(0.0, 9.5, 0.0), a, b, 3.0, 0.0) < 0.0, "the point just below the tip is inside")
		expect(PrimitiveField.sdf_cone_flat(Vector3(0.0, 10.1, 0.0), a, b, 3.0, 0.0) > 0.0, "the point above the tip is outside")
	)


func _cone_sphere() -> void:
	var point := Vector3(1.0, 2.0, 3.0)
	step("Then equal endpoints use the larger radius", func():
		var value := PrimitiveField.sdf_cone_round(point, point, point, 2.0, 4.0)
		expect(is_equal_approx(value, -4.0), "the center distance is the larger radius")
		var surface := point + Vector3(4.0, 0.0, 0.0)
		expect(is_equal_approx(PrimitiveField.sdf_cone_round(surface, point, point, 2.0, 4.0), 0.0), "the larger radius is the surface")
	)


func _roundness() -> void:
	step("Then a fully round cube becomes a sphere", func():
		var point := Vector3(2.0, 2.0, 2.0)
		expect(is_equal_approx(PrimitiveField.sdf_round_box(point, Vector3.ZERO, Vector3(2.0, 2.0, 2.0), 0.0), 0.0), "the sharp cube corner is on the surface")
		expect(PrimitiveField.sdf_round_box(point, Vector3.ZERO, Vector3(2.0, 2.0, 2.0), 1.0) > 0.0, "the round cube corner is outside")
		expect(is_equal_approx(PrimitiveField.sdf_round_box(Vector3(2.0, 0.0, 0.0), Vector3.ZERO, Vector3(2.0, 2.0, 2.0), 1.0), 0.0), "the round cube axis point stays on the surface")
	)
	step("Then a cone blends from flat to round", func():
		var a := Vector3(0.0, -10.0, 0.0)
		var b := Vector3(0.0, 10.0, 0.0)
		var point := Vector3(0.0, 12.0, 0.0)
		var flat := _cone_primitive(a, b, 3.0, 3.0, 0.0)
		var round := _cone_primitive(a, b, 3.0, 3.0, 1.0)
		expect(PrimitiveField.primitive_distance(flat, point) > 0.0, "the flat cone is outside its cap")
		expect(PrimitiveField.primitive_distance(round, point) < 0.0, "the round cone is inside its cap")
	)


func _shell() -> void:
	step("Then a zero shell keeps the solid center", func():
		var request := _request([_box_primitive(Vector3.ZERO, Vector3(5.0, 5.0, 5.0))], 0, 0.0, 0.0)
		expect(PrimitiveField.field_distance(request, Vector3.ZERO) <= 0.0, "the center is inside")
	)
	step("Then a shell removes the center and keeps the surface band", func():
		var request := _request([_box_primitive(Vector3.ZERO, Vector3(5.0, 5.0, 5.0))], 0, 0.0, 1.0)
		expect(PrimitiveField.field_distance(request, Vector3.ZERO) > 0.0, "the center is outside the shell")
		expect(PrimitiveField.field_distance(request, Vector3(5.0, 0.0, 0.0)) <= 0.0, "the face is inside the shell")
	)


func _smooth() -> void:
	step("Then the smooth minimum lowers the join value", func():
		expect(is_equal_approx(PrimitiveField.smin(0.5, 0.5, 2.0), 0.0), "the smooth union reaches the midpoint")
		expect(PrimitiveField.smin(0.5, 0.5, 0.0) > 0.0, "the hard union leaves a gap")
	)
	step("Then the combined field fills the join", func():
		var left := _ellipsoid_primitive(Vector3(-2.0, 0.0, 0.0), Vector3(1.75, 1.75, 1.75))
		var right := _ellipsoid_primitive(Vector3(2.0, 0.0, 0.0), Vector3(1.75, 1.75, 1.75))
		var hard := _request([left, right], 0, 0.0, 0.0)
		var blended := _request([left, right], 0, 2.0, 0.0)
		expect(PrimitiveField.field_distance(hard, Vector3.ZERO) > 0.0, "the hard union leaves the midpoint outside")
		expect(PrimitiveField.field_distance(blended, Vector3.ZERO) <= 0.0, "the smooth union includes the midpoint")
	)


func _bounds() -> void:
	step("Then a box bounds its half extents", func():
		var box := PrimitiveField.primitive_bounds(_box_primitive(Vector3(10.0, 0.0, 0.0), Vector3(2.0, 3.0, 4.0)))
		expect(is_equal_approx(box.position.x, 8.0) and is_equal_approx(box.size.x, 4.0), "the box bounds match")
	)
	step("Then smooth and shell grow the scan bounds", func():
		var request := _request([_box_primitive(Vector3.ZERO, Vector3(5.0, 5.0, 5.0))], 0, 2.0, 1.0)
		var value := PrimitiveField.scan_bounds(request)
		expect(not value.is_empty(), "the scan bounds exist")
		var min_cell: Vector3i = value[0]
		var max_cell: Vector3i = value[1]
		expect(min_cell.x <= -8 and max_cell.x >= 8, "the scan bounds include smooth and shell padding")
	)


func _warnings() -> void:
	step("Then a narrow cone at step 2 warns", func():
		var request := _request([_cone_primitive(Vector3(0.0, 0.0, 0.0), Vector3(0.0, 4.0, 0.0), 1.0, 0.0, 0.0)], 0, 0.0, 0.0, 2)
		var values := PrimitiveField.warnings(request)
		var found := false
		for value in values:
			if str(value).contains("below"):
				found = true
		expect(found, "the warning names the small radius")
	)


func _validation() -> void:
	step("Then a negative radius is invalid", func():
		var request := _request([_cone_primitive(Vector3.ZERO, Vector3(0.0, 4.0, 0.0), -1.0, 1.0, 0.0)], 0, 0.0, 0.0)
		expect(not PrimitiveField.validate_request(request).is_empty(), "the negative radius is refused")
	)
	step("Then two zero radii are invalid", func():
		var request := _request([_cone_primitive(Vector3.ZERO, Vector3(0.0, 4.0, 0.0), 0.0, 0.0, 0.0)], 0, 0.0, 0.0)
		expect(not PrimitiveField.validate_request(request).is_empty(), "the zero radii are refused")
	)
	step("Then a valid box is accepted", func():
		var request := _request([_box_primitive(Vector3.ZERO, Vector3(2.0, 2.0, 2.0))], 0, 0.0, 0.0)
		expect(PrimitiveField.validate_request(request).is_empty(), "the box is valid")
	)


func _rotation() -> void:
	step("Given a box rotated forty-five degrees around Y", func():
		var rotation := Quaternion(Vector3.UP, deg_to_rad(45.0))
		var primitive := {
			"kind": PrimitiveField.KIND_BOX,
			"center": Vector3.ZERO,
			"half_size": Vector3(2.0, 1.0, 0.5),
			"roundness": 0.0,
			"rotation": rotation,
		}
		var world := rotation * Vector3(1.0, 0.0, 0.0)
		var distance := PrimitiveField.primitive_distance(primitive, world)
		expect(is_equal_approx(distance, -0.5), "the rotated point keeps its local distance")
		var outside := rotation * Vector3(2.5, 0.0, 0.0)
		expect(is_equal_approx(PrimitiveField.primitive_distance(primitive, outside), 0.5), "the rotated face is on the local surface")
		var bounds := PrimitiveField.primitive_bounds(primitive)
		expect(is_equal_approx(bounds.size.x, sqrt(2.0) * 2.5), "the rotated x extent covers the diagonal")
		expect(is_equal_approx(bounds.size.y, 2.0), "the rotated y extent stays")
		expect(is_equal_approx(bounds.size.z, sqrt(2.0) * 2.5), "the rotated z extent covers the diagonal")
	)
	step("Given a cone rotated a quarter turn around Z", func():
		var rotation := Quaternion(Vector3(0, 0, 1), deg_to_rad(-90.0))
		var primitive := {
			"kind": PrimitiveField.KIND_CONE,
			"a": Vector3.ZERO,
			"b": Vector3(0.0, 4.0, 0.0),
			"r1": 1.0,
			"r2": 1.0,
			"roundness": 0.0,
			"rotation": rotation,
		}
		var bounds := PrimitiveField.primitive_bounds(primitive)
		expect(is_equal_approx(bounds.size.x, 6.0), "the rotated cone lies along x")
		expect(is_equal_approx(bounds.size.y, 2.0), "the rotated cone keeps its radius")
		expect(is_equal_approx(bounds.size.z, 2.0), "the rotated cone keeps its depth")
		expect(PrimitiveField.primitive_distance(primitive, Vector3(0.0, 2.0, 0.0)) <= 0.0, "the rotated cone center is inside")
	)


func _rasterize() -> void:
	step("Then a three-cell box writes twenty-seven cells", func():
		var request := _request([_box_primitive(Vector3.ZERO, Vector3(1.5, 1.5, 1.5))], 0, 0.0, 0.0)
		var result := PrimitiveField.rasterize(request, VoxelFrame.new())
		var changes: Dictionary = result["changes"]
		expect(changes.size() == 27, "the box writes 27 cells")
		expect(changes.has(Vector3i.ZERO), "the box includes the center")
		expect(not changes.has(Vector3i(2, 0, 0)), "the box excludes the outside cell")
	)


func _determinism() -> void:
	step("Then two identical requests match", func():
		var request := _request([_ellipsoid_primitive(Vector3.ZERO, Vector3(2.0, 3.0, 4.0))], 0, 1.0, 1.0)
		var first: Dictionary = PrimitiveField.rasterize(request, VoxelFrame.new())["changes"]
		var second: Dictionary = PrimitiveField.rasterize(request, VoxelFrame.new())["changes"]
		expect(first.keys() == second.keys(), "the cell keys match")
	)


func _box_primitive(center: Vector3, half_size: Vector3) -> Dictionary:
	return {"kind": PrimitiveField.KIND_BOX, "center": center, "half_size": half_size}


func _ellipsoid_primitive(center: Vector3, radii: Vector3) -> Dictionary:
	return {"kind": PrimitiveField.KIND_ELLIPSOID, "center": center, "radii": radii}


func _cone_primitive(a: Vector3, b: Vector3, r1: float, r2: float, roundness: float) -> Dictionary:
	return {"kind": PrimitiveField.KIND_CONE, "a": a, "b": b, "r1": r1, "r2": r2, "roundness": roundness}


func _request(primitives: Array, op: int, smooth: float, shell: float, step := 1) -> Dictionary:
	return {
		"primitives": primitives,
		"op": op,
		"smooth": smooth,
		"shell": shell,
		"step": step,
		"material": VoxelFrame.material(Color.WHITE),
	}
