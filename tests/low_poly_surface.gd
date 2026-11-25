extends "res://tests/test.gd"


const TEST_PATH := "user://low_poly_surface_test.lve"
const MODEL_PATH := "user://low_poly_surface_test.glb"

var renderer: VoxelRenderer
var loaded: VoxelDocument
var voxel_mesh: Mesh
var low_poly_mesh: Mesh
var exporter: Node
var export_error := OK


func _ready() -> void:
	timeout = 30.0
	test("the low poly surface replaces the chunk meshes", _run)


func _run() -> void:
	step("Given a document in voxel mode", func():
		State.document = VoxelDocument.new()
		State.document.low_poly = false
		State.document.smooth_normals = false
		var cells := {}
		var material := VoxelFrame.material(Color(1.0, 0.0, 1.0))
		for x in range(-1, 2):
			for y in range(-1, 2):
				for z in range(-1, 2):
					cells[Vector3i(x, y, z)] = material
		State.get_current_voxel_frame().set_cells(cells)
		State.frames_changed.emit()
		renderer = editor_viewport().get_node("ViewportScene/VoxelRenderer")
	)
	await _settle()
	step("Then the chunk mesh is visible", func():
		expect(renderer._chunk_instances.has(Vector3i.ZERO), "the voxel mode builds a chunk mesh")
		voxel_mesh = renderer._chunk_instances[Vector3i.ZERO].mesh
		expect(voxel_mesh != null, "the voxel chunk has a mesh")
	)
	step("When the document enables low poly", func():
		State.document.low_poly = true
		State.model_settings_changed.emit()
	)
	await _settle()
	step("Then the chunk uses the low poly mesh", func():
		expect(renderer._chunk_instances.has(Vector3i.ZERO), "the low poly mode keeps one chunk instance")
		low_poly_mesh = renderer._chunk_instances[Vector3i.ZERO].mesh
		expect(low_poly_mesh != null and low_poly_mesh != voxel_mesh, "the chunk mesh is rebuilt for low poly")
		var material := renderer._chunk_instances[Vector3i.ZERO].material_override as StandardMaterial3D
		expect(material != null and material.vertex_color_use_as_albedo, "the low poly chunk uses the vertex colour material")
	)
	step("When the document enables smooth normals", func():
		State.document.smooth_normals = true
		State.model_settings_changed.emit()
	)
	await _settle()
	step("Then the low poly surface uses smooth normals", func():
		var mesh: Mesh = renderer._chunk_instances[Vector3i.ZERO].mesh
		expect(_has_smooth_normals(mesh), "the low poly mesh follows the smooth normals setting")
	)
	step("When the document returns to flat normals", func():
		State.document.smooth_normals = false
		State.model_settings_changed.emit()
	)
	await _settle()
	await _settle()
	exporter = plugin("ExportPlugin")
	export_error = await exporter.export_gltf(MODEL_PATH)
	step("Then the glTF keeps the low poly mesh", func():
		expect(export_error == OK, "the low poly model exports successfully")
		var gltf := GLTFDocument.new()
		var state := GLTFState.new()
		expect(gltf.append_from_file(MODEL_PATH, state) == OK, "the low poly glTF file imports")
		var meshes := state.get_meshes()
		expect(meshes.size() == 1, "the export contains the low poly frame")
		if not meshes.is_empty():
			var mesh: Mesh = meshes[0].mesh.get_mesh()
			var triangles := 0
			var colors := 0
			for surface in mesh.get_surface_count():
				triangles += mesh.surface_get_arrays(surface)[Mesh.ARRAY_INDEX].size() / 3
				colors += mesh.surface_get_arrays(surface)[Mesh.ARRAY_COLOR].size()
			expect(triangles > 0, "the exported low poly mesh has triangles")
			expect(colors == triangles * 3, "the exported low poly mesh keeps one colour per vertex")
			var arrays := mesh.surface_get_arrays(0)
			var welded := PackedInt32Array()
			var lookup := {}
			for position: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
				var key := Vector3i((position * 10000.0).round())
				if not lookup.has(key):
					lookup[key] = lookup.size()
				welded.append(lookup[key])
			var edges := {}
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for index in range(0, indices.size(), 3):
				var a := welded[indices[index]]
				var b := welded[indices[index + 1]]
				var c := welded[indices[index + 2]]
				for edge in [[a, b], [b, c], [c, a]]:
					var key := mini(int(edge[0]), int(edge[1])) * 1000000 + maxi(int(edge[0]), int(edge[1]))
					edges[key] = edges.get(key, 0) + 1
			var boundary := 0
			for key in edges:
				if edges[key] == 1:
					boundary += 1
			expect(boundary == 0, "the low poly chunks share their borders")
			var chunk_triangles := 0
			for chunk: MeshInstance3D in renderer._chunk_instances.values():
				if chunk.mesh == null:
					continue
				for surface in chunk.mesh.get_surface_count():
					chunk_triangles += chunk.mesh.surface_get_arrays(surface)[Mesh.ARRAY_INDEX].size() / 3
			expect(triangles == chunk_triangles, "the export matches the low poly preview")
	)
	step("When the document saves with low poly enabled", func():
		State.document.save_file(TEST_PATH)
		loaded = VoxelDocument.load_file(TEST_PATH)
	)
	step("Then the low poly setting returns", func():
		expect(loaded != null and loaded.low_poly, "the low poly mode survives save and load")
	)
	step("When the document returns to voxel mode", func():
		State.document.low_poly = false
		State.model_settings_changed.emit()
	)
	await _settle()
	step("Then the voxel chunk mesh returns", func():
		var mesh: Mesh = renderer._chunk_instances[Vector3i.ZERO].mesh
		expect(mesh != null and mesh != low_poly_mesh, "the voxel mesh replaces the low poly mesh")
	)
	for path in [TEST_PATH, MODEL_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _settle() -> void:
	while not renderer.is_settled():
		await get_tree().process_frame


func _has_smooth_normals(mesh: Mesh) -> bool:
	for surface in mesh.get_surface_count():
		for normal: Vector3 in mesh.surface_get_arrays(surface)[Mesh.ARRAY_NORMAL]:
			var largest_component := maxf(absf(normal.x), maxf(absf(normal.y), absf(normal.z)))
			if largest_component < 0.99 and normal.length() > 0.99:
				return true
	return false
