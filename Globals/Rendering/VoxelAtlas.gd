extends RefCounted

# Keep one padded rectangle per distinct face pattern in this frame.
const MAX_SIZE := 4096
var patches: Array[Dictionary] = []
var patch_ids := {}
var size := Vector2i.ZERO
var albedo: Image
var orm: Image
var emission: Image
var emission_energy := 1.0
var has_transparency := false


func add_patch(materials: PackedFloat32Array, dimensions: Vector2i, checkpoint := Callable()) -> int:
	var uniform := true
	for base in range(VoxelFrame.MATERIAL_STRIDE, materials.size(), VoxelFrame.MATERIAL_STRIDE):
		if base % (VoxelFrame.MATERIAL_STRIDE * 4096) == 0 and checkpoint.is_valid() and not checkpoint.call(0):
			return -1
		for component in VoxelFrame.MATERIAL_STRIDE:
			if materials[base + component] != materials[component]:
				uniform = false
				break
		if not uniform:
			break
	if uniform:
		materials = materials.slice(0, VoxelFrame.MATERIAL_STRIDE)
		dimensions = Vector2i.ONE
	var key := [dimensions, materials]
	if patch_ids.has(key):
		return patch_ids[key]
	var id := patches.size()
	patch_ids[key] = id
	patches.append({"size": dimensions, "materials": materials, "position": Vector2i.ZERO})
	for base in range(0, materials.size(), VoxelFrame.MATERIAL_STRIDE):
		if base % (VoxelFrame.MATERIAL_STRIDE * 4096) == 0 and checkpoint.is_valid() and not checkpoint.call(0):
			return -1
		has_transparency = has_transparency or materials[base + 3] < 1.0
		for component in 3:
			emission_energy = maxf(emission_energy, materials[base + VoxelFrame.MATERIAL_EMISSION + component])
	return id


func bake(checkpoint: Callable) -> Error:
	if patches.is_empty():
		return OK
	var order := patches.duplicate()
	order.sort_custom(func(a, b): return a.size.y > b.size.y)
	var area := 0
	var widest := 0
	for patch in order:
		area += (patch.size.x + 2) * (patch.size.y + 2)
		widest = maxi(widest, patch.size.x + 2)
	var width := mini(MAX_SIZE, maxi(widest, ceili(sqrt(area))))
	while true:
		var cursor := Vector2i.ZERO
		var row_height := 0
		for patch in order:
			var padded: Vector2i = patch.size + Vector2i.ONE * 2
			if cursor.x + padded.x > width:
				cursor = Vector2i(0, cursor.y + row_height)
				row_height = 0
			patch.position = cursor + Vector2i.ONE
			cursor.x += padded.x
			row_height = maxi(row_height, padded.y)
		size = Vector2i(width, cursor.y + row_height)
		if size.y <= MAX_SIZE and widest <= MAX_SIZE:
			break
		if width == MAX_SIZE:
			return ERR_OUT_OF_MEMORY
		width = mini(width * 2, MAX_SIZE)
	albedo = Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	orm = Image.create_empty(size.x, size.y, false, Image.FORMAT_RGB8)
	emission = Image.create_empty(size.x, size.y, false, Image.FORMAT_RGB8)
	for patch_index in patches.size():
		var patch := patches[patch_index]
		var materials: PackedFloat32Array = patch.materials
		for y in range(-1, patch.size.y + 1):
			if not checkpoint.call(patch_index):
				return ERR_UNAVAILABLE
			for x in range(-1, patch.size.x + 1):
				# Duplicate edge texels into the gutter. Nearest sampling needs no mipmaps.
				var base: int = (clampi(y, 0, patch.size.y - 1) * patch.size.x + clampi(x, 0, patch.size.x - 1)) * VoxelFrame.MATERIAL_STRIDE
				var texel: Vector2i = patch.position + Vector2i(x, y)
				albedo.set_pixelv(texel, Color(materials[base], materials[base + 1], materials[base + 2], materials[base + 3]))
				orm.set_pixelv(texel, Color(1.0, materials[base + VoxelFrame.MATERIAL_ROUGHNESS], materials[base + VoxelFrame.MATERIAL_METALLIC]))
				var glow := Color(materials[base + 4], materials[base + 5], materials[base + 6]) / emission_energy
				emission.set_pixelv(texel, glow.linear_to_srgb())
	return OK


func patch_uvs(patch_id: int) -> PackedVector2Array:
	var patch := patches[patch_id]
	var start := Vector2(patch.position) / Vector2(size)
	var end := Vector2(patch.position + patch.size) / Vector2(size)
	return PackedVector2Array([start, Vector2(end.x, start.y), end, Vector2(start.x, end.y)])


func create_material(template: StandardMaterial3D = null) -> StandardMaterial3D:
	var material: StandardMaterial3D = template.duplicate() if template else StandardMaterial3D.new()
	material.resource_name = "VoxelAtlas"
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.texture_repeat = false
	material.vertex_color_use_as_albedo = false
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	if albedo == null:
		return material
	material.albedo_texture = ImageTexture.create_from_image(albedo)
	var finish := ImageTexture.create_from_image(orm)
	material.metallic = 1.0
	material.metallic_texture = finish
	material.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	material.roughness_texture = finish
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	# glTF multiplies the emissive factor and texture. Use the same operator in the viewport.
	material.emission_enabled = true
	material.emission = Color.WHITE
	material.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	material.emission_energy_multiplier = emission_energy
	material.emission_texture = ImageTexture.create_from_image(emission)
	if has_transparency:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material
