extends "res://tests/test.gd"

## Bakes and reads the voxel ambient occlusion. The unit cases read the four
## corner levels of one cell face, so one corner at a time is exact. The builder
## cases cover the color table and the split of a merged face along a crease.

const SURFACE := preload("res://Globals/Rendering/VoxelSurface.gd")


func _ready() -> void:
	test("a free face corner stays bright", _free_corner)
	test("a concave corner darkens at both ends", _concave_ends)
	test("a direct outside cell never occludes", _direct_outside)
	test("both side cells darken a corner the most", _both_sides)
	test("a negative face reads the same layer", _negative_face)
	test("a crease splits a merged face", _merged_crease)
	test("the builder bakes the strength into vertex colors", _builder_strength)


func _frame(cells: Array) -> VoxelFrame:
	var frame := VoxelFrame.new()
	for cell: Vector3i in cells:
		frame.set_cell(cell, VoxelFrame.material(Color.WHITE))
	return frame


func _code(frame: VoxelFrame, plane: Vector3i, cell: Vector3i) -> int:
	return SURFACE._face_ao_code(frame, plane, cell)


func _level(code: int, index: int) -> int:
	return (code >> (index * 2)) & 3


func _free_corner() -> void:
	var frame := _frame([Vector3i(1, 0, 0)])
	# The +Y face of cell (1, 0, 0).
	var plane := Vector3i(1, 1, 1)
	var code := _code(frame, plane, Vector3i(1, 0, 0))
	step("Given one face cell with nothing around it", func():
		pass
	)
	step("Then every corner of the face stays bright", func():
		for index in 4:
			expect(_level(code, index) == 3, "corner %d stays bright" % index)
	)


func _concave_ends() -> void:
	# A one-cell wall stands on the low x side of a floor. Its top face is
	# covered, so only the floor cell at x = 1 exposes its +Y face.
	var frame := _frame([Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0)])
	var plane := Vector3i(1, 1, 1)
	var code := _code(frame, plane, Vector3i(1, 0, 0))
	step("Given a floor face beside a wall", func():
		pass
	)
	step("Then the two crease corners of the face darken", func():
		expect(_level(code, 0) == 2, "the low z, low x corner darkens")
		expect(_level(code, 1) == 2, "the high z, low x corner darkens")
	)
	step("Then the corners away from the wall stay bright", func():
		expect(_level(code, 2) == 3, "the low z, high x corner stays bright")
		expect(_level(code, 3) == 3, "the high z, high x corner stays bright")
	)


func _direct_outside() -> void:
	# The cell directly in front of a face cannot shade that face. A face that
	# is exposed always has an empty direct cell, so the cell face must ignore
	# the one that sits at the face cell tangent.
	var frame := _frame([Vector3i(1, 0, 0), Vector3i(1, 1, 0)])
	var plane := Vector3i(1, 1, 1)
	var code := _code(frame, plane, Vector3i(1, 0, 0))
	step("Given an occluder directly in front of the face", func():
		expect(frame.has(Vector3i(1, 1, 0)), "the direct cell is present")
	)
	step("Then the corner ignores the direct cell", func():
		for index in 4:
			expect(_level(code, index) == 3, "corner %d stays bright" % index)
	)


func _both_sides() -> void:
	var frame := _frame([Vector3i(1, 0, 0), Vector3i(1, 1, 1), Vector3i(0, 1, 0)])
	var plane := Vector3i(1, 1, 1)
	var code := _code(frame, plane, Vector3i(1, 0, 0))
	step("Given both side cells of one corner are occupied", func():
		pass
	)
	step("Then the corner reaches the darkest level", func():
		expect(_level(code, 1) == 0, "the high z, low x corner reaches the dark floor")
		expect(_level(code, 0) == 2, "the other side corner keeps one side lit")
	)


func _negative_face() -> void:
	# The -X face of cell (1, 0, 0) looks at an occluder at (0, 1, 0). The
	# negative face must sample the same layer as the positive face.
	var frame := _frame([Vector3i(1, 0, 0), Vector3i(0, 1, 0)])
	var plane := Vector3i(0, -1, 1)
	var code := _code(frame, plane, Vector3i(1, 0, 0))
	step("Given an occluder beside a negative face", func():
		pass
	)
	step("Then the negative face darkens at the corner", func():
		expect(_level(code, 1) == 2, "the high y, low z corner darkens")
		expect(_level(code, 3) == 2, "the high y, high z corner darkens")
		expect(_level(code, 0) == 3, "the low y, low z corner stays bright")
		expect(_level(code, 2) == 3, "the low y, high z corner stays bright")
	)


func _merged_crease() -> void:
	step("Given a floor with a wall along one edge", func():
		var frame := VoxelFrame.new()
		for x in 6:
			for z in 6:
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		for z in 6:
			frame.set_cell(Vector3i(0, 1, z), VoxelFrame.material(Color.WHITE))
		var floor := _floor_top(_build(frame, 1.0))
		var crease := Vector3(0.5, 0.5, -0.5)
		var next := Vector3(1.5, 0.5, -0.5)
		expect(floor.size() > 4, "the crease keeps the floor from merging into one quad")
		expect(floor.has(crease), "the crease keeps a vertex beside the wall")
		if floor.has(crease):
			expect(is_equal_approx(floor[crease], 2.0 / 3.0), "the crease vertex holds the dark level")
		expect(floor.has(next), "the next column keeps its own vertex")
		if floor.has(next):
			expect(is_equal_approx(floor[next], 1.0), "the next column stays bright")
	)


func _builder_strength() -> void:
	step("Given a concave frame built with and without ambient occlusion", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(0, 1, 0), VoxelFrame.material(Color.WHITE))
		var full := _build(frame, 1.0)
		var half := _build(frame, 0.5)
		var off := _build(frame, 0.0)
		expect(full[Mesh.ARRAY_COLOR] is PackedColorArray, "the full-strength mesh carries vertex colors")
		expect(half[Mesh.ARRAY_COLOR] is PackedColorArray, "the half-strength mesh carries vertex colors")
		expect(off[Mesh.ARRAY_COLOR] == null, "the mesh without ambient occlusion omits vertex colors")
		var full_min := _darkest(full[Mesh.ARRAY_COLOR])
		var half_min := _darkest(half[Mesh.ARRAY_COLOR])
		expect(is_equal_approx(full_min, 2.0 / 3.0), "the full strength shades one crease")
		expect(is_equal_approx(half_min, 1.0 - (1.0 - 2.0 / 3.0) * 0.5), "the half strength scales the same crease")
		expect(half_min <= 1.0, "the half strength stays inside the valid range")
	)


func _build(frame: VoxelFrame, strength: float) -> Array:
	var job := VoxelMeshBuilder.new()
	job.source_frame = frame
	job.ao_strength = strength
	job.run()
	return job.surface_arrays


func _darkest(colors: PackedColorArray) -> float:
	var value := 1.0
	for color: Color in colors:
		value = minf(value, color.r)
	return value


func _floor_top(arrays: Array) -> Dictionary:
	var top := {}
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	for index in positions.size():
		if normals[index].is_equal_approx(Vector3.UP) and is_equal_approx(positions[index].y, 0.5):
			top[positions[index]] = colors[index].r
	return top
