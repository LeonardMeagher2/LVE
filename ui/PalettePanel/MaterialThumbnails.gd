extends Node

## Renders and caches the palette material thumbnails.
##
## One off-screen viewport renders a rounded tile for each material. The cache
## is bounded. A headless run fills a flat color instead.

## Emitted when one thumbnail finishes. [param key] is the material key.
signal thumbnail_ready(key: String, texture: Texture2D)

## The maximum cached thumbnail count.
const CACHE_LIMIT := 256
## The tile edge length at display scale one, in pixels.
const TILE_SIZE := 32

var _cache: Dictionary = {}
var _pending: Dictionary = {}
var _rendering := false
var _revision := 0
var _material := StandardMaterial3D.new()

@onready var _viewport: SubViewport = $SubViewport


func _ready() -> void:
	$SubViewport/Tile.mesh = _make_tile()
	$SubViewport/Tile.material_override = _material
	# Keep reflection sources neutral and independent of the document world.
	var image := Image.create(256, 128, false, Image.FORMAT_RGBF)
	for y in image.get_height():
		for x in image.get_width():
			var uv := Vector2(x / 256.0, y / 128.0)
			var key_light := exp(-pow((uv.x - 0.2) / 0.07, 4.0) - pow((uv.y - 0.35) / 0.18, 4.0))
			var fill_light := exp(-pow((uv.x - 0.7) / 0.12, 4.0) - pow((uv.y - 0.45) / 0.24, 4.0))
			var value := 0.08 + 0.16 * (1.0 - uv.y) + key_light * 1.8 + fill_light * 0.7
			image.set_pixel(x, y, Color(value, value, value))
	var sky_material := PanoramaSkyMaterial.new()
	sky_material.panorama = ImageTexture.create_from_image(image)
	var sky := Sky.new()
	sky.sky_material = sky_material
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.12, 0.12, 0.12)
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.45
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	$SubViewport/WorldEnvironment.environment = environment
	if not _pending.is_empty():
		_rendering = true
		_render_pending.call_deferred(_revision)


## Returns the cache key of one material and display scale. Every material float
## is part of the key.
func thumbnail_key(material: PackedFloat32Array, display_scale: float = 1.0) -> String:
	# Use every float's bytes. Same-color material variants must not share a key.
	return material.to_byte_array().hex_encode() + ":" + var_to_bytes(display_scale).hex_encode()


## Returns the cached thumbnail, or null while one renders. A finished
## thumbnail emits [signal thumbnail_ready].
func request_thumbnail(material: PackedFloat32Array, display_scale: float = 1.0) -> Texture2D:
	if material.size() != VoxelFrame.MATERIAL_STRIDE:
		return null
	var key := thumbnail_key(material, display_scale)
	if _cache.has(key):
		var texture: Texture2D = _cache[key]
		_cache.erase(key)
		_cache[key] = texture
		return texture
	_pending[key] = [material.duplicate(), clampi(ceili(TILE_SIZE * display_scale), 2, 512)]
	if not _rendering and is_node_ready():
		_rendering = true
		_render_pending.call_deferred(_revision)
	return null


func _render_pending(revision: int) -> void:
	if revision != _revision:
		return
	while not _pending.is_empty() and is_inside_tree() and revision == _revision:
		var key: String = _pending.keys()[0]
		var request: Array = _pending[key]
		var material: PackedFloat32Array = request[0]
		var pixels: int = request[1]
		var image: Image
		if DisplayServer.get_name() == "headless":
			# The dummy renderer cannot capture a viewport. Do not wait for a draw signal.
			image = Image.create(pixels, pixels, false, Image.FORMAT_RGBA8)
			image.fill(Color(material[0], material[1], material[2], material[3]))
		else:
			_viewport.size = Vector2i.ONE * pixels
			_material.albedo_color = Color(material[0], material[1], material[2], material[3])
			_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if material[3] < 1.0 else BaseMaterial3D.TRANSPARENCY_DISABLED
			_material.emission_enabled = true
			_material.emission = Color(material[4], material[5], material[6])
			_material.metallic = material[7]
			_material.roughness = material[8]
			for draw in 2:
				_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
				await RenderingServer.frame_post_draw
				if not is_inside_tree() or revision != _revision:
					return
			image = _viewport.get_texture().get_image()
			_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_pending.erase(key)
		image.convert(Image.FORMAT_RGBA8)
		_round_corners(image)
		var texture := ImageTexture.create_from_image(image)
		_cache[key] = texture
		if _cache.size() > CACHE_LIMIT:
			_cache.erase(_cache.keys()[0])
		thumbnail_ready.emit(key, texture)
	if revision == _revision:
		_rendering = false


func _round_corners(image: Image) -> void:
	var pixels := image.get_width()
	var radius := pixels * 3.0 / TILE_SIZE
	var center := pixels * 0.5
	for y in pixels:
		for x in pixels:
			var corner := Vector2(maxf(absf(x + 0.5 - center) - center + radius, 0.0), maxf(absf(y + 0.5 - center) - center + radius, 0.0))
			var coverage := clampf(radius + 0.5 - corner.length(), 0.0, 1.0)
			if coverage < 1.0:
				var color := image.get_pixel(x, y)
				color.a *= coverage
				image.set_pixel(x, y, color)


func _make_tile() -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	const SEGMENTS := 24
	# Curve only the surface. Keep the projected outline square.
	for y in SEGMENTS + 1:
		for x in SEGMENTS + 1:
			var u := x * 2.0 / SEGMENTS - 1.0
			var v := y * 2.0 / SEGMENTS - 1.0
			vertices.append(Vector3(u, v, 0.22 * (1.0 - u * u) * (1.0 - v * v)))
			normals.append(Vector3(0.44 * u * (1.0 - v * v), 0.44 * v * (1.0 - u * u), 1.0).normalized())
	for y in SEGMENTS:
		for x in SEGMENTS:
			var i := y * (SEGMENTS + 1) + x
			indices.append_array(PackedInt32Array([i, i + SEGMENTS + 1, i + 1, i + 1, i + SEGMENTS + 1, i + SEGMENTS + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _exit_tree() -> void:
	_revision += 1
	_pending.clear()
	_rendering = false
	if is_instance_valid(_viewport):
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
