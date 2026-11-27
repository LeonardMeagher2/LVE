extends "res://tests/test.gd"


const EXPORT := preload("res://plugins/Export/GLTFExport.gd")
const ROUND_TRIP := "user://low_poly_export.glb"

var frame: VoxelFrame
var job: RefCounted
var reference_triangles := 0
var export_error := OK
var imported_arrays: Array


func _ready() -> void:
	timeout = 60.0
	test("the low-poly style exports its marching mesh with atlas UVs", _run)


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
