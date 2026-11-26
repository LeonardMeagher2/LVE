extends "res://tests/test.gd"


const VIEW := preload("res://tests/helpers/marching_view.gd")

var _view
var _renderer
var _block_mesh: Mesh


func _ready() -> void:
	timeout = 60.0
	test("a same-material diagonal pair joins with a filled gap", _diagonal_pair, "bridge_diagonal_pair")
	test("a same-material corner pair joins through the block", _corner_pair, "bridge_corner_pair")
	test("different materials join with a seam", _different_materials, "bridge_different_materials")
	test("a finish change alone keeps the pair joined", _material_values, "bridge_material_values")
	test("two face-adjacent materials keep their own colours", _face_materials, "bridge_face_materials")
	test("a third material does not block the gap", _third_material, "bridge_third_material")
	test("a concave corner stays open", _concave_corner, "bridge_concave_corner")
	test("a mixed-material concave corner stays open", _mixed_concave_corner, "bridge_mixed_concave")
	test("a gap across four chunks joins without a seam", _chunk_seam, "bridge_chunk_seam")
	test("the editor viewport draws the joined pair", _viewport, "bridge_viewport")


func _diagonal_pair() -> void:
	step("Given two same-material voxels that share an edge", func():
		_view = VIEW.new(self)
		_view.apply({
			Vector3i.ZERO: VoxelFrame.material(Color.WHITE),
			Vector3i(1, 1, 0): VoxelFrame.material(Color.WHITE),
		})
	)
	await _view.settle()
	step("Then the pair draws as one surface with a filled gap", func():
		_view.collect()
		expect(_view.closed(), "the joined pair has no boundary")
		expect(_view.components() == 1, "the pair is one surface")
		expect(_view.has_gap_face(), "the gap holds a filled face and not a pinch")
		expect(_view.duplicates() == 0, "no triangle is emitted twice")
	)


func _corner_pair() -> void:
	step("Given two same-material voxels that share a corner", func():
		_view = VIEW.new(self)
		_view.apply({
			Vector3i.ZERO: VoxelFrame.material(Color.WHITE),
			Vector3i(1, 1, 1): VoxelFrame.material(Color.WHITE),
		})
	)
	await _view.settle()
	step("Then the pair stays two shells", func():
		_view.collect()
		expect(_view.closed(), "the corner pair has no boundary")
		expect(_view.components() == 2, "a corner-only pair keeps its own shell")
		expect(_view.bounds().is_equal_approx(AABB(Vector3.ONE * -0.5, Vector3.ONE * 2.0)), "the pair fills the two-cell block")
		expect(not _view.has_vertex(Vector3.ONE * 0.5), "the shells do not pinch at one point")
	)


func _different_materials() -> void:
	step("Given two diagonal voxels of different materials", func():
		_view = VIEW.new(self)
		_view.apply({
			Vector3i.ZERO: VoxelFrame.material(Color.WHITE),
			Vector3i(1, 1, 0): VoxelFrame.material(Color.RED),
		})
	)
	await _view.settle()
	step("Then the surfaces join and keep the gap volume", func():
		_view.collect()
		expect(_view.closed(), "both blobs have no boundary")
		expect(_view.components() == 1, "different materials join through the gap")
		expect(_view.volume() > 0.4, "the join keeps the gap volume")
	)


func _material_values() -> void:
	step("Given two diagonal voxels with one colour and different roughness", func():
		_view = VIEW.new(self)
		_view.apply({
			Vector3i.ZERO: VoxelFrame.material(Color.WHITE, Color.BLACK, 0.0, 1.0),
			Vector3i(1, 1, 0): VoxelFrame.material(Color.WHITE, Color.BLACK, 0.0, 0.3),
		})
	)
	await _view.settle()
	step("Then the pair still joins", func():
		_view.collect()
		expect(_view.closed(), "both blobs have no boundary")
		expect(_view.components() == 1, "roughness alone does not break the join")
		expect(_view.volume() > 0.4, "the join keeps the gap volume")
	)


func _third_material() -> void:
	step("Given a white diagonal pair with a red voxel beside one gap", func():
		_view = VIEW.new(self)
		_view.apply({
			Vector3i.ZERO: VoxelFrame.material(Color.WHITE),
			Vector3i(1, 1, 0): VoxelFrame.material(Color.WHITE),
			Vector3i(2, 1, 0): VoxelFrame.material(Color.RED),
		})
	)
	await _view.settle()
	step("Then both gaps join and the red voxel keeps its own surface", func():
		_view.collect()
		expect(_view.closed(), "the pair has no boundary")
		expect(_view.components() == 1, "both gaps join the pair")
		var red := VoxelFrame.material_color(State.get_current_voxel_frame().get_material(Vector3i(2, 1, 0)))
		var red_triangles := 0
		for offset in range(0, _view.indices.size(), 3):
			if _matches(_view.colors[_view.indices[offset]], red):
				red_triangles += 1
		expect(red_triangles > 0, "the red voxel keeps its own surface")
	)


func _face_materials() -> void:
	step("Given two face-adjacent voxels of different materials", func():
		_view = VIEW.new(self)
		_view.apply({
			Vector3i.ZERO: VoxelFrame.material(Color.WHITE),
			Vector3i(1, 0, 0): VoxelFrame.material(Color.RED),
		})
	)
	await _view.settle()
	step("Then every vertex keeps one of the two material colours", func():
		_view.collect()
		expect(_view.closed(), "the pair has no boundary")
		var white := VoxelFrame.material_color(State.get_current_voxel_frame().get_material(Vector3i.ZERO))
		var red := VoxelFrame.material_color(State.get_current_voxel_frame().get_material(Vector3i(1, 0, 0)))
		var mixed := false
		for color in _view.colors:
			if not _matches(color, white) and not _matches(color, red):
				mixed = true
		expect(not mixed, "no patch blends the two materials")
	)


func _matches(color: Color, expected: Color) -> bool:
	return absf(color.r - expected.r) < 0.01 and absf(color.g - expected.g) < 0.01 and absf(color.b - expected.b) < 0.01 and absf(color.a - expected.a) < 0.01


func _concave_corner() -> void:
	step("Given three same-material voxels painted as an L", func():
		_view = VIEW.new(self)
		_view.apply({
			Vector3i.ZERO: VoxelFrame.material(Color.WHITE),
			Vector3i(1, 0, 0): VoxelFrame.material(Color.WHITE),
			Vector3i(0, 1, 0): VoxelFrame.material(Color.WHITE),
		})
	)
	await _view.settle()
	step("Then the notch stays open", func():
		_view.collect()
		expect(_view.closed(), "the L surface has no boundary")
		expect(not _view.fills_notch(), "the concave notch is not filled")
	)


func _mixed_concave_corner() -> void:
	step("Given an L whose arms have different materials", func():
		_view = VIEW.new(self)
		_view.apply({
			Vector3i.ZERO: VoxelFrame.material(Color.WHITE),
			Vector3i(1, 0, 0): VoxelFrame.material(Color.RED),
			Vector3i(0, 1, 0): VoxelFrame.material(Color.WHITE),
		})
	)
	await _view.settle()
	step("Then the notch stays open", func():
		_view.collect()
		expect(_view.closed(), "the mixed L surface has no boundary")
		expect(not _view.fills_notch(), "different materials do not fill the notch")
	)


func _chunk_seam() -> void:
	step("Given a diagonal pair painted across four chunks", func():
		_view = VIEW.new(self)
		_view.apply({
			Vector3i(15, 15, 0): VoxelFrame.material(Color.WHITE),
			Vector3i(16, 16, 0): VoxelFrame.material(Color.WHITE),
		})
	)
	await _view.settle()
	step("Then the pair joins without a seam or a duplicate", func():
		_view.collect()
		expect(_view.closed(), "the seam has no boundary")
		expect(_view.components() == 1, "the seam keeps one surface")
		expect(_view.duplicates() == 0, "no triangle is emitted twice")
	)


func _viewport() -> void:
	step("Given two diagonal voxels in the block style", func():
		State.get_current_voxel_frame().set_cells({
			Vector3i.ZERO: VoxelFrame.material(Color.RED),
			Vector3i(1, 1, 0): VoxelFrame.material(Color.RED),
		})
		State.set_mesh_style(0, false)
		_renderer = editor_viewport().get_node("ViewportScene/VoxelRenderer")
		State.frames_changed.emit()
		sync_viewport()
	)
	await _settle()
	step("When the document switches to the low-poly style", func():
		_block_mesh = _renderer._chunk_instances[Vector3i.ZERO].mesh
		State.set_mesh_style(1, false)
	)
	await _settle()
	step("Then the chunk draws the joined pair", func():
		var mesh: Mesh = _renderer._chunk_instances[Vector3i.ZERO].mesh
		expect(mesh != null, "the bridged chunk has a mesh")
		expect(mesh != _block_mesh, "the style change replaces the chunk mesh")
		if mesh != null:
			var arrays := mesh.surface_get_arrays(0)
			expect(arrays[Mesh.ARRAY_INDEX].size() > 0, "the joined pair draws triangles")
	)


func _settle() -> void:
	while not _renderer.is_settled():
		await get_tree().process_frame
	for frame in 3:
		await get_tree().process_frame
