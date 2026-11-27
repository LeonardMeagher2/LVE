extends "res://tests/test.gd"


const VIEW := preload("res://tests/helpers/marching_view.gd")

var _view
var _enclosed_builder
var _shell_builder
var _slice_builder


func _ready() -> void:
	timeout = 180.0
	test("a painted block across 27 chunks renders closed and unique", _large_block, "chunk_large_block")
	test("a painted wall across the seam renders closed", _seam_wall, "chunk_seam_wall")
	test("a painted staircase joins across chunks", _diagonal_chain, "chunk_diagonal_chain")
	test("a painted material boundary keeps two surfaces", _material_boundary, "chunk_material_boundary")
	test("an enclosed chunk builds no surface", _enclosed_chunk, "chunk_enclosed")
	test("a slice keeps the cap at a chunk row edge", _slice_cap, "chunk_slice_cap")


func _large_block() -> void:
	step("Given a 32-cell block painted in the application", func():
		var cells := {}
		for z in range(-8, 24):
			for y in range(-8, 24):
				for x in range(-8, 24):
					cells[Vector3i(x, y, z)] = VoxelFrame.material(Color.WHITE)
		_view = VIEW.new(self)
		_view.apply(cells)
	)
	await _view.settle()
	step("Then the rendered surfaces are closed, single, and unique", func():
		_view.collect()
		expect(_view.closed(), "the surface has no boundary")
		expect(_view.components() == 1, "the surface is one piece")
		expect(_view.duplicates() == 0, "no triangle is emitted twice")
		expect(_view.bounds().is_equal_approx(AABB(Vector3.ONE * -8.5, Vector3.ONE * 32.0)), "the surface keeps the block extent")
	)


func _seam_wall() -> void:
	step("Given a one-cell wall painted across the seam", func():
		var cells := {}
		for z in range(-8, 24):
			for y in range(-8, 24):
				cells[Vector3i(0, y, z)] = VoxelFrame.material(Color.WHITE)
		_view = VIEW.new(self)
		_view.apply(cells)
	)
	await _view.settle()
	step("Then the wall renders as one closed surface", func():
		_view.collect()
		expect(_view.closed(), "the wall has no boundary")
		expect(_view.components() == 1, "the wall is one surface")
		expect(_view.duplicates() == 0, "no triangle is emitted twice")
		expect(_view.bounds().is_equal_approx(AABB(Vector3(-0.5, -8.5, -8.5), Vector3(1.0, 32.0, 32.0))), "the wall keeps its extent")
	)


func _diagonal_chain() -> void:
	step("Given a same-material staircase painted across four chunk columns", func():
		var cells := {}
		for index in range(-20, 21):
			cells[Vector3i(index, index, 0)] = VoxelFrame.material(Color.WHITE)
		_view = VIEW.new(self)
		_view.apply(cells)
	)
	await _view.settle()
	step("Then the staircase renders as one closed surface", func():
		_view.collect()
		expect(_view.closed(), "the staircase has no boundary")
		expect(_view.components() == 1, "the staircase is one surface")
		expect(_view.duplicates() == 0, "no triangle is emitted twice")
	)


func _material_boundary() -> void:
	step("Given a staircase painted with a material change at the seam", func():
		var cells := {}
		for index in range(-20, 21):
			var material := VoxelFrame.material(Color.WHITE) if index < 0 else VoxelFrame.material(Color.RED)
			cells[Vector3i(index, index, 0)] = material
		_view = VIEW.new(self)
		_view.apply(cells)
	)
	await _view.settle()
	step("Then the two colours render on one joined surface", func():
		_view.collect()
		expect(_view.closed(), "both chains have no boundary")
		expect(_view.components() == 1, "the material change keeps one surface")
		expect(_view.duplicates() == 0, "no triangle is emitted twice")
	)


func _enclosed_chunk() -> void:
	step("Given a solid 48-cube with an enclosed chunk", func():
		var frame := VoxelFrame.new()
		var cells := {}
		var material := VoxelFrame.material(Color.WHITE)
		for z in 48:
			for y in 48:
				for x in 48:
					cells[Vector3i(x, y, z)] = material
		frame.set_cells(cells)
		_enclosed_builder = _chunk_builder(frame, Vector3i(1, 1, 1))
		_shell_builder = _chunk_builder(frame, Vector3i.ZERO)
	)
	step("Then the enclosed chunk builds nothing and the shell keeps its surface", func():
		expect(_enclosed_builder.surface_arrays[Mesh.ARRAY_VERTEX].is_empty(), "the enclosed chunk has no vertices")
		expect(_enclosed_builder.enclosed_culled, "the enclosed chunk reports a cull")
		expect(not _shell_builder.surface_arrays[Mesh.ARRAY_VERTEX].is_empty(), "the shell chunk builds vertices")
		expect(not _shell_builder.enclosed_culled, "the shell chunk does not report a cull")
	)


func _chunk_builder(frame: VoxelFrame, location: Vector3i) -> VoxelMarchingMeshBuilder:
	var builder := VoxelMarchingMeshBuilder.new()
	builder.source_frame = frame
	builder.chunk_location = location
	builder.smooth_normals = true
	builder.run()
	return builder


func _slice_cap() -> void:
	step("Given a solid two-chunk column", func():
		var frame := VoxelFrame.new()
		var cells := {}
		var material := VoxelFrame.material(Color.WHITE)
		for z in 16:
			for y in range(-16, 16):
				for x in 16:
					cells[Vector3i(x, y, z)] = material
		frame.set_cells(cells)
		_slice_builder = VoxelMarchingMeshBuilder.new()
		_slice_builder.source_frame = frame
		_slice_builder.chunk_location = Vector3i.ZERO
		_slice_builder.smooth_normals = true
		_slice_builder.slice_axis = Vector3.Axis.AXIS_Y
		_slice_builder.slice_index = 0
		_slice_builder.slice_count = 2
		_slice_builder.run()
	)
	step("Then the upper chunk keeps its lower cap and stays closed", func():
		var arrays: Array = _slice_builder.surface_arrays
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var lowest := INF
		for position: Vector3 in positions:
			lowest = minf(lowest, position.y)
		expect(is_equal_approx(lowest, -0.5), "the slice keeps the lower cap at y -0.5")
		var view = VIEW.new(self)
		view.positions = positions
		view.indices = arrays[Mesh.ARRAY_INDEX]
		expect(view.closed(), "the sliced slab has no boundary")
	)
