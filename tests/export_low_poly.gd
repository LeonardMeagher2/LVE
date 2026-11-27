extends "res://tests/test.gd"


const EXPORT := preload("res://plugins/Export/GLTFExport.gd")
const FIXTURE := preload("res://tests/helpers/marching_fixture.gd")
const VIEW := preload("res://tests/helpers/marching_view.gd")
const ROUND_TRIP := "user://low_poly_export.glb"

var frame: VoxelFrame
var job: RefCounted
var reference_triangles := 0
var export_error := OK
var imported_arrays: Array
var _chunk_vertex_count := 0
var _chunk_triangle_count := 0
var _chunk_dissolved_count := 0
var _smooth_vertex_count := 0
var _smooth_triangle_count := 0


func _ready() -> void:
	timeout = 60.0
	test("the low-poly style exports its marching mesh with atlas UVs", _run)
	test("the smooth export welds the frame and dissolves it once", _smooth_export, "export_smooth_weld")


func _run() -> void:
	step("Given a floor and wall in the low-poly style", func():
		frame = VoxelFrame.new()
		var red := VoxelFrame.material(Color.RED)
		var blue := VoxelFrame.material(Color.BLUE)
		for z in 3:
			for x in 3:
				frame.set_cell(Vector3i(x, 0, z), red)
		for z in 3:
			for y in range(1, 4):
				frame.set_cell(Vector3i(0, y, z), blue)
		frame.set_cell(Vector3i(16, 0, 0), VoxelFrame.material(Color.GREEN))
		reference_triangles = _marching_triangles(frame)
	)
	step("When the exporter builds the low-poly frame", func():
		job = EXPORT.ExportJob.new()
		job.frames.append(frame)
		job.mesh_style = 1
		job.ao_strength = 1.0
		job.center_origin = false
		job.run()
	)
	step("Then the mesh keeps the marching triangles and the frame atlas", func():
		expect(job.error == OK, "the low-poly job completes")
		expect(job.frame_surfaces.size() == 1, "the job builds one frame")
		var arrays: Array = job.frame_surfaces[0]
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		expect(not positions.is_empty(), "the export mesh has vertices")
		expect(arrays[Mesh.ARRAY_INDEX].size() / 3 == reference_triangles, "the export keeps the marching triangle count")
		expect(uvs.size() == positions.size(), "each vertex carries an atlas UV")
		expect(job.frame_atlases.size() == 1 and job.frame_atlases[0].albedo != null, "the frame has a baked atlas")
		var atlas: RefCounted = job.frame_atlases[0]
		var image: Image = atlas.albedo
		var colors := {}
		for uv: Vector2 in uvs:
			var texel := image.get_pixelv(Vector2i(uv * Vector2(image.get_size())))
			colors[texel.to_html(false)] = true
		expect(colors.size() == 3, "the atlas holds the three frame materials")
		var bounds := _bounds(positions)
		expect(bounds.size.x > 16.0, "the export covers both chunks")
	)
	step("Then the frame keeps its ambient occlusion colors", func():
		var arrays: Array = job.frame_surfaces[0]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		expect(colors.size() == arrays[Mesh.ARRAY_VERTEX].size(), "each vertex carries an occlusion color")
		var darkest := 1.0
		for color: Color in colors:
			darkest = minf(darkest, color.r)
		expect(darkest < 0.99, "the concave corner darkens")
	)
	await _round_trip()
	step("Then the GLB keeps the low-poly UVs", func():
		expect(export_error == OK, "the low-poly GLB exports successfully")
		if imported_arrays.is_empty():
			expect(false, "the imported GLB keeps its geometry")
			return
		expect(imported_arrays[Mesh.ARRAY_TEX_UV].size() == imported_arrays[Mesh.ARRAY_VERTEX].size(), "the imported GLB keeps one UV per vertex")
		expect(imported_arrays[Mesh.ARRAY_INDEX].size() / 3 == reference_triangles, "the imported GLB keeps the triangle count")
	)
	if FileAccess.file_exists(ROUND_TRIP):
		DirAccess.remove_absolute(ROUND_TRIP)


func _marching_triangles(source: VoxelFrame) -> int:
	var triangles := 0
	for location: Vector3i in source.chunks:
		var builder := VoxelMarchingMeshBuilder.new()
		builder.source_frame = source
		builder.chunk_location = location
		builder.ao_strength = 1.0
		builder.skip_atlas = true
		builder.run()
		triangles += builder.surface_arrays[Mesh.ARRAY_INDEX].size() / 3
	return triangles


func _smooth_export() -> void:
	step("Given a smooth sphere of four materials across eight chunks", func():
		var material_frame := FIXTURE.sphere_frame(4, 4)
		_chunk_vertex_count = _chunk_vertices(material_frame)
		_chunk_triangle_count = _chunk_triangles(material_frame)
		_chunk_dissolved_count = _chunk_triangles(material_frame, true)
		frame = material_frame
		job = EXPORT.ExportJob.new()
		job.frames.append(frame)
		job.mesh_style = 1
		job.smooth_normals = true
		job.ao_strength = 1.0
		job.center_origin = false
		job.run()
		expect(_chunk_triangle_count > 0, "the smooth fixture builds a surface")
	)
	step("Then the frame welds across the chunk boundaries", func():
		expect(job.error == OK, "the smooth job completes")
		var arrays: Array = job.frame_surfaces[0]
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		_smooth_vertex_count = positions.size()
		_smooth_triangle_count = arrays[Mesh.ARRAY_INDEX].size() / 3
		print("MEASURE export_smooth_weld: chunk_vertices=%d chunk_triangles=%d chunk_dissolved=%d export_vertices=%d export_triangles=%d" % [
			_chunk_vertex_count, _chunk_triangle_count, _chunk_dissolved_count, _smooth_vertex_count, _smooth_triangle_count,
		])
		expect(_smooth_vertex_count < _chunk_vertex_count, "the weld removes the chunk boundary duplicates")
		expect(not uvs.is_empty() and uvs.size() == positions.size(), "each vertex keeps its atlas UV")
		expect(_duplicate_vertices(positions, uvs) == 0, "no two vertices share a position and a material")
	)
	step("Then one global dissolve removes triangles without a seam", func():
		expect(_smooth_triangle_count < _chunk_triangle_count, "the global dissolve removes triangles")
		expect(_smooth_triangle_count < _chunk_dissolved_count, "the global dissolve removes more than the chunk passes")
		var arrays: Array = job.frame_surfaces[0]
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var view = VIEW.new(self)
		view.positions = positions
		view.indices = indices
		expect(view.closed(), "the dissolved export has no boundary")
		expect(view.duplicates() == 0, "no triangle is emitted twice")
		expect(_manifold(positions, indices), "every export edge joins two triangles")
		expect(_distinct_uvs(arrays) == 4, "the export keeps the four materials")
		var unit := true
		for normal: Vector3 in normals:
			if absf(normal.length() - 1.0) > 0.001:
				unit = false
		expect(unit, "each export normal has unit length")
	)
	step("Then the flat export keeps one normal per facet", func():
		var flat_job = EXPORT.ExportJob.new()
		flat_job.frames.append(frame)
		flat_job.mesh_style = 1
		flat_job.ao_strength = 1.0
		flat_job.center_origin = false
		flat_job.run()
		expect(flat_job.error == OK, "the flat job completes")
		var arrays: Array = flat_job.frame_surfaces[0]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var separate := 0
		for triangle in indices.size() / 3:
			var first := normals[indices[triangle * 3]]
			if not first.is_equal_approx(normals[indices[triangle * 3 + 1]]) or not first.is_equal_approx(normals[indices[triangle * 3 + 2]]):
				separate += 1
		expect(separate == 0, "each flat triangle keeps one normal")
		expect(arrays[Mesh.ARRAY_VERTEX].size() > _smooth_vertex_count, "the flat export keeps its facet vertices")
	)


func _chunk_vertices(source: VoxelFrame) -> int:
	var vertices := 0
	for location: Vector3i in source.chunks:
		var builder := VoxelMarchingMeshBuilder.new()
		builder.source_frame = source
		builder.chunk_location = location
		builder.smooth_normals = true
		builder.ao_strength = 1.0
		builder.skip_atlas = true
		builder.dissolve_limited = false
		builder.run()
		vertices += builder.surface_arrays[Mesh.ARRAY_VERTEX].size()
	return vertices


func _chunk_triangles(source: VoxelFrame, dissolve := false) -> int:
	var triangles := 0
	for location: Vector3i in source.chunks:
		var builder := VoxelMarchingMeshBuilder.new()
		builder.source_frame = source
		builder.chunk_location = location
		builder.smooth_normals = true
		builder.ao_strength = 1.0
		builder.skip_atlas = true
		builder.dissolve_limited = dissolve
		builder.run()
		triangles += builder.surface_arrays[Mesh.ARRAY_INDEX].size() / 3
	return triangles


func _duplicate_vertices(positions: PackedVector3Array, uvs: PackedVector2Array) -> int:
	var seen := {}
	var duplicates := 0
	for index in positions.size():
		var key := Vector4i(
			roundi(positions[index].x * 1024.0),
			roundi(positions[index].y * 1024.0),
			roundi(positions[index].z * 1024.0),
			roundi(uvs[index].x * 4096.0) * 4096 + roundi(uvs[index].y * 4096.0)
		)
		if seen.has(key):
			duplicates += 1
		seen[key] = true
	return duplicates


func _manifold(positions: PackedVector3Array, indices: PackedInt32Array) -> bool:
	var canonical := PackedInt32Array()
	canonical.resize(positions.size())
	var lookup := {}
	for index in positions.size():
		var key := Vector3i(roundi(positions[index].x * 1024.0), roundi(positions[index].y * 1024.0), roundi(positions[index].z * 1024.0))
		if not lookup.has(key):
			lookup[key] = lookup.size()
		canonical[index] = lookup[key]
	var edges := {}
	for triangle in indices.size() / 3:
		for corner in 3:
			var first := canonical[indices[triangle * 3 + corner]]
			var second := canonical[indices[triangle * 3 + (corner + 1) % 3]]
			if first == second:
				return false
			var key := Vector2i(mini(first, second), maxi(first, second))
			edges[key] = edges.get(key, 0) + 1
	for key: Vector2i in edges:
		if edges[key] != 2:
			return false
	return true


func _distinct_uvs(arrays: Array) -> int:
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var seen := {}
	for uv: Vector2 in uvs:
		seen[Vector2i(roundi(uv.x * 4096.0), roundi(uv.y * 4096.0))] = true
	return seen.size()


func _bounds(positions: PackedVector3Array) -> AABB:
	var box := AABB(positions[0], Vector3.ZERO)
	for position: Vector3 in positions:
		box = box.expand(position)
	return box


func _round_trip() -> void:
	State.document = VoxelDocument.new()
	State.document.frames[0] = frame.copy_frame()
	State.document.mesh_style = 1
	export_error = await plugin("ExportPlugin")._gltf.export_gltf(ROUND_TRIP, false)
	if export_error != OK:
		return
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(ROUND_TRIP, state) == OK and not state.get_meshes().is_empty():
		imported_arrays = state.get_meshes()[0].mesh.get_surface_arrays(0)


