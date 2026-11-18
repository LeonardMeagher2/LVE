extends "res://tests/test.gd"


const PrimitiveField := preload("res://Globals/State/Tools/PrimitiveField.gd")
const SPAN := 64
const FILLED := 32
const WARMUPS := 1
const REPEATS := 2


func _ready() -> void:
	timeout = 600.0
	test("each primitive rasterize case reports its cost", _cost, "primitive_cost")


func _cost() -> void:
	var solid := _solid_frame()
	var box := _box(Vector3.ZERO, Vector3.ONE * (SPAN * 0.5))
	step("When the rasterize cases run warmed", func():
		_measure("add_sharp", func():
			return PrimitiveField.rasterize(_request([box], 0, 0.0, 1), VoxelFrame.new())
		)
		_measure("add_step2", func():
			return PrimitiveField.rasterize(_request([box], 0, 0.0, 2), VoxelFrame.new())
		)
		_measure("add_smooth", func():
			var primitives := [box, _ellipsoid(Vector3(8, 0, 0), Vector3(24, 24, 24))]
			return PrimitiveField.rasterize(_request(primitives, 0, 4.0, 1), solid)
		)
		_measure("subtract", func():
			return PrimitiveField.rasterize(_request([box], 1, 0.0, 1), solid)
		)
		_measure("intersect", func():
			return PrimitiveField.rasterize(_request([_box(Vector3.ZERO, Vector3(8, 8, 8))], 2, 0.0, 1), solid)
		)
	)
	step("Then every case writes cells", func():
		expect(solid.count() == FILLED * FILLED * FILLED, "the solid frame holds its block")
	)


func _measure(name: String, body: Callable) -> void:
	var times: Array[int] = []
	var applied := 0
	for index in WARMUPS + REPEATS:
		var started := Time.get_ticks_usec()
		var result: Dictionary = body.call()
		times.append(Time.get_ticks_usec() - started)
		applied = int(result.get("applied", 0))
	var measured := times.slice(WARMUPS)
	measured.sort()
	var median: int = measured[measured.size() / 2]
	print("MEASURE primitive_cost %s: us=%d applied=%d" % [name, median, applied])


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


func _box(center: Vector3, half_size: Vector3) -> Dictionary:
	return {"kind": PrimitiveField.KIND_BOX, "center": center, "half_size": half_size}


func _ellipsoid(center: Vector3, radii: Vector3) -> Dictionary:
	return {"kind": PrimitiveField.KIND_ELLIPSOID, "center": center, "radii": radii}


func _request(primitives: Array, op: int, smooth: float, step: int) -> Dictionary:
	return {
		"primitives": primitives,
		"op": op,
		"smooth": smooth,
		"shell": 0.0,
		"step": step,
		"material": VoxelFrame.material(Color.WHITE),
	}
