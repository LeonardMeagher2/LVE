extends Node


const MODEL := "res://splash.lve"
const OUTPUT := "res://docs/screenshots/lowpoly/"
const VIEWS := [
	{"name": "flamingo_low_1.png", "direction": Vector3(1.0, 0.7, 1.0)},
	{"name": "flamingo_low_2.png", "direction": Vector3(-1.0, 0.7, 1.0)},
	{"name": "flamingo_low_3.png", "direction": Vector3(1.0, 0.4, -1.0)},
	{"name": "flamingo_low_4.png", "direction": Vector3(-1.0, 0.5, -1.0)},
]
const VOXEL_VIEW := {"name": "flamingo_voxel.png", "direction": Vector3(1.0, 0.7, 1.0)}
const SIZE := Vector2i(1280, 960)

var viewport: SubViewport
var camera: Camera3D
var model: Node3D


func _ready() -> void:
	var document := VoxelDocument.load_file(MODEL)
	if document == null:
		push_error("model does not load: %s" % MODEL)
		get_tree().quit(1)
		return
	var frame: VoxelFrame = document.frames[0]
	_build_viewport()
	_build_environment()
	model = Node3D.new()
	viewport.add_child(model)
	_build_model(frame, document, true)
	await _capture_all()
	_clear_model()
	_build_model(frame, document, false)
	await _capture(VOXEL_VIEW)
	get_tree().quit()


func _build_viewport() -> void:
	viewport = SubViewport.new()
	viewport.size = SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	add_child(viewport)
	camera = Camera3D.new()
	camera.fov = 32.0
	camera.near = 0.1
	camera.far = 4000.0
	viewport.add_child(camera)


func _build_environment() -> void:
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.11, 0.11, 0.12)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.45
	world.environment = environment
	viewport.add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	light.light_energy = 1.1
	viewport.add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20.0, 145.0, 0.0)
	fill.light_energy = 0.35
	viewport.add_child(fill)


func _build_model(frame: VoxelFrame, document: VoxelDocument, low_poly: bool) -> void:
	for location: Vector3i in frame.chunks:
		var builder := VoxelMeshBuilder.new()
		builder.source_frame = frame
		builder.chunk_location = location
		builder.low_poly = low_poly
		builder.smooth_normals = document.smooth_normals
		builder.ao_strength = document.ao_strength
		builder.run()
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, builder.surface_arrays)
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.material_override = _material(builder)
		instance.position = Vector3(location * VoxelFrame.CHUNK_SIZE)
		model.add_child(instance)


func _material(builder: VoxelMeshBuilder) -> StandardMaterial3D:
	var material: StandardMaterial3D
	if builder.atlas != null:
		material = builder.atlas.create_material()
	elif builder.atlas_size.x > 0:
		material = StandardMaterial3D.new()
		material.albedo_texture = _texture(builder.atlas_size, builder.atlas_albedo)
		var finish := _texture(builder.atlas_size, builder.atlas_orm)
		material.metallic_texture = finish
		material.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
		material.roughness_texture = finish
		material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		material.emission_texture = _texture(builder.atlas_size, builder.atlas_emission)
		material.emission_enabled = true
		material.emission = Color.BLACK
		material.metallic = 1.0
		material.roughness = 1.0
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	else:
		material = StandardMaterial3D.new()
		material.albedo_color = Color.MAGENTA
	if builder.ao_strength > 0.0:
		material.vertex_color_use_as_albedo = true
		material.vertex_color_is_srgb = false
	return material


func _texture(size: Vector2i, bytes: PackedByteArray) -> ImageTexture:
	return ImageTexture.create_from_image(Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGB8, bytes))


func _capture_all() -> void:
	for view in VIEWS:
		await _capture(view)


func _capture(view: Dictionary) -> void:
	var bounds := _bounds()
	var centre := bounds.get_center()
	var radius := maxf(bounds.size.length() * 0.5, 0.5)
	var direction: Vector3 = (view.direction as Vector3).normalized()
	var distance := radius / tan(deg_to_rad(camera.fov) * 0.5) * 1.05
	camera.look_at_from_position(centre + direction * distance, centre, Vector3.UP)
	for frame_index in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var error := image.save_png(OUTPUT + view.name)
	print("SHOT %s bounds=%s bytes=%d error=%d" % [view.name, bounds, image.get_data().size(), error])


func _bounds() -> AABB:
	var bounds := AABB()
	var first := true
	for child: MeshInstance3D in model.get_children():
		if child.mesh == null:
			continue
		var box: AABB = child.transform * child.mesh.get_aabb()
		if first:
			bounds = box
			first = false
		else:
			bounds = bounds.merge(box)
	return bounds


func _clear_model() -> void:
	for child in model.get_children():
		child.queue_free()
