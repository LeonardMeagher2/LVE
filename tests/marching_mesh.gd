extends "res://tests/test.gd"


const VIEW := preload("res://tests/helpers/marching_view.gd")

var _view
var _renderer
var _bar
var _dialog
var _block_mesh: Mesh
var _seed := 1


func _ready() -> void:
	timeout = 60.0
	test("one painted voxel draws a closed octahedron", _single_voxel, "march_single_voxel")
	test("one painted voxel in a negative chunk keeps the shape", _negative_voxel, "march_single_voxel_negative")
	test("two painted adjacent voxels merge", _adjacent_voxels, "march_adjacent_voxels")
	test("two materials meet on their own edge", _material_boundary, "march_material_boundary")
	test("a material seam across two chunks stays closed", _material_seam_chunk, "march_material_seam_chunk")
	test("a diagonal pair of one material joins without a lid", _diagonal_join, "march_diagonal_join")
	test("a diagonal pair of two materials stays apart", _diagonal_separate, "march_diagonal_separate")
	test("a painted random model stays closed across seams", _random_model, "march_watertight")
	test("a painted 2x2x2 block stays closed", _solid_block, "march_solid_block")
	test("a painted 16-cell slab spans the chunk", _slab, "march_slab")
	test("a painted flat plate stays one closed surface", _flat_plate, "march_flat_plate")
	test("a painted hollow shell keeps its cavity", _hollow_shell, "march_hollow_shell")
	test("a straight material seam keeps its diagonal vertex", _straight_material_seam, "march_straight_material_seam")
	test("an edge seam outside the shared edge keeps its vertex", _edge_seam_span, "march_edge_seam_span")
	test("an edge seam beyond half a cell keeps its vertex", _edge_seam_travel, "march_edge_seam_travel")
	test("a four-material face colours each triangle from its own cell", _four_material_face, "march_four_material_face")
	test("the low-poly style renders in the editor viewport", _viewport_style, "march_viewport_style")
	test("the settings modal stores one undoable style change", _style_undo, "march_style_undo")


func _single_voxel() -> void:
	step("Given one voxel painted in the editor", func():
		_view = VIEW.new(self)
		_view.apply({Vector3i.ZERO: VoxelFrame.material(Color(0.8, 0.2, 0.1))})
	)
	await _view.settle()
	step("Then the chunk draws a closed octahedron", func():
		_view.collect()
		expect(_view.indices.size() == 24, "the octahedron has eight triangles")
		expect(_view.closed(), "the surface has no boundary")
		expect(_view.bounds().is_equal_approx(AABB(Vector3.ONE * -0.5, Vector3.ONE)), "the surface fills one voxel")
		var outward := true
		for offset in range(0, _view.indices.size(), 3):
			var centroid: Vector3 = (_view.positions[_view.indices[offset]] + _view.positions[_view.indices[offset + 1]] + _view.positions[_view.indices[offset + 2]]) / 3.0
			if _view.normals[_view.indices[offset]].dot(centroid) <= 0.0:
				outward = false
		expect(outward, "every normal points away from the voxel")
		var material: PackedFloat32Array = State.get_current_voxel_frame().get_material(Vector3i.ZERO)
		expect(material == VoxelFrame.material(Color(0.8, 0.2, 0.1)), "the document keeps the painted material")
	)


func _negative_voxel() -> void:
	step("Given one voxel painted at the corner of a negative chunk", func():
		_view = VIEW.new(self)
		_view.apply({Vector3i(-1, -1, -1): VoxelFrame.material(Color.WHITE)})
	)
	await _view.settle()
	step("Then the surface sits around that cell", func():
		_view.collect()
		expect(_view.indices.size() == 24, "the octahedron has eight triangles")
		expect(_view.closed(), "the surface has no boundary")
		expect(_view.bounds().is_equal_approx(AABB(Vector3.ONE * -1.5, Vector3.ONE)), "the surface fills one voxel")
	)


func _adjacent_voxels() -> void:
	step("Given two painted voxels that share a face", func():
		_view = VIEW.new(self)
		_view.apply({
			Vector3i.ZERO: VoxelFrame.material(Color.WHITE),
			Vector3i(1, 0, 0): VoxelFrame.material(Color.WHITE),
		})
	)
	await _view.settle()
	step("Then the shared face is gone and the surface stays closed", func():
		_view.collect()
		expect(_view.closed(), "the merged surface has no boundary")
		expect(not _view.has_vertex(Vector3(0.5, 0.0, 0.0)), "no vertex remains on the shared face")
		expect(_view.bounds().is_equal_approx(AABB(Vector3.ONE * -0.5, Vector3(2.0, 1.0, 1.0))), "the surface spans both cells")
	)


func _material_boundary() -> void:
	step("Given two painted voxels with different materials", func():
		_view = VIEW.new(self)
		_view.apply({
			Vector3i.ZERO: VoxelFrame.material(Color.RED),
			Vector3i(1, 0, 0): VoxelFrame.material(Color.BLUE),
		})
	)
	await _view.settle()
	step("Then each triangle carries one material and the seam has an edge", func():
		_view.collect()
		expect(_view.closed(), "the seam keeps the surface closed")
		var mixed := 0
		var red := 0
		var blue := 0
		for offset in range(0, _view.indices.size(), 3):
			var first: Color = _view.colors[_view.indices[offset]]
			var second: Color = _view.colors[_view.indices[offset + 1]]
			var third: Color = _view.colors[_view.indices[offset + 2]]
			if first != second or second != third:
				mixed += 1
			elif first == Color.RED:
				red += 1
			elif first == Color.BLUE:
				blue += 1
		expect(mixed == 0, "no triangle spans both materials")
		expect(red > 0 and blue > 0, "both materials draw their own triangles")
		var shared := 0
		for index in _view.positions.size():
			for other in range(index + 1, _view.positions.size()):
				if not _view.positions[index].is_equal_approx(_view.positions[other]):
					continue
				if _view.colors[index] != _view.colors[other]:
					shared += 1
					break
		expect(shared > 0, "the seam has two materials on one line")
	)


func _material_seam_chunk() -> void:
	step("Given two materials that meet at a chunk border", func():
		_view = VIEW.new(self)
		_view.apply({
			Vector3i(VoxelFrame.CHUNK_SIZE - 1, 0, 0): VoxelFrame.material(Color.RED),
			Vector3i(VoxelFrame.CHUNK_SIZE, 0, 0): VoxelFrame.material(Color.BLUE),
		})
	)
	await _view.settle()
	step("Then both chunks split the seam the same way", func():
		_view.collect()
		expect(_view.closed(), "the seam has no boundary across the border")
		expect(_view.duplicates() == 0, "no triangle is emitted twice")
		expect(not _view.indices.is_empty(), "the seam draws triangles")
	)


func _diagonal_join() -> void:
	step("Given a diagonal pair of one material over a floor", func():
		_view = VIEW.new(self)
		var cells := {}
		for z in 4:
			for x in 4:
				cells[Vector3i(x, 0, z)] = VoxelFrame.material(Color.WHITE)
		cells[Vector3i(0, 1, 0)] = VoxelFrame.material(Color.RED)
		cells[Vector3i(1, 1, 1)] = VoxelFrame.material(Color.RED)
		_view.apply(cells)
	)
	await _view.settle()
	step("Then the pair joins and the empty cells stay open", func():
		_view.collect()
		expect(_view.duplicates() == 0, "no triangle is emitted twice")
		var lid := 0
		for offset in range(0, _view.indices.size(), 3):
			var first: Color = _view.colors[_view.indices[offset]]
			if first != Color.RED:
				continue
			var centre: Vector3 = (_view.positions[_view.indices[offset]] + _view.positions[_view.indices[offset + 1]] + _view.positions[_view.indices[offset + 2]]) / 3.0
			var covers_first := centre.x > 0.6 and centre.x < 1.4 and centre.z > -0.4 and centre.z < 0.4
			var covers_second := centre.x > -0.4 and centre.x < 0.4 and centre.z > 0.6 and centre.z < 1.4
			if centre.y > 1.1 and (covers_first or covers_second):
				lid += 1
		expect(lid == 0, "no material covers the empty diagonal cells")
		var bridge := 0
		for offset in range(0, _view.indices.size(), 3):
			var first: Color = _view.colors[_view.indices[offset]]
			if first != Color.RED:
				continue
			var centre: Vector3 = (_view.positions[_view.indices[offset]] + _view.positions[_view.indices[offset + 1]] + _view.positions[_view.indices[offset + 2]]) / 3.0
			if absf(centre.x - 0.5) < 0.35 and absf(centre.z - 0.5) < 0.35 and centre.y > 0.5 and centre.y < 1.5:
				bridge += 1
		expect(bridge > 0, "the pair joins across the shared corner")
	)


func _diagonal_separate() -> void:
	step("Given a diagonal pair of two materials over a floor", func():
		_view = VIEW.new(self)
		var cells := {}
		for z in 4:
			for x in 4:
				cells[Vector3i(x, 0, z)] = VoxelFrame.material(Color.WHITE)
		cells[Vector3i(0, 1, 0)] = VoxelFrame.material(Color.RED)
		cells[Vector3i(1, 1, 1)] = VoxelFrame.material(Color.BLUE)
		_view.apply(cells)
	)
	await _view.settle()
	step("Then the two materials keep their own corners", func():
		_view.collect()
		expect(not _view.indices.is_empty(), "the surface draws triangles")
		var mixed := 0
		var red := 0
		var blue := 0
		for offset in range(0, _view.indices.size(), 3):
			var first: Color = _view.colors[_view.indices[offset]]
			if _view.colors[_view.indices[offset + 1]] != first or _view.colors[_view.indices[offset + 2]] != first:
				mixed += 1
			elif first == Color.RED:
				red += 1
			elif first == Color.BLUE:
				blue += 1
		expect(mixed == 0, "no triangle spans both materials")
		expect(red > 0 and blue > 0, "both materials draw their own triangles")
	)


func _random_model() -> void:
	step("Given a painted random model across eight chunks", func():
		_view = VIEW.new(self)
		_view.apply(_random_cells())
	)
	await _view.settle()
	step("Then the rendered model has no boundary and no duplicate", func():
		_view.collect()
		expect(not _view.indices.is_empty(), "the model draws surfaces")
		expect(_view.closed(), "the model has no boundary")
		expect(_view.duplicates() == 0, "no triangle is emitted twice")
	)


func _solid_block() -> void:
	step("Given a painted 2x2x2 block", func():
		_view = VIEW.new(self)
		var cells := {}
		for z in 2:
			for y in 2:
				for x in 2:
					cells[Vector3i(x, y, z)] = VoxelFrame.material(Color.WHITE)
		_view.apply(cells)
	)
	await _view.settle()
	step("Then the surface is closed around the block", func():
		_view.collect()
		expect(_view.closed(), "the block surface has no boundary")
		expect(_view.components() == 1, "the block is one surface")
		expect(_view.bounds().is_equal_approx(AABB(Vector3.ONE * -0.5, Vector3.ONE * 2.0)), "the surface fills the block")
	)


func _slab() -> void:
	step("Given sixteen painted voxels in a line", func():
		_view = VIEW.new(self)
		var cells := {}
		for x in VoxelFrame.CHUNK_SIZE:
			cells[Vector3i(x, 0, 0)] = VoxelFrame.material(Color.WHITE)
		_view.apply(cells)
	)
	await _view.settle()
	step("Then the surface spans the line and stays closed", func():
		_view.collect()
		expect(_view.closed(), "the slab surface has no boundary")
		expect(_view.bounds().is_equal_approx(AABB(Vector3.ONE * -0.5, Vector3(16.0, 1.0, 1.0))), "the slab keeps its length and thickness")
	)


func _flat_plate() -> void:
	step("Given a painted 12x12 flat plate", func():
		var cells := {}
		for z in 12:
			for x in 12:
				cells[Vector3i(x, 0, z)] = VoxelFrame.material(Color.WHITE)
		_view = VIEW.new(self)
		_view.apply(cells)
	)
	await _view.settle()
	step("Then the plate is one closed surface", func():
		_view.collect()
		expect(_view.closed(), "the plate has no boundary")
		expect(_view.components() == 1, "the plate is one surface")
		expect(_view.duplicates() == 0, "no triangle is emitted twice")
	)


func _hollow_shell() -> void:
	step("Given a painted hollow three-cube shell", func():
		_view = VIEW.new(self)
		var cells := {}
		for z in range(-1, 2):
			for y in range(-1, 2):
				for x in range(-1, 2):
					if x == 0 and y == 0 and z == 0:
						continue
					cells[Vector3i(x, y, z)] = VoxelFrame.material(Color.WHITE)
		_view.apply(cells)
	)
	await _view.settle()
	step("Then the shell and its cavity both draw", func():
		_view.collect()
		expect(_view.closed(), "the shell surface has no boundary")
		expect(_view.components() == 2, "the shell and the cavity are two surfaces")
		expect(_view.bounds().is_equal_approx(AABB(Vector3.ONE * -1.5, Vector3.ONE * 3.0)), "the shell keeps its three-cell extent")
		expect(_view.has_vertex(Vector3(0.5, 0.0, 0.0)), "the inner cavity has its own surface")
	)


func _straight_material_seam() -> void:
	step("Given the selected red, yellow, blue, and green seam", func():
		_view = VIEW.new(self)
		_view.apply(_straight_seam_cells())
	)
	await _view.settle()
	step("Then the seam keeps its straight diagonal vertex", func():
		_view.collect()
		expect(not _view.indices.is_empty(), "the seam draws triangles")
		expect(_view.has_vertex(Vector3(3.25, 0.75, -4.5)), "the seam keeps the midpoint of its diagonal")
		expect(not _view.has_vertex(Vector3(3.5, 0.5, -4.5)), "the seam vertex does not move to the cell centre")
	)


func _edge_seam_span() -> void:
	step("Given the selected red, yellow, blue, and green corner", func():
		_view = VIEW.new(self)
		_view.apply(_edge_seam_cells())
	)
	await _view.settle()
	step("Then the seam keeps the vertex outside the shared edge", func():
		_view.collect()
		expect(not _view.indices.is_empty(), "the seam draws triangles")
		expect(_view.has_vertex(Vector3(4.5, -14.0, -4.5)), "the seam keeps its diagonal midpoint")
		expect(not _view.has_vertex(Vector3(4.5, -13.5, -4.5)), "the seam vertex does not move onto the edge span")
	)


func _edge_seam_travel() -> void:
	step("Given the selected seam beyond the shared edge span", func():
		_view = VIEW.new(self)
		_view.apply(_edge_seam_travel_cells())
	)
	await _view.settle()
	step("Then the seam keeps its own vertex", func():
		_view.collect()
		expect(not _view.indices.is_empty(), "the seam draws triangles")
		expect(_view.has_vertex(Vector3(8.75, -13.75, -4.5)), "the seam keeps its diagonal midpoint")
		expect(not _view.has_vertex(Vector3(7.5, -13.75, -4.5)), "the seam vertex does not travel to the shared edge")
	)


func _four_material_face() -> void:
	step("Given four materials around one face corner", func():
		_view = VIEW.new(self)
		_view.apply(_four_material_face_cells())
	)
	await _view.settle()
	step("Then each face triangle carries the material behind it", func():
		_view.collect()
		var cells := _four_material_face_cells()
		var quadrants := {}
		var wrong := 0
		for index in range(0, _view.indices.size(), 3):
			var first: Vector3 = _view.positions[_view.indices[index]]
			var second: Vector3 = _view.positions[_view.indices[index + 1]]
			var third: Vector3 = _view.positions[_view.indices[index + 2]]
			if absf(first.x + 3.5) > 0.001 or absf(second.x + 3.5) > 0.001 or absf(third.x + 3.5) > 0.001:
				continue
			var centre := (first + second + third) / 3.0
			var cell := Vector3i(-3, roundi(centre.y), roundi(centre.z))
			quadrants[Vector2i(cell.y, cell.z)] = true
			if not cells.has(cell):
				wrong += 1
				continue
			var material: PackedFloat32Array = cells[cell]
			var expected := Color(material[0], material[1], material[2], material[3])
			if not _view.colors[_view.indices[index]].is_equal_approx(expected):
				wrong += 1
		expect(quadrants.size() == 4, "the face draws all four quadrants")
		expect(wrong == 0, "each face triangle carries the material behind it")
	)


func _viewport_style() -> void:
	step("Given one painted voxel and the block style", func():
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.frames_changed.emit()
		_renderer = editor_viewport().get_node("ViewportScene/VoxelRenderer")
	)
	await _settle()
	step("When the document switches to the low-poly style", func():
		_block_mesh = _renderer._chunk_instances[Vector3i.ZERO].mesh
		State.set_mesh_style(1, false)
	)
	await _settle()
	step("Then the chunk draws a marching-cubes surface", func():
		var mesh: Mesh = _renderer._chunk_instances[Vector3i.ZERO].mesh
		expect(mesh != null, "the low-poly chunk has a mesh")
		expect(mesh != _block_mesh, "the style change replaces the chunk mesh")
		if mesh != null:
			var arrays := mesh.surface_get_arrays(0)
			expect(arrays[Mesh.ARRAY_INDEX].size() == 24, "one voxel becomes an eight-triangle octahedron")
			expect(arrays[Mesh.ARRAY_COLOR] is PackedColorArray, "the low-poly mesh carries voxel colours")
	)
	step("When the style returns to blocks", func():
		State.set_mesh_style(0, false)
	)
	await _settle()
	step("Then the block surface returns from the cache", func():
		expect(_renderer._chunk_instances[Vector3i.ZERO].mesh == _block_mesh, "the style is part of the surface key")
	)


func _style_undo() -> void:
	step("Given the document settings modal and the block style", func():
		_bar = main.get_node("%MenuBar")
		_dialog = _bar.get_node("DocumentSettingsModal")
		_renderer = editor_viewport().get_node("ViewportScene/VoxelRenderer")
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.frames_changed.emit()
	)
	await _settle()
	step("When the user picks Low Poly and confirms", func():
		_bar.get_node("ModelSettingsBtn").pressed.emit()
		_dialog.get_node("Margin/Layout/StyleRow/Low").button_pressed = true
		_dialog.confirmed.emit()
		_dialog.hide()
	)
	await _settle()
	step("Then the document stores one undoable style change", func():
		expect(State.document.mesh_style == 1, "the document stores the low-poly style")
		expect(State.undo_redo.has_undo(), "the style change has an undo step")
	)
	step("When the user undoes the style change", func():
		State.undo_redo.undo()
	)
	await _settle()
	step("Then the blocks and the modal selection return", func():
		expect(State.document.mesh_style == 0, "undo restores the block style")
		_bar.get_node("ModelSettingsBtn").pressed.emit()
		expect(_dialog.get_node("Margin/Layout/StyleRow/Blocks").button_pressed, "the modal shows the block style")
		_dialog.hide()
	)


func _settle() -> void:
	while not _renderer.is_settled():
		await get_tree().process_frame
	for frame in 3:
		await get_tree().process_frame


func _straight_seam_cells() -> Dictionary:
	return {
		Vector3i(2, -2, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(3, -2, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(4, -2, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(5, -2, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(2, -1, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(3, -1, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(4, -1, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(5, -1, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(1, 0, -5): VoxelFrame.material(Color(0.0, 1.0, 0.0)),
		Vector3i(3, 0, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(4, 0, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(5, 0, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(4, 1, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(5, 1, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(5, 2, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(1, -2, -4): VoxelFrame.material(Color(0.0, 1.0, 0.0)),
		Vector3i(2, -2, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(3, -2, -4): VoxelFrame.material(Color(0.0, 1.0, 0.0)),
		Vector3i(4, -2, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(5, -2, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(1, -1, -4): VoxelFrame.material(Color(0.0, 1.0, 0.0)),
		Vector3i(2, -1, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(3, -1, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(4, -1, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(5, -1, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(1, 0, -4): VoxelFrame.material(Color(0.0, 1.0, 0.0)),
		Vector3i(2, 0, -4): VoxelFrame.material(Color(0.0, 1.0, 0.0)),
		Vector3i(3, 0, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(4, 0, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(5, 0, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(4, 1, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(5, 1, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(5, 2, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
	}


func _edge_seam_cells() -> Dictionary:
	return {
		Vector3i(6, -15, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(5, -14, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(6, -14, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -14, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(4, -13, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(5, -13, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(6, -13, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -13, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(4, -12, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(5, -12, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(6, -12, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -12, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(3, -11, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(4, -11, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(5, -11, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(6, -11, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -11, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(3, -10, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(4, -10, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(5, -10, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(6, -10, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -10, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(6, -15, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(5, -14, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(6, -14, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -14, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(3, -13, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(4, -13, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(5, -13, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(6, -13, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -13, -4): VoxelFrame.material(Color(0.0, 1.0, 0.0)),
		Vector3i(2, -12, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(3, -12, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(4, -12, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(5, -12, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(6, -12, -4): VoxelFrame.material(Color(0.0, 1.0, 0.0)),
		Vector3i(7, -12, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(2, -11, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(3, -11, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(4, -11, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(5, -11, -4): VoxelFrame.material(Color(0.0, 1.0, 0.0)),
		Vector3i(6, -11, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -11, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(2, -10, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(3, -10, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(4, -10, -4): VoxelFrame.material(Color(0.0, 1.0, 0.0)),
		Vector3i(5, -10, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(6, -10, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -10, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
	}


func _four_material_face_cells() -> Dictionary:
	return {
		Vector3i(-3, 0, 0): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(-3, 0, 1): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(-3, 1, 0): VoxelFrame.material(Color(1.0, 0.0, 1.0)),
		Vector3i(-3, 1, 1): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
	}


func _edge_seam_travel_cells() -> Dictionary:
	return {
		Vector3i(6, -15, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(5, -14, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(6, -14, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -14, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(8, -14, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(4, -13, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(5, -13, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(6, -13, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -13, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(8, -13, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(9, -13, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(4, -12, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(5, -12, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(6, -12, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -12, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(8, -12, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(9, -12, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(10, -12, -5): VoxelFrame.material(Color(1.0, 0.0, 0.0)),
		Vector3i(4, -11, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(5, -11, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(6, -11, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -11, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(8, -11, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(9, -11, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(10, -11, -5): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(6, -15, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(5, -14, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(6, -14, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -14, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(8, -14, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(4, -13, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(5, -13, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(6, -13, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -13, -4): VoxelFrame.material(Color(0.0, 1.0, 0.0)),
		Vector3i(8, -13, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(9, -13, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(4, -12, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(5, -12, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(6, -12, -4): VoxelFrame.material(Color(0.0, 1.0, 0.0)),
		Vector3i(7, -12, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(8, -12, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(9, -12, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(10, -12, -4): VoxelFrame.material(Color(0.0, 0.0, 1.0)),
		Vector3i(4, -11, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(5, -11, -4): VoxelFrame.material(Color(0.0, 1.0, 0.0)),
		Vector3i(6, -11, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(7, -11, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(8, -11, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(9, -11, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
		Vector3i(10, -11, -4): VoxelFrame.material(Color(1.0, 1.0, 0.0)),
	}


func _random_cells() -> Dictionary:
	_seed = 104729
	var cells := {}
	for z in range(-2, 3):
		for y in range(-2, 3):
			for x in range(-2, 3):
				_seed = (_seed * 1103515245 + 12345) & 0x7fffffff
				if _seed % 100 < 45:
					cells[Vector3i(x, y, z)] = VoxelFrame.material(Color.WHITE)
	if cells.is_empty():
		cells[Vector3i.ZERO] = VoxelFrame.material(Color.WHITE)
	return cells
