extends "res://tests/test.gd"


const VIEW := preload("res://tests/helpers/marching_view.gd")
const ALBEDO := Color(0.8, 0.2, 0.1)
const EMISSION := Color(0.1, 0.2, 0.3)
const METALLIC := 0.7
const ROUGHNESS := 0.3

var _view
var _flat_vertices := 0
var _flat_normals := PackedVector3Array()
var _flat_indices := PackedInt32Array()
var _smooth_vertices := 0
var _smooth_normals := PackedVector3Array()


func _ready() -> void:
	timeout = 60.0
	test("the low-poly mesh uses the atlas PBR values", _atlas, "march_atlas_pbr")
	test("the low-poly mesh keeps one normal per triangle in flat mode", _flat_normals_test, "march_flat_normals")
	test("the low-poly mesh blends shared normals in smooth mode", _smooth_normals_test, "march_smooth_normals")
	test("the renderer passes the smooth normal setting", _smooth_renderer_test, "march_smooth_renderer")


func _atlas() -> void:
	step("Given one voxel with a metal, rough, and glowing material", func():
		_view = VIEW.new(self)
		_view.apply({
			Vector3i.ZERO: VoxelFrame.material(
				ALBEDO, EMISSION, METALLIC, ROUGHNESS
			),
		})
	)
	await _view.settle()
	step("Then the chunk uses the atlas textures and the material values", func():
		var instance := _instance_at(Vector3.ZERO)
		expect(instance != null, "the chunk instance is visible")
		if instance == null:
			return
		var material: StandardMaterial3D = instance.material_override
		expect(material != null, "the chunk has an atlas material")
		if material == null:
			return
		expect(material.albedo_texture != null, "the atlas provides the albedo texture")
		expect(material.metallic_texture != null, "the atlas provides the finish texture")
		expect(material.roughness_texture != null, "the atlas provides the roughness texture")
		expect(material.emission_texture != null, "the atlas provides the emission texture")
		expect(material.metallic_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_BLUE, "the metal value uses the blue channel")
		expect(material.roughness_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_GREEN, "the roughness value uses the green channel")
		var arrays: Array = instance.mesh.surface_get_arrays(0)
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		expect(uvs.size() == arrays[Mesh.ARRAY_VERTEX].size(), "each vertex has a UV")
		expect(not uvs.is_empty(), "the mesh has UVs")
		if uvs.is_empty():
			return
		var uv := uvs[0]
		var albedo := material.albedo_texture.get_image().get_pixelv(_texel(uv, material.albedo_texture.get_size()))
		expect(absf(albedo.r - ALBEDO.r) < 0.01, "the albedo red matches")
		expect(absf(albedo.g - ALBEDO.g) < 0.01, "the albedo green matches")
		expect(absf(albedo.b - ALBEDO.b) < 0.01, "the albedo blue matches")
		var finish := material.metallic_texture.get_image().get_pixelv(_texel(uv, material.metallic_texture.get_size()))
		expect(absf(finish.g - ROUGHNESS) < 0.01, "the roughness matches")
		expect(absf(finish.b - METALLIC) < 0.01, "the metallic matches")
		expect(material.emission_enabled, "the atlas material emits light")
		expect(absf(material.emission_energy_multiplier - 1.0) < 0.01, "the atlas keeps the default energy")
		var glow := material.emission_texture.get_image().get_pixelv(_texel(uv, material.emission_texture.get_size()))
		var expected_glow := EMISSION.linear_to_srgb()
		expect(absf(glow.r - expected_glow.r) < 0.02, "the emission red matches")
		expect(absf(glow.g - expected_glow.g) < 0.02, "the emission green matches")
		expect(absf(glow.b - expected_glow.b) < 0.02, "the emission blue matches")
	)


func _flat_normals_test() -> void:
	step("Given a two-cube block built in flat mode", func():
		var builder := _builder(false)
		_flat_normals = builder.surface_arrays[Mesh.ARRAY_NORMAL]
		_flat_indices = builder.surface_arrays[Mesh.ARRAY_INDEX]
		_flat_vertices = _flat_normals.size()
	)
	step("Then each triangle keeps one normal", func():
		expect(_flat_vertices > 0, "the block builds a surface")
		var separate := 0
		for triangle in range(0, _flat_indices.size(), 3):
			var first := _flat_normals[_flat_indices[triangle]]
			var second := _flat_normals[_flat_indices[triangle + 1]]
			var third := _flat_normals[_flat_indices[triangle + 2]]
			if not first.is_equal_approx(second) or not first.is_equal_approx(third):
				separate += 1
		expect(separate == 0, "each triangle uses one normal")
	)


func _smooth_normals_test() -> void:
	step("Given the same block built in flat and smooth mode", func():
		var flat := _builder(false)
		_flat_vertices = flat.surface_arrays[Mesh.ARRAY_VERTEX].size()
		var builder := _builder(true)
		_smooth_normals = builder.surface_arrays[Mesh.ARRAY_NORMAL]
		_smooth_vertices = _smooth_normals.size()
	)
	step("Then shared corners blend and the mesh uses fewer vertices", func():
		expect(_smooth_vertices > 0, "the smooth block builds a surface")
		expect(_smooth_vertices < _flat_vertices, "smooth mode shares vertices")
		var blended := 0
		var unit := true
		for normal in _smooth_normals:
			var axes := 0
			if absf(normal.x) > 0.001:
				axes += 1
			if absf(normal.y) > 0.001:
				axes += 1
			if absf(normal.z) > 0.001:
				axes += 1
			if axes > 1:
				blended += 1
			if absf(normal.length() - 1.0) >= 0.001:
				unit = false
		expect(unit, "each smooth normal has unit length")
		expect(blended > 0, "a corner normal blends two or more axes")
	)


func _smooth_renderer_test() -> void:
	step("Given a two-cube block with the smooth setting on", func():
		State.document.smooth_normals = true
		_view = VIEW.new(self)
		_view.apply(_block_cells())
	)
	await _view.settle()
	step("Then the renderer builds blended normals", func():
		_view.collect()
		var blended := 0
		for normal: Vector3 in _view.normals:
			var axes := 0
			if absf(normal.x) > 0.001:
				axes += 1
			if absf(normal.y) > 0.001:
				axes += 1
			if absf(normal.z) > 0.001:
				axes += 1
			if axes > 1:
				blended += 1
		expect(blended > 0, "the rendered mesh has a blended normal")
	)


func _builder(smooth: bool) -> VoxelMarchingMeshBuilder:
	var frame := VoxelFrame.new()
	frame.set_cells(_block_cells())
	var builder := VoxelMarchingMeshBuilder.new()
	builder.smooth_normals = smooth
	builder.source_frame = frame
	builder.chunk_location = Vector3i.ZERO
	builder.run()
	return builder


func _block_cells() -> Dictionary:
	var cells := {}
	for z in 2:
		for y in 2:
			for x in 2:
				cells[Vector3i(x, y, z)] = VoxelFrame.material(ALBEDO)
	return cells


func _texel(uv: Vector2, size: Vector2i) -> Vector2i:
	return Vector2i(clampi(floori(uv.x * size.x), 0, size.x - 1), clampi(floori(uv.y * size.y), 0, size.y - 1))


func _instance_at(position: Vector3) -> MeshInstance3D:
	for child in _view.renderer.get_children():
		if child is MeshInstance3D and child.visible and child.position == position:
			return child
	return null
