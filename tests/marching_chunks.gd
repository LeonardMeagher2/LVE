extends "res://tests/test.gd"


const VIEW := preload("res://tests/helpers/marching_view.gd")

var _view


func _ready() -> void:
	timeout = 180.0
	test("a painted block across 27 chunks renders closed and unique", _large_block, "chunk_large_block")
	test("a painted wall across the seam renders closed", _seam_wall, "chunk_seam_wall")
	test("a painted staircase joins across chunks", _diagonal_chain, "chunk_diagonal_chain")
	test("a painted material boundary keeps two surfaces", _material_boundary, "chunk_material_boundary")


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
	step("Then the two colours render their own surfaces", func():
		_view.collect()
		expect(_view.closed(), "both chains have no boundary")
		expect(_view.components() == 2, "the material change splits the surface")
		expect(_view.duplicates() == 0, "no triangle is emitted twice")
	)
