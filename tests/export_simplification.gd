extends "res://tests/test.gd"

const OUTPUT := "user://voxel_simplification_test.glb"
const CAVITY := Vector3i(0, 32, 32)
var imported_scene: Node
var source_document: VoxelDocument
var raw_meshes: Array[ImporterMesh] = []
var export_error := OK


func _ready() -> void:
	timeout = 60.0
	test("final voxel meshes merge chunk seams without changing colors, cavities, or sparse shapes", _run)


func _run() -> void:
	step("Given a solid cube, a two-color cube, a cube with a cavity, and distant voxels", func():
		State.document = VoxelDocument.new()
		source_document = State.document
		var cells := {}
		for z in 64:
			for y in 64:
				for x in range(-32, 32):
					cells[Vector3i(x, y, z)] = VoxelFrame.material(Color.RED)
		source_document.frames[0].set_cells(cells)
		var striped := source_document.add_frame(0)
		var blue_cells := {}
		for z in 64:
			for y in 64:
				for x in 32:
					blue_cells[Vector3i(x, y, z)] = VoxelFrame.material(Color.BLUE)
		striped.set_cells(blue_cells)
		var hollow := source_document.add_frame(0)
		hollow.set_cell(CAVITY, VoxelFrame.material(Color.TRANSPARENT))
		var sparse := source_document.add_frame()
		sparse.set_cell(Vector3i(-4096, 4096, -4096), VoxelFrame.material(Color.RED))
		sparse.set_cell(Vector3i(4096, -4096, 4096), VoxelFrame.material(Color.BLUE))
	)
	var started := Time.get_ticks_msec()
	var exporter := plugin("ExportPlugin")
	export_error = await exporter.export_gltf(OUTPUT)
	step("When the final asset is imported", func():
		expect(export_error == OK, "the simplified asset exports successfully")
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		var error := document.append_from_file(OUTPUT, state)
		expect(error == OK, "the simplified asset imports successfully")
		if error != OK:
			return
		for gltf_mesh in state.get_meshes():
			raw_meshes.append(gltf_mesh.mesh)
			var raw_mesh: ImporterMesh = gltf_mesh.mesh
			expect(raw_mesh.get_surface_count() == 1, "each nonempty frame has one textured surface")
			for surface_index in raw_mesh.get_surface_count():
				var arrays := raw_mesh.get_surface_arrays(surface_index)
				expect(arrays[Mesh.ARRAY_COLOR] == null, "the raw frame has no vertex colors")
				expect(arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array, "the raw frame has atlas UVs")
		imported_scene = document.generate_scene(state, 30, false, false)
		expect(imported_scene != null, "the asset creates a scene")
		if imported_scene == null:
			return
		main.add_child(imported_scene)
	)
	step("Then the solid cube uses six exact faces with sharp normals", func():
		if imported_scene == null:
			return
		var mesh := _mesh(0)
		expect(_index_count(mesh) == 36, "the solid cube contains only twelve triangles")
		expect(_vertex_count(mesh) == 24, "the solid cube keeps twenty-four sharp-edge vertices")
		expect(mesh.get_aabb().size.is_equal_approx(Vector3.ONE * 64), "the solid cube keeps its exact dimensions")
		expect(absf(_area(mesh) - 6.0 * 64 * 64) < 0.01, "the solid cube keeps its exact surface area")
		expect(_sharp_normals(mesh), "the face normals stay aligned with the outward voxel faces")
		print("Final solid cube: 96 chunk quads become 12 export triangles")
	)
	step("Then color boundaries remain exact", func():
		if imported_scene == null:
			return
		var mesh := _mesh(1)
		expect(_index_count(mesh) == 60, "the two-color cube keeps twenty triangles along material seams")
		expect(_vertex_count(mesh) == 40, "the two-color cube retains forty sharp-edge and material-seam vertices")
		expect(raw_meshes.size() == 4, "all frames retain their raw import meshes")
		if raw_meshes.size() != 4:
			return
		_check_voxel_colors(raw_meshes[1], mesh.get_aabb())
	)
	step("Then the cavity and distant voxels keep all their exposed faces", func():
		if imported_scene == null:
			return
		var hollow := _mesh(2)
		expect(_index_count(hollow) == 72, "the hollow cube keeps six outer and six inner faces")
		expect(absf(_area(hollow) - (6.0 * 64 * 64 + 6)) < 0.01, "the hollow cube retains the cavity surface area")
		expect(_cavity_area(raw_meshes[2]) == 6.0, "all cavity walls remain at the original voxel position")
		expect(_index_count(_mesh(3)) == 72, "the distant voxels retain their twelve separate faces")
		expect(source_document.frames[0].count() == 262144, "simplification preserves the source solid cube")
		expect(source_document.frames[2].count() == 262143, "simplification preserves the source cavity")
		expect(not State.edit_busy(), "the completed export releases editing")
		print("Simplified four-frame export: %d ms" % (Time.get_ticks_msec() - started))
	)
	if imported_scene:
		imported_scene.free()
	if FileAccess.file_exists(OUTPUT):
		DirAccess.remove_absolute(OUTPUT)


func _check_voxel_colors(mesh: ImporterMesh, bounds: AABB) -> void:
	if mesh.get_surface_count() != 1:
		return
	var material := mesh.get_surface_material(0) as StandardMaterial3D
	expect(material != null and material.albedo_texture != null, "the two-color cube has an albedo atlas")
	if material == null or material.albedo_texture == null:
		return
	var image := material.albedo_texture.get_image()
	expect(image != null, "the two-color atlas is readable")
	if image == null:
		return
	var arrays := mesh.get_surface_arrays(0)
	var colors_preserved := true
	var sampled := 0
	var red_samples := 0
	var blue_samples := 0
	for axis in 3:
		for side in 2:
			for row in 64:
				for column in 64:
					var point := bounds.position
					point[axis] += bounds.size[axis] * side
					point[(axis + 1) % 3] += row + 0.5
					point[(axis + 2) % 3] += column + 0.5
					var uv: Variant = _uv_at(arrays, point)
					if not uv is Vector2:
						colors_preserved = false
						continue
					var pixel := Vector2i(floori(uv.x * image.get_width()), floori(uv.y * image.get_height()))
					if pixel.x < 0 or pixel.y < 0 or pixel.x >= image.get_width() or pixel.y >= image.get_height():
						colors_preserved = false
						continue
					var is_red := point.x < bounds.get_center().x
					var expected := Color.RED if is_red else Color.BLUE
					var actual := image.get_pixelv(pixel)
					colors_preserved = colors_preserved and absf(actual.r - expected.r) < 0.005 and absf(actual.g - expected.g) < 0.005 and absf(actual.b - expected.b) < 0.005 and absf(actual.a - 1.0) < 0.005
					sampled += 1
					if is_red:
						red_samples += 1
					else:
						blue_samples += 1
	expect(sampled == 6 * 64 * 64, "every exposed voxel face has interpolated UVs")
	expect(red_samples == 3 * 64 * 64 and blue_samples == 3 * 64 * 64, "the samples cover both color partitions equally")
	expect(colors_preserved, "every voxel face samples its source color across the merged quads")


func _uv_at(arrays: Array, point: Vector3) -> Variant:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if not arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
		return null
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	if uvs.size() != positions.size():
		return null
	for index in range(0, indices.size(), 3):
		var a := positions[indices[index]]
		var ab := positions[indices[index + 1]] - a
		var ac := positions[indices[index + 2]] - a
		var normal := ab.cross(ac)
		if normal.length_squared() < 0.000001 or absf(normal.normalized().dot(point - a)) > 0.001:
			continue
		var denominator := ab.dot(ab) * ac.dot(ac) - ab.dot(ac) * ab.dot(ac)
		var v := (ac.dot(ac) * (point - a).dot(ab) - ab.dot(ac) * (point - a).dot(ac)) / denominator
		var w := (ab.dot(ab) * (point - a).dot(ac) - ab.dot(ac) * (point - a).dot(ab)) / denominator
		if v >= -0.00001 and w >= -0.00001 and v + w <= 1.00001:
			return uvs[indices[index]] * (1.0 - v - w) + uvs[indices[index + 1]] * v + uvs[indices[index + 2]] * w
	return null


func _mesh(frame_index: int) -> Mesh:
	return imported_scene.find_child("Frame_%d" % frame_index, true, false).mesh


func _index_count(mesh: Mesh) -> int:
	var count := 0
	for surface_index in mesh.get_surface_count():
		count += mesh.surface_get_arrays(surface_index)[Mesh.ARRAY_INDEX].size()
	return count


func _vertex_count(mesh: Mesh) -> int:
	var count := 0
	for surface_index in mesh.get_surface_count():
		count += mesh.surface_get_arrays(surface_index)[Mesh.ARRAY_VERTEX].size()
	return count


func _area(mesh: Mesh) -> float:
	var area := 0.0
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for index in range(0, indices.size(), 3):
			var a := positions[indices[index]]
			var b := positions[indices[index + 1]]
			var c := positions[indices[index + 2]]
			area += (b - a).cross(c - a).length() * 0.5
	return area


func _sharp_normals(mesh: Mesh) -> bool:
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for normal in normals:
			if absf(absf(normal.x) + absf(normal.y) + absf(normal.z) - 1.0) > 0.001:
				return false
		for index in range(0, indices.size(), 3):
			var a := positions[indices[index]]
			var b := positions[indices[index + 1]]
			var c := positions[indices[index + 2]]
			if (b - a).cross(c - a).dot(normals[indices[index]]) >= 0.0:
				return false
	return true


func _cavity_area(mesh: ImporterMesh) -> float:
	var area := 0.0
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.get_surface_arrays(surface_index)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for index in range(0, indices.size(), 3):
			var points := [positions[indices[index]], positions[indices[index + 1]], positions[indices[index + 2]]]
			var on_cavity := true
			for point: Vector3 in points:
				var offset := (point - Vector3(CAVITY)).abs()
				on_cavity = on_cavity and offset.x <= 0.5 and offset.y <= 0.5 and offset.z <= 0.5
			if on_cavity:
				area += (points[1] - points[0]).cross(points[2] - points[0]).length() * 0.5
	return area
