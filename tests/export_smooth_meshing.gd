extends "res://tests/test.gd"

const EXPORT := preload("res://plugins/Export/GLTFExport.gd")
const ROUND_TRIP := "user://smooth_chunk_seams.glb"
var frame: VoxelFrame
var job: RefCounted
var reference: Array
var flat_arrays: Array
var imported_arrays: Array
var export_error := OK


func _ready() -> void:
	timeout = 30.0
	test("flat and smooth export meshes share topology and retain boundary corner normals", _run)


func _run() -> void:
	step("Given a uniform-material cube across eight chunks", func():
		frame = VoxelFrame.new()
		var cells := {}
		for z in 8:
			for y in 8:
				for x in 8:
					cells[Vector3i(x + 14, y + 14, z + 14)] = VoxelFrame.material(Color.RED)
		frame.set_cells(cells)
		_build_reference()
	)
	step("When the exporter builds flat and smooth meshes", func():
		_build_exports()
	)
	step("Then both meshes contain only twelve triangles", func():
		var arrays: Array = job.frame_surfaces[0]
		var old_triangles: int = reference[Mesh.ARRAY_INDEX].size() / 3
		var triangles: int = arrays[Mesh.ARRAY_INDEX].size() / 3
		expect(old_triangles == 768, "the source has two triangles per exposed voxel face")
		expect(triangles == 12, "the smooth cube dissolves each planar side into two triangles")
		print("Smooth cube: %d source triangles become %d export triangles" % [old_triangles, triangles])
		_expect_topology_and_area(arrays, 384.0)
		_expect_normals(arrays)
	)
	await _round_trip()
	step("Then the imported GLB also welds away every chunk boundary", func():
		expect(export_error == OK, "the cross-chunk smooth GLB exports successfully")
		if imported_arrays.is_empty():
			expect(false, "the cross-chunk GLB retains its raw geometry")
			return
		expect(imported_arrays[Mesh.ARRAY_INDEX].size() == 36, "the imported smooth cube contains twelve triangles")
		expect(imported_arrays[Mesh.ARRAY_VERTEX].size() == 8, "the imported smooth cube shares eight corners across all chunks")
		# The ArrayMesh/glTF round trip quantizes normals.
		_expect_normals(imported_arrays, 0.001)
	)
	step("Then moving the cube inside one chunk leaves the export geometry unchanged", func():
		var shifted := VoxelFrame.new()
		for z in 8:
			for y in 8:
				for x in 8:
					shifted.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.RED))
		var shifted_job := EXPORT.ExportJob.new()
		shifted_job.frames.append(shifted)
		shifted_job.smooth_normals = true
		shifted_job.center_origin = false
		shifted_job.run()
		var normalized: Array = job.frame_surfaces[0].duplicate()
		var positions: PackedVector3Array = normalized[Mesh.ARRAY_VERTEX]
		for index in positions.size():
			positions[index] -= Vector3.ONE * 14
		normalized[Mesh.ARRAY_VERTEX] = positions
		expect(_triangles(normalized) == _triangles(shifted_job.frame_surfaces[0]), "chunk alignment does not add edges or change triangle positions")
	)
	step("When the cube contains a notch and an internal cavity", func():
		frame.set_cell(Vector3i(14, 17, 17), VoxelFrame.material(Color.TRANSPARENT))
		frame.set_cell(Vector3i(17, 17, 17), VoxelFrame.material(Color.TRANSPARENT))
		_build_reference()
		_build_exports()
	)
	step("Then the irregular meshes keep their areas, topology, and surviving corner normals", func():
		var arrays: Array = job.frame_surfaces[0]
		expect(arrays[Mesh.ARRAY_INDEX].size() < reference[Mesh.ARRAY_INDEX].size(), "the irregular mesh also merges repeated faces")
		_expect_topology_and_area(arrays, 394.0)
		_expect_normals(arrays)
	)
	job = null
	if FileAccess.file_exists(ROUND_TRIP):
		DirAccess.remove_absolute(ROUND_TRIP)


func _round_trip() -> void:
	State.document = VoxelDocument.new()
	State.document.frames[0] = frame.copy_frame()
	State.document.smooth_normals = true
	export_error = await plugin("ExportPlugin")._gltf.export_gltf(ROUND_TRIP, false)
	if export_error != OK:
		return
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(ROUND_TRIP, state) == OK and not state.get_meshes().is_empty():
		imported_arrays = state.get_meshes()[0].mesh.get_surface_arrays(0)


func _build_exports() -> void:
	job = EXPORT.ExportJob.new()
	job.frames.append(frame)
	job.center_origin = false
	job.run()
	flat_arrays = job.frame_surfaces[0]
	job = EXPORT.ExportJob.new()
	job.frames.append(frame)
	job.smooth_normals = true
	job.center_origin = false
	job.run()


func _build_reference() -> void:
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for location: Vector3i in frame.chunks:
		var builder := VoxelMeshBuilder.new()
		builder.source_frame = frame
		builder.chunk_location = location
		builder.smooth_normals = true
		builder.texture_materials = false
		builder.run()
		var first_vertex := positions.size()
		for position: Vector3 in builder.surface_arrays[Mesh.ARRAY_VERTEX]:
			positions.append(position + Vector3(location * VoxelFrame.CHUNK_SIZE))
		normals.append_array(builder.surface_arrays[Mesh.ARRAY_NORMAL])
		for index: int in builder.surface_arrays[Mesh.ARRAY_INDEX]:
			indices.append(first_vertex + index)
	reference.resize(Mesh.ARRAY_MAX)
	reference[Mesh.ARRAY_VERTEX] = positions
	reference[Mesh.ARRAY_NORMAL] = normals
	reference[Mesh.ARRAY_INDEX] = indices


func _expect_normals(arrays: Array, normal_tolerance := 0.0001) -> void:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var source_positions: PackedVector3Array = reference[Mesh.ARRAY_VERTEX]
	var source_normals: PackedVector3Array = reference[Mesh.ARRAY_NORMAL]
	var matches := true
	var unit_normals := normals.size() == positions.size()
	var non_axis := false
	for index in normals.size():
		unit_normals = unit_normals and absf(normals[index].length() - 1.0) < 0.0001
		non_axis = non_axis or absf(normals[index].x) + absf(normals[index].y) + absf(normals[index].z) > 1.001
		var found := false
		for source_index in source_positions.size():
			if positions[index].distance_to(source_positions[source_index]) < 0.0001 and normals[index].distance_to(source_normals[source_index]) < normal_tolerance:
				found = true
				break
		matches = matches and found
	expect(unit_normals, "every retained vertex has a unit normal")
	expect(non_axis, "smooth shading retains non-axis corner normals")
	expect(matches, "every retained corner keeps a source normal at the same position")


func _expect_topology_and_area(arrays: Array, expected_area: float) -> void:
	expect(_triangles(arrays) == _triangles(flat_arrays), "flat and smooth shading use identical position triangles")
	expect(absf(_area(reference) - expected_area) < 0.0001, "the source has the expected exposed area")
	expect(absf(_area(arrays) - expected_area) < 0.0001, "the smooth mesh keeps every exposed face area")
	expect(absf(_area(flat_arrays) - expected_area) < 0.0001, "the flat mesh keeps every exposed face area")


func _triangles(arrays: Array) -> Array[String]:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var triangles: Array[String] = []
	for offset in range(0, indices.size(), 3):
		var corners: Array[String] = []
		for corner in 3:
			corners.append(str(positions[indices[offset + corner]]))
		corners.sort()
		triangles.append(str(corners))
	triangles.sort()
	return triangles


func _area(arrays: Array) -> float:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var area := 0.0
	for offset in range(0, indices.size(), 3):
		var a := positions[indices[offset]]
		var b := positions[indices[offset + 1]]
		var c := positions[indices[offset + 2]]
		area += (b - a).cross(c - a).length() * 0.5
	return area
