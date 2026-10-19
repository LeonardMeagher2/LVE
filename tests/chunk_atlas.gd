extends "res://tests/test.gd"

const MATERIAL := {"emission": Color(2.0, 1.0, 0.5), "metallic": 0.8, "roughness": 0.25}
const MESH_SAMPLES := preload("res://tests/helpers/mesh_samples.gd")

var scene_renderer: VoxelRenderer
var chunk_position := Vector3i.ZERO


func _ready() -> void:
	timeout = 20.0
	test("voxel materials bake into one atlas for each chunk", _run)


func _run() -> void:
	step("Given a chunk with a metallic voxel and a plain voxel", func():
		State.document = VoxelDocument.new()
		State.paint(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.paint(Vector3i(1, 0, 0), VoxelFrame.material(Color.BLUE))
		State.get_current_voxel_frame().set_cells({Vector3i(1, 0, 0): VoxelFrame.material(Color.BLUE, MATERIAL.emission, MATERIAL.metallic, MATERIAL.roughness)})
		scene_renderer = load("res://ui/Viewport/VoxelRenderer.tscn").instantiate()
		main.add_child(scene_renderer)
	)
	await _settle()
	step("Then the chunk material bakes all voxel values", func():
		var material: StandardMaterial3D = _chunk_material()
		expect(material != null, "the material chunk uses its own material")
		if material == null:
			return
		var surface: ArrayMesh = scene_renderer._surface_cache[_displayed_key()].surface
		expect(surface.get_surface_count() == 1, "the chunk uses one surface for all materials")
		expect(material.albedo_texture != null, "the material holds an albedo texture")
		expect(material.roughness_texture != null, "the material holds a metallic and roughness texture")
		expect(material.roughness_texture == material.metallic_texture, "one texture serves the metallic and the roughness")
		expect(material.roughness_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_GREEN, "the roughness reads the green channel")
		expect(material.metallic_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_BLUE, "the metallic reads the blue channel")
		expect(material.emission_texture != null, "the material holds an emission texture")
		expect(material.emission_enabled, "the material emits the baked light")
		expect(material.emission == Color.WHITE, "the emission color preserves the texture values")
		expect(material.emission_operator == BaseMaterial3D.EMISSION_OP_MULTIPLY, "the emission texture multiplies the white emission color")
		var energy := maxf(1.0, maxf(MATERIAL.emission.r, maxf(MATERIAL.emission.g, MATERIAL.emission.b)))
		expect(is_equal_approx(material.emission_energy_multiplier, energy), "the emission energy retains the HDR strength")
		expect(not material.vertex_color_use_as_albedo, "the atlas supplies the color without vertex colors")
		expect(material.albedo_texture.get_image().get_format() == Image.FORMAT_RGBA8, "the albedo atlas retains alpha")
		expect(material.roughness_texture.get_image().get_format() == Image.FORMAT_RGB8, "the finish atlas uses three channels")
		expect(material.metallic == 1.0 and material.roughness == 1.0, "the textures supply the metallic and roughness values")
		expect(_holds_color(material.albedo_texture, Color.BLUE), "the atlas holds the plain voxel color")
		expect(_holds_finish(material.roughness_texture, MATERIAL), "the atlas holds the metallic and the roughness")
		expect(_holds_color(material.emission_texture, (MATERIAL.emission / energy).linear_to_srgb()), "the atlas holds the normalized sRGB emission color")
		var template: StandardMaterial3D = scene_renderer.mesh.surface_get_material(0)
		expect(material.cull_mode == template.cull_mode, "the atlas retains the template cull mode")
		expect(material.rim_enabled == template.rim_enabled and is_equal_approx(material.rim, template.rim) and is_equal_approx(material.rim_tint, template.rim_tint), "the atlas retains the template rim settings")
		expect(material.stencil_flags == template.stencil_flags and material.stencil_color == template.stencil_color and is_equal_approx(material.stencil_outline_thickness, template.stencil_outline_thickness), "the atlas retains the template stencil settings")
	)
	step("When the user clears the material of the chunk", func():
		State.get_current_voxel_frame().set_cells({Vector3i(1, 0, 0): VoxelFrame.material(Color.BLUE)})
		var affected_chunks: Array[Vector3i] = [chunk_position]
		State.chunks_changed.emit(0, affected_chunks)
	)
	await _settle()
	step("Then the plain chunk retains its spatial atlas", func():
		var material := _chunk_material()
		expect(material != null and material.albedo_texture != null, "a plain chunk keeps its own atlas material")
		if material != null:
			expect(_holds_color(material.albedo_texture, Color.RED), "the plain atlas retains the red voxel")
			expect(_holds_color(material.albedo_texture, Color.BLUE), "the plain atlas retains the blue voxel")
			expect(is_equal_approx(material.emission_energy_multiplier, 1.0), "the plain atlas uses the minimum emission energy")
		expect(scene_renderer._surface_cache[_displayed_key()].bytes > 0, "the cached surface reports its size")
	)
	step("Given adjacent red voxels with two different materials", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var metal := VoxelFrame.material(Color.RED, Color.GREEN, 0.75, 0.25)
		frame.set_cell(Vector3i.RIGHT, metal)
		frame.set_cell(Vector3i.RIGHT * 2, metal)
		var job := VoxelMeshBuilder.new()
		job.source_frame = frame
		job.run()
		var vertices: PackedVector3Array = job.surface_arrays[Mesh.ARRAY_VERTEX]
		expect(vertices.size() == 40, "ten material-bounded faces retain their flat vertices")
		expect(job.surface_arrays[Mesh.ARRAY_INDEX].size() == 60, "ten material-bounded faces produce twenty triangles")
		expect(job.surface_arrays[Mesh.ARRAY_COLOR] == null, "the atlas mesh omits vertex colors")
		expect(job.atlas_size.x > 0 and job.atlas_size.y > 0, "the face rectangles fit in an atlas")
		expect(job.geometry_bytes == vertices.size() * 32 + job.surface_arrays[Mesh.ARRAY_INDEX].size() * 4, "the surface size includes positions, normals, and UVs")
		var albedo := Image.create_from_data(job.atlas_size.x, job.atlas_size.y, false, Image.FORMAT_RGBA8, job.atlas_albedo)
		var emission := Image.create_from_data(job.atlas_size.x, job.atlas_size.y, false, Image.FORMAT_RGB8, job.atlas_emission)
		var orm := Image.create_from_data(job.atlas_size.x, job.atlas_size.y, false, Image.FORMAT_RGB8, job.atlas_orm)
		var samples_match := true
		var face_samples := [0, 0, 0]
		# Sample each exposed voxel face, not at the atlas gutter.
		for cell: Vector3i in frame.positions():
			for direction: Vector3i in [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.DOWN, Vector3i.UP, Vector3i.FORWARD, Vector3i.BACK]:
				if frame.has(cell + direction):
					continue
				var uv: Variant = MESH_SAMPLES.uv_at(job.surface_arrays, Vector3(cell) + Vector3(direction) * 0.5, Vector3(direction))
				if uv == null:
					samples_match = false
					continue
				var texel := Vector2i(uv * Vector2(job.atlas_size))
				var is_metal := cell.x > 0
				face_samples[cell.x] += 1
				var glow := emission.get_pixelv(texel)
				var values := orm.get_pixelv(texel)
				samples_match = samples_match and albedo.get_pixelv(texel).is_equal_approx(Color.RED)
				samples_match = samples_match and glow.is_equal_approx(Color.GREEN if is_metal else Color.BLACK)
				samples_match = samples_match and absi(roundi(values.b * 255) - (191 if is_metal else 0)) <= 1
				samples_match = samples_match and absi(roundi(values.g * 255) - (64 if is_metal else 255)) <= 1
		expect(face_samples == [5, 4, 5], "all fourteen exposed voxel faces receive interior samples")
		expect(samples_match, "every voxel face interior samples its own material")
	)
	step("When an erased material leaves an unused slot", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i.RIGHT, VoxelFrame.material(Color.BLUE, Color.GREEN, 1.0, 0.25))
		frame.set_cell(Vector3i.RIGHT, VoxelFrame.material(Color.TRANSPARENT))
		var job := VoxelMeshBuilder.new()
		job.source_frame = frame
		job.run()
		expect(job.atlas_size == Vector2i(3, 3), "one remaining material uses one texel with a gutter")
		expect(job.atlas_albedo.size() == 3 * 3 * 4, "the uniform atlas retains its RGBA texels")
	)


func _settle() -> void:
	while not scene_renderer.is_settled():
		await get_tree().process_frame


func _displayed_key() -> PackedInt64Array:
	return scene_renderer._displayed_surface_keys[chunk_position]


func _chunk_material() -> StandardMaterial3D:
	return VoxelRenderer._surface_cache[_displayed_key()].material


func _holds_color(texture: Texture2D, color: Color) -> bool:
	var expected := Vector3i(roundi(color.r * 255.0), roundi(color.g * 255.0), roundi(color.b * 255.0))
	var image: Image = texture.get_image()
	for y in image.get_height():
		for x in image.get_width():
			var texel := image.get_pixel(x, y)
			if absi(roundi(texel.r * 255.0) - expected.x) <= 1 and absi(roundi(texel.g * 255.0) - expected.y) <= 1 and absi(roundi(texel.b * 255.0) - expected.z) <= 1:
				return true
	return false


# The packed finish texture holds roughness in green and metallic in blue.
func _holds_finish(texture: Texture2D, material: Dictionary) -> bool:
	var expected := Vector2i(roundi(material.roughness * 255.0), roundi(material.metallic * 255.0))
	var image: Image = texture.get_image()
	for y in image.get_height():
		for x in image.get_width():
			var texel := image.get_pixel(x, y)
			if absi(roundi(texel.g * 255.0) - expected.x) <= 1 and absi(roundi(texel.b * 255.0) - expected.y) <= 1:
				return true
	return false
