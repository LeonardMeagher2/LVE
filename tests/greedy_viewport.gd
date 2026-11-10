extends "res://tests/test.gd"

const EXPORT := preload("res://plugins/Export/GLTFExport.gd")
var renderer: VoxelRenderer
var job: RefCounted
var preview: MeshInstance3D


func _ready() -> void:
	timeout = 30.0
	test("viewport and export share planar meshing with flat and smooth normals", _run)


func _run() -> void:
	step("Given a full chunk with one material that uses every channel", func():
		State.document = VoxelDocument.new()
		var cells := {}
		for z in 16:
			for y in 16:
				for x in 16:
					cells[Vector3i(x, y, z)] = VoxelFrame.material(Color.RED, Color(0, 0.5, 0), 0.25, 0.75)
		State.get_current_voxel_frame().set_cells(cells)
		renderer = load("res://ui/Viewport/VoxelRenderer.tscn").instantiate()
		main.add_child(renderer)
	)
	await _settle()
	step("Then flat viewport and export meshes both use twelve triangles and twenty-four vertices", func():
		_build_export()
		_expect_same_mesh(12, 24)
		var material: StandardMaterial3D = renderer._chunk_instances[Vector3i.ZERO].material_override
		expect(material.albedo_texture != null and material.metallic_texture != null and material.emission_texture != null, "the viewport keeps every material channel in textures")
		expect(material.vertex_color_use_as_albedo and not material.vertex_color_is_srgb, "the viewport multiplies the baked ambient occlusion")
	)
	step("When the user enables smooth normals", func():
		State.document.smooth_normals = true
		State.model_settings_changed.emit()
	)
	await _settle()
	step("Then both smooth meshes use twelve triangles and eight welded vertices", func():
		_build_export()
		_expect_same_mesh(12, 8)
	)
	step("Given a material preview with a fully enclosed central chunk", func():
		var cells := {}
		for z in range(-1, 17):
			for y in range(-1, 17):
				for x in range(-1, 17):
					cells[Vector3i(x, y, z)] = VoxelFrame.material(Color.BLUE)
		preview = MeshInstance3D.new()
		preview.set_script(load("res://Globals/Rendering/VoxelPreview.gd"))
		main.add_child(preview)
		preview.show_voxels(cells, Color.WHITE)
	)
	while not preview.is_settled():
		await get_tree().process_frame
	step("Then the preview skips the empty interior mesh and keeps its shell", func():
		expect(preview.mesh != null and preview.mesh.get_surface_count() == 26, "the preview retains all twenty-six visible chunk surfaces")
		expect(preview.mesh.get_aabb().is_equal_approx(AABB(Vector3.ONE * -1.5, Vector3.ONE * 18)), "the preview keeps its complete bounds")
	)
	preview.free()
	renderer.free()
	job = null


func _settle() -> void:
	while not renderer.is_settled():
		await get_tree().process_frame


func _build_export() -> void:
	job = EXPORT.ExportJob.new()
	job.frames.append(State.get_current_voxel_frame())
	job.smooth_normals = State.document.smooth_normals
	job.center_origin = false
	job.run()


func _expect_same_mesh(triangles: int, vertices: int) -> void:
	var mesh: ArrayMesh = renderer._chunk_instances[Vector3i.ZERO].mesh
	var arrays := mesh.surface_get_arrays(0)
	var exported: Array = job.frame_surfaces[0]
	expect(arrays[Mesh.ARRAY_INDEX].size() == triangles * 3, "the viewport uses %d triangles" % triangles)
	expect(exported[Mesh.ARRAY_INDEX].size() == triangles * 3, "the exporter uses the same triangle count")
	expect(arrays[Mesh.ARRAY_VERTEX].size() == vertices, "the viewport uses %d welded vertices" % vertices)
	expect(exported[Mesh.ARRAY_VERTEX].size() == vertices, "the exporter uses the same welded vertex count")
	var matches: bool = arrays[Mesh.ARRAY_VERTEX].size() == exported[Mesh.ARRAY_VERTEX].size()
	if matches:
		for index in arrays[Mesh.ARRAY_VERTEX].size():
			matches = matches and arrays[Mesh.ARRAY_VERTEX][index].distance_to(exported[Mesh.ARRAY_VERTEX][index]) < 0.001
			matches = matches and arrays[Mesh.ARRAY_NORMAL][index].distance_to(exported[Mesh.ARRAY_NORMAL][index]) < 0.001
	expect(matches, "the viewport and exporter use the same vertex positions and normals")
