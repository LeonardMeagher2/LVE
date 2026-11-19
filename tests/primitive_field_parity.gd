extends "res://tests/test.gd"


const PrimitiveField := preload("res://Globals/State/Tools/PrimitiveField.gd")
const PrimitiveReference := preload("res://tests/benchmarks/primitive_reference.gd")
const FILLED := 16
const SEED := 104729
const RANDOM_CASES := 40


func _ready() -> void:
	timeout = 600.0
	test("the blend matches the reference on fixed cases", _fixed_cases, "fixed_cases")
	test("the blend matches the reference on random cases", _random_cases, "random_cases")


func _fixed_cases() -> void:
	var box := _box(Vector3.ZERO, Vector3.ONE * 16.0)
	var ellipsoid := _ellipsoid(Vector3(8, 0, 0), Vector3(12, 12, 12))
	var cone := {"kind": PrimitiveField.KIND_CONE, "a": Vector3(-8, -8, -8), "b": Vector3(8, 8, 8), "r1": 6.0, "r2": 2.0, "roundness": 0.5}
	var round_box := _box(Vector3(10, 0, 0), Vector3(5, 12, 12), 0.5)
	var shell_box := _box(Vector3.ZERO, Vector3.ONE * 12.0)
	var cases: Array = []
	cases.append(_request([box, ellipsoid], 0, 4.0, 1, 0.0))
	cases.append(_request([box, ellipsoid], 0, 4.0, 2, 0.0))
	cases.append(_request([box, cone], 0, 3.0, 1, 0.0))
	cases.append(_request([round_box, box], 0, 2.0, 1, 0.0))
	cases.append(_request([shell_box], 0, 2.0, 1, 3.0))
	cases.append(_request([box, ellipsoid, cone, round_box], 0, 5.0, 1, 2.0))
	cases.append(_request([ellipsoid], 0, 0.0, 1, 0.0))
	cases.append(_request([box], 1, 0.0, 1, 0.0))
	cases.append(_request([box], 2, 0.0, 2, 0.0))
	var solid := _solid_frame()
	step("When the reference and the field run the same cases", func():
		for index in range(cases.size()):
			var request: Dictionary = cases[index]
			_compare(PrimitiveField.rasterize(request, _solid_frame()), PrimitiveReference.rasterize(request, solid), index)
	)


func _random_cases() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = SEED
	step("When the reference and the field run random cases", func():
		for index in range(RANDOM_CASES):
			var request := _random_request(random)
			var frame := _random_frame(random)
			_compare(PrimitiveField.rasterize(request, frame), PrimitiveReference.rasterize(request, frame), index)
	)


func _compare(result_a: Dictionary, result_b: Dictionary, index: int) -> void:
	var label := "case %d: " % index
	expect(bool(result_a.get("blend_skipped", false)) == bool(result_b.get("blend_skipped", false)), label + "the blend skip flag matches")
	if bool(result_a.get("blend_skipped", false)):
		return
	var changes_a: Dictionary = result_a["changes"]
	var changes_b: Dictionary = result_b["changes"]
	expect(changes_a.size() == changes_b.size(), label + "the applied cell count matches (%d vs %d)" % [changes_a.size(), changes_b.size()])
	var mismatched := 0
	for cell: Vector3i in changes_a:
		var material_a: PackedFloat32Array = changes_a[cell]
		var material_b: PackedFloat32Array = changes_b.get(cell, VoxelFrame.material(Color.MAGENTA))
		if not material_a == material_b:
			mismatched += 1
			if mismatched == 1:
				print("PARITY first mismatch at %s" % str(cell))
	expect(mismatched == 0, label + "every applied cell holds the same material")
	var reference_only := 0
	for cell: Vector3i in changes_b:
		if not changes_a.has(cell):
			reference_only += 1
			if reference_only == 1:
				print("PARITY reference-only cell at %s" % str(cell))
	expect(reference_only == 0, label + "no cell appears only in the reference")
	expect(result_a.get("changed_min", Vector3i.MAX) == result_b.get("changed_min", Vector3i.MAX), label + "the changed min corner matches")
	expect(result_a.get("changed_max", Vector3i.MIN) == result_b.get("changed_max", Vector3i.MIN), label + "the changed max corner matches")


func _random_request(random: RandomNumberGenerator) -> Dictionary:
	var primitives: Array = []
	var count := random.randi_range(1, 4)
	for index in range(count):
		var kind := random.randi_range(0, 2)
		var rotation := Quaternion(Vector3(1, 1, 1).normalized(), random.randf_range(0.0, TAU))
		if kind == PrimitiveField.KIND_BOX:
			primitives.append(_box(Vector3.ZERO, Vector3.ONE * random.randf_range(4.0, 16.0), random.randf_range(0.0, 1.0), rotation))
		elif kind == PrimitiveField.KIND_ELLIPSOID:
			primitives.append(_ellipsoid(Vector3.ZERO, Vector3.ONE * random.randf_range(4.0, 16.0), rotation))
		else:
			var a := Vector3.ONE * random.randf_range(-12.0, 12.0)
			var b := Vector3.ONE * random.randf_range(-12.0, 12.0)
			var r1 := random.randf_range(1.0, 8.0)
			var r2 := random.randf_range(1.0, 8.0)
			primitives.append({"kind": PrimitiveField.KIND_CONE, "a": a, "b": b, "r1": r1, "r2": r2, "roundness": random.randf_range(0.0, 1.0), "rotation": rotation})
	var op := random.randi_range(0, 2)
	var smooth := random.randf_range(0.0, 4.0)
	if op != 0:
		smooth = 0.0
	var shell := random.randf_range(0.0, 2.0) if random.randf() < 0.3 else 0.0
	return _request(primitives, op, smooth, random.randi_range(1, 2), shell)


func _random_frame(random: RandomNumberGenerator) -> VoxelFrame:
	var frame := VoxelFrame.new()
	var material := VoxelFrame.material(Color.WHITE)
	var changes := {}
	var half := FILLED / 2
	if random.randf() < 0.8:
		for x in range(-half, half):
			for y in range(-half, half):
				for z in range(-half, half):
					if random.randf() < 0.35:
						changes[Vector3i(x, y, z)] = material
	var blocks := random.randi_range(0, 3)
	for index in range(blocks):
		var corner := Vector3i(
			random.randi_range(-half - 2, half - 2),
			random.randi_range(-half - 2, half - 2),
			random.randi_range(-half - 2, half - 2)
		)
		var extent := Vector3i(
			random.randi_range(4, 8),
			random.randi_range(4, 8),
			random.randi_range(4, 8)
		)
		for dx in range(extent.x):
			for dy in range(extent.y):
				for dz in range(extent.z):
					changes[corner + Vector3i(dx, dy, dz)] = material
	if changes.is_empty():
		changes[Vector3i.ZERO] = material
	frame.set_cells(changes)
	return frame


func _solid_frame() -> VoxelFrame:
	var frame := VoxelFrame.new()
	var material := VoxelFrame.material(Color.WHITE)
	var changes := {}
	var half := FILLED / 2
	for x in range(-half, half):
		for y in range(-half, half):
			for z in range(-half, half):
				changes[Vector3i(x, y, z)] = material
	frame.set_cells(changes)
	return frame


func _box(center: Vector3, half_size: Vector3, roundness := 0.0, rotation := Quaternion.IDENTITY) -> Dictionary:
	return {"kind": PrimitiveField.KIND_BOX, "center": center, "half_size": half_size, "roundness": roundness, "rotation": rotation}


func _ellipsoid(center: Vector3, radii: Vector3, rotation := Quaternion.IDENTITY) -> Dictionary:
	return {"kind": PrimitiveField.KIND_ELLIPSOID, "center": center, "radii": radii, "rotation": rotation}


func _request(primitives: Array, op: int, smooth: float, step: int, shell: float) -> Dictionary:
	return {
		"primitives": primitives,
		"op": op,
		"smooth": smooth,
		"shell": shell,
		"step": step,
		"material": VoxelFrame.material(Color.WHITE),
	}
