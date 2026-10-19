extends "res://tests/test.gd"

const EXPORT := preload("res://plugins/Export/GLTFExport.gd")
const ATLAS := preload("res://Globals/Rendering/VoxelAtlas.gd")
const MESH_SAMPLES := preload("res://tests/helpers/mesh_samples.gd")
var frame: VoxelFrame
var job: RefCounted
var flat_index_count := 0


func _ready() -> void:
	test("export atlases remove material splits and preserve every face sample", _run)


func _run() -> void:
	step("Given a box with different material values in every voxel", func():
		frame = VoxelFrame.new()
		for z in 2:
			for y in 3:
				for x in 4:
					frame.set_cell(Vector3i(x - 2, y + 15, z), VoxelFrame.material(Color(0.2 + x * 0.2, y * 0.3, z * 0.5), Color(x, y * 0.5, z * 0.25), x / 3.0, y / 2.0))
	)
	step("When the flat export mesh and textures are built", func():
		job = EXPORT.ExportJob.new()
		job.frames.append(frame)
		job.center_origin = false
		job.run()
	)
	step("Then the box retains every full-material boundary in its geometry", func():
		expect(job.error == OK, "the atlas bake completes")
		var arrays: Array = job.frame_surfaces[0]
		flat_index_count = arrays[Mesh.ARRAY_INDEX].size()
		expect(flat_index_count == 312, "fifty-two exposed material faces produce one hundred four triangles")
		expect(arrays[Mesh.ARRAY_VERTEX].size() < flat_index_count, "the indexed triangles share welded vertices")
		expect(arrays[Mesh.ARRAY_COLOR] == null, "the mesh needs no vertex colors")
		_expect_samples()
	)
	step("When the same frame uses smooth normals", func():
		job = EXPORT.ExportJob.new()
		job.frames.append(frame)
		job.center_origin = false
		job.smooth_normals = true
		job.run()
	)
	step("Then smooth normals retain their geometry and all material samples", func():
		expect(job.frame_surfaces[0][Mesh.ARRAY_INDEX].size() == flat_index_count, "smooth shading retains the flat topology count")
		expect(job.frame_surfaces[0][Mesh.ARRAY_VERTEX].size() < flat_index_count, "the smooth triangles share welded vertices")
		var unit_normals := true
		for normal: Vector3 in job.frame_surfaces[0][Mesh.ARRAY_NORMAL]:
			unit_normals = unit_normals and absf(normal.length() - 1.0) < 0.001
		expect(unit_normals, "all smooth normals have unit length")
		_expect_samples()
	)
	step("Then repeated uniform patches share one padded texel", func():
		var atlas := ATLAS.new()
		var material := VoxelFrame.material(Color(0.25, 0.5, 0.75, 0.5))
		var repeated := PackedFloat32Array()
		for index in 12:
			repeated.append_array(material)
		var first := atlas.add_patch(repeated, Vector2i(4, 3))
		var second := atlas.add_patch(material, Vector2i.ONE)
		expect(first == second and atlas.patches.size() == 1, "equal patterns deduplicate after uniform compression")
		expect(atlas.bake(func(_progress): return true) == OK, "the compact atlas bakes")
		expect(atlas.size == Vector2i(3, 3), "one texel and its gutter occupy nine pixels")
		expect(atlas.has_transparency, "the atlas detects partial alpha")
		expect(atlas.albedo.get_pixel(0, 0) == atlas.albedo.get_pixel(1, 1), "the gutter repeats the edge sample")
	)
	step("Then atlas limits and cancellation return explicit errors", func():
		var atlas := ATLAS.new()
		var materials := PackedFloat32Array()
		for index in ATLAS.MAX_SIZE:
			materials.append_array(VoxelFrame.material(Color.RED if index % 2 else Color.BLUE))
		atlas.add_patch(materials, Vector2i(ATLAS.MAX_SIZE, 1))
		expect(atlas.bake(func(_progress): return true) == ERR_OUT_OF_MEMORY, "an oversized atlas fails before image allocation")
		atlas = ATLAS.new()
		atlas.add_patch(VoxelFrame.material(Color.RED), Vector2i.ONE)
		expect(atlas.bake(func(_progress): return false) == ERR_UNAVAILABLE, "cancellation stops the bake")
		atlas = ATLAS.new()
		var repeated := PackedFloat32Array()
		for index in 4097:
			repeated.append_array(VoxelFrame.material(Color.RED))
		expect(atlas.add_patch(repeated, Vector2i(4097, 1), func(_progress): return false) == -1, "cancellation stops uniform patch compression")
		expect(atlas.add_patch(materials, Vector2i(ATLAS.MAX_SIZE, 1), func(_progress): return false) == -1, "cancellation stops the emission scan")
	)
	job = null


func _expect_samples() -> void:
	var arrays: Array = job.frame_surfaces[0]
	var atlas: RefCounted = job.frame_atlases[0]
	var samples_match := true
	var samples := 0
	for cell: Vector3i in frame.positions():
		for direction: Vector3i in [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.DOWN, Vector3i.UP, Vector3i.FORWARD, Vector3i.BACK]:
			if frame.has(cell + direction):
				continue
			var uv: Variant = MESH_SAMPLES.uv_at(arrays, Vector3(cell) + Vector3(direction) * 0.5, Vector3(direction))
			if uv == null:
				samples_match = false
				continue
			var texel := Vector2i(uv * Vector2(atlas.size))
			var color: Color = atlas.albedo.get_pixelv(texel)
			var finish: Color = atlas.orm.get_pixelv(texel)
			var emission: Color = atlas.emission.get_pixelv(texel).srgb_to_linear() * atlas.emission_energy
			var source := frame.get_color(cell)
			samples_match = samples_match and _near_color(color, source, 0.005)
			samples_match = samples_match and absf(finish.g - frame.get_roughness(cell)) < 0.005
			samples_match = samples_match and absf(finish.b - frame.get_metallic(cell)) < 0.005
			samples_match = samples_match and _near_color(emission, frame.get_emission(cell), 0.03, false)
			samples += 1
	expect(samples == 52, "every exposed voxel face is sampled on all six sides")
	expect(samples_match, "the UVs preserve albedo, roughness, metallic, and HDR emission at every sample")


func _near_color(actual: Color, expected: Color, tolerance: float, alpha := true) -> bool:
	return absf(actual.r - expected.r) < tolerance and absf(actual.g - expected.g) < tolerance and absf(actual.b - expected.b) < tolerance and (not alpha or absf(actual.a - expected.a) < tolerance)
