extends "res://tests/test.gd"

var renderer: VoxelRenderer
var first_mesh: Mesh
var quads := 0


func _ready() -> void:
	timeout = 30.0
	test("surface rendering merges faces, closes chunk seams, and reuses cached frame meshes", _run)


func _run() -> void:
	step("Given a solid red chunk and the surface renderer", func():
		State.document = VoxelDocument.new()
		for z in 16:
			for y in 16:
				for x in 16:
					State.paint(Vector3i(x, y, z), VoxelFrame.material(Color.RED))
		renderer = load("res://ui/Viewport/VoxelRenderer.tscn").instantiate()
		main.add_child(renderer)
	)
	await _settle()
	step("Then the solid chunk has six outward faces", func():
		quads = _quad_count()
		expect(quads == 6, "the solid chunk renders six merged quads")
		first_mesh = _mesh_at(Vector3.ZERO)
		expect(first_mesh != null, "the solid chunk has a mesh")
		if first_mesh:
			var arrays := first_mesh.surface_get_arrays(0)
			var unit_normals := true
			for normal in arrays[Mesh.ARRAY_NORMAL]:
				unit_normals = unit_normals and normal.length() == 1.0
			expect(unit_normals, "the faces have unit normals")
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var clockwise := true
			for i in range(0, indices.size(), 3):
				var a := vertices[indices[i]]
				var b := vertices[indices[i + 1]]
				var c := vertices[indices[i + 2]]
				clockwise = clockwise and (b - a).cross(c - a).dot(arrays[Mesh.ARRAY_NORMAL][indices[i]]) < 0
			expect(clockwise, "the exterior faces have clockwise winding")
	)
	step("When the user adds an adjacent solid chunk", func():
		State.begin_stroke()
		for z in 16:
			for y in 16:
				for x in range(16, 32):
					State.paint(Vector3i(x, y, z), VoxelFrame.material(Color.RED))
		State.end_stroke()
		var affected: Array[Vector3i] = []
		State.cells_changed.emit(0, affected)
	)
	await _settle()
	step("Then the two chunks have no internal seam faces", func():
		expect(_quad_count() == 10, "the two chunks render ten exterior quads")
	)
	step("When the user undoes the added chunk", func():
		State.undo_redo.undo()
	)
	await _settle()
	step("Then the original mesh is reused", func():
		expect(_quad_count() == 6, "undo restores six exterior quads")
		expect(_mesh_at(Vector3.ZERO) == first_mesh, "undo reuses the cached original mesh")
	)
	step("When the user switches away and back while a mesh job is pending", func():
		State.add_frame()
		State.paint(Vector3i(-1, 0, 0), VoxelFrame.material(Color.BLUE))
		var affected: Array[Vector3i] = [Vector3i(-1, 0, 0)]
		State.cells_changed.emit(1, affected)
		State.current_frame = 0
	)
	await _settle()
	step("Then the current frame has the original cached geometry", func():
		expect(_mesh_at(Vector3.ZERO) == first_mesh, "frame switching reuses the cached mesh")
		expect(_quad_count() == 6, "a stale job leaves the current frame unchanged")
	)
	step("When the user switches to the negative-coordinate blue voxel", func():
		State.current_frame = 1
	)
	await _settle()
	step("Then the voxel renders with its original color and location", func():
		var surface := _mesh_at(Vector3(-16, 0, 0))
		expect(surface != null, "the negative chunk has a visible mesh")
		if surface:
			var material: StandardMaterial3D = renderer._chunk_instances[Vector3i(-1, 0, 0)].material_override
			var image := material.albedo_texture.get_image()
			expect(image.get_pixel(1, 1) == Color.BLUE, "the voxel's atlas is blue")
			expect(surface.get_aabb().position == Vector3(14.5, -0.5, -0.5), "the voxel retains its chunk-local position")
	)


func _settle() -> void:
	while not renderer.is_settled():
		await get_tree().process_frame


func _mesh_at(position: Vector3) -> Mesh:
	for child in renderer.get_children():
		if child is MeshInstance3D and child.visible and child.position == position:
			return child.mesh
	return null


func _quad_count() -> int:
	var total := 0
	for child in renderer.get_children():
		if child is MeshInstance3D and child.visible:
			total += child.mesh.surface_get_array_index_len(0) / 6
	return total
