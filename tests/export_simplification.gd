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
					cells[Vector3i(x, y, z)] = Color.RED
		source_document.frames[0].set_cells(cells)
		var striped := source_document.add_frame(0)
		var blue_cells := {}
		for z in 64:
			for y in 64:
				for x in 32:
					blue_cells[Vector3i(x, y, z)] = Color.BLUE
		striped.set_cells(blue_cells)
		var hollow := source_document.add_frame(0)
		hollow.set_cell(CAVITY, Color.TRANSPARENT)
		var sparse := source_document.add_frame()
		sparse.set_cell(Vector3i(-4096, 4096, -4096), Color.RED)
		sparse.set_cell(Vector3i(4096, -4096, 4096), Color.BLUE)
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
		imported_scene = document.generate_scene(state, 30, false, false)
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
		print("Final solid cube: 96 chunk quads become 6 export quads")
	)
	step("Then color boundaries remain exact", func():
		if imported_scene == null:
			return
		var mesh := _mesh(1)
		expect(_index_count(mesh) == 60, "the two-color cube has ten exact colored faces")
		var colors_preserved := true
		var raw_mesh := raw_meshes[1]
		for surface_index in raw_mesh.get_surface_count():
			var arrays := raw_mesh.get_surface_arrays(surface_index)
			var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
			for vertex_index in positions.size():
				if colors[vertex_index] == Color.RED:
					colors_preserved = colors_preserved and positions[vertex_index].x <= -0.5
				elif colors[vertex_index] == Color.BLUE:
					colors_preserved = colors_preserved and positions[vertex_index].x >= -0.5
				else:
					colors_preserved = false
		expect(colors_preserved, "each face keeps its source color and partition boundary")
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
