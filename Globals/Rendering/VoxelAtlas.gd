extends RefCounted

## Packs one padded rectangle per distinct face pattern.
##
## The atlas bakes an albedo image, a finish image, and an emission image. A
## patch holds one material or one face-pattern material list. The gutter
## repeats the edge texels, so nearest sampling needs no mipmaps.

# Keep one padded rectangle per distinct face pattern in this frame.
## The maximum atlas edge length in pixels.
const MAX_SIZE := 4096
## The patch records. Each holds a size, a material list, and a position.
var patches: Array[Dictionary] = []
## The patch id for each size and material key.
var patch_ids := {}
## The baked atlas size in pixels.
var size := Vector2i.ZERO
## The baked albedo image.
var albedo: Image
## The baked finish image. Blue holds metallic and green holds roughness.
var orm: Image
## The baked emission image.
var emission: Image
## The maximum emission strength across the patches.
var emission_energy := 1.0
## Whether any patch holds a color with alpha below one.
var has_transparency := false


## Adds one patch and returns its id. An equal patch returns its existing id. A
## uniform material list becomes a one-by-one patch. Returns -1 when
## [param checkpoint] cancels.
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


## Bakes the images and returns the error code. It packs the patches from
## tallest to shortest. Returns [constant ERR_UNAVAILABLE] when
## [param checkpoint] cancels.
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
	# Fill one byte buffer per image, then upload each image once. The gutter
	# repeats content texels, so one packed value per content texel is enough.
	var albedo_bytes := PackedByteArray()
	albedo_bytes.resize(size.x * size.y * 4)
	var finish_bytes := PackedByteArray()
	finish_bytes.resize(size.x * size.y * 3)
	var emission_bytes := PackedByteArray()
	emission_bytes.resize(size.x * size.y * 3)
	for patch_index in patches.size():
		var patch := patches[patch_index]
		var materials: PackedFloat32Array = patch.materials
		var patch_size: Vector2i = patch.size
		var position: Vector2i = patch.position
		var content := patch_size.x * patch_size.y
		var albedo_texels := PackedInt32Array()
		albedo_texels.resize(content)
		var finish_texels := PackedInt32Array()
		finish_texels.resize(content)
		var emission_texels := PackedInt32Array()
		emission_texels.resize(content)
		for index in content:
			# Image writes a color channel with uint8_t(clamp(value * 255.0, 0, 255)).
			# Keep the quantization inline: a helper call costs more than the math.
			var base := index * VoxelFrame.MATERIAL_STRIDE
			var red := int(clampf(materials[base] * 255.0, 0.0, 255.0))
			var green := int(clampf(materials[base + 1] * 255.0, 0.0, 255.0))
			var blue := int(clampf(materials[base + 2] * 255.0, 0.0, 255.0))
			var alpha := int(clampf(materials[base + 3] * 255.0, 0.0, 255.0))
			albedo_texels[index] = red | (green << 8) | (blue << 16) | (alpha << 24)
			finish_texels[index] = 255 | (int(clampf(materials[base + VoxelFrame.MATERIAL_ROUGHNESS] * 255.0, 0.0, 255.0)) << 8) | (int(clampf(materials[base + VoxelFrame.MATERIAL_METALLIC] * 255.0, 0.0, 255.0)) << 16)
			var glow := (Color(materials[base + 4], materials[base + 5], materials[base + 6]) / emission_energy).linear_to_srgb()
			emission_texels[index] = int(clampf(glow.r * 255.0, 0.0, 255.0)) | (int(clampf(glow.g * 255.0, 0.0, 255.0)) << 8) | (int(clampf(glow.b * 255.0, 0.0, 255.0)) << 16)
		for y in range(-1, patch_size.y + 1):
			if not checkpoint.call(patch_index):
				return ERR_UNAVAILABLE
			var content_row := clampi(y, 0, patch_size.y - 1) * patch_size.x
			var row_start := (position.y + y) * size.x + position.x
			for x in range(-1, patch_size.x + 1):
				# Duplicate edge texels into the gutter. Nearest sampling needs no mipmaps.
				var source := content_row + clampi(x, 0, patch_size.x - 1)
				var texel := row_start + x
				# encode_u32 writes little-endian, so the first byte is red.
				albedo_bytes.encode_u32(texel * 4, albedo_texels[source])
				var offset := texel * 3
				var finish_texel := finish_texels[source]
				var emission_texel := emission_texels[source]
				finish_bytes[offset] = finish_texel & 0xFF
				finish_bytes[offset + 1] = (finish_texel >> 8) & 0xFF
				finish_bytes[offset + 2] = (finish_texel >> 16) & 0xFF
				emission_bytes[offset] = emission_texel & 0xFF
				emission_bytes[offset + 1] = (emission_texel >> 8) & 0xFF
				emission_bytes[offset + 2] = (emission_texel >> 16) & 0xFF
	albedo.set_data(size.x, size.y, false, Image.FORMAT_RGBA8, albedo_bytes)
	orm.set_data(size.x, size.y, false, Image.FORMAT_RGB8, finish_bytes)
	emission.set_data(size.x, size.y, false, Image.FORMAT_RGB8, emission_bytes)
	return OK


## Returns the four corner UVs of one patch.
func patch_uvs(patch_id: int) -> PackedVector2Array:
	var patch := patches[patch_id]
	var start := Vector2(patch.position) / Vector2(size)
	var end := Vector2(patch.position + patch.size) / Vector2(size)
	return PackedVector2Array([start, Vector2(end.x, start.y), end, Vector2(start.x, end.y)])


## Returns a material that samples the baked atlas. [param template] supplies the
## base material settings.
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
