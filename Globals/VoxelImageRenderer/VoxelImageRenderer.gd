extends Node

signal frame_rendered(frame_index: int, texture: ImageTexture)

const VIEWPORT_SCENE := preload("res://Globals/VoxelImageRenderer/RendererViewport.tscn")

var parked_transform := Transform3D.IDENTITY

var resolution := 64
var yaw_degrees := -45.0
var pitch_degrees := 45.0
var orthographic := true

var _thumbnail_viewport: SubViewport
var _thumbnail_renderer: VoxelRenderer
var _thumbnail_camera: Camera3D
var _pending_frames: Array[int] = []
var _processing_queue := false
var _render_due_ms: Dictionary = {}
var _queue_revision := 0
const RENDER_DELAY_MS := 200


func _ready() -> void:
	_thumbnail_viewport = VIEWPORT_SCENE.instantiate()
	add_child(_thumbnail_viewport)
	_thumbnail_viewport.size = Vector2i(resolution, resolution)
	_thumbnail_renderer = _thumbnail_viewport.get_node("%VoxelRenderer")
	_thumbnail_camera = _thumbnail_viewport.get_node("Node3D/Camera3D")
	parked_transform = _thumbnail_camera.transform
	_thumbnail_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	State.frames_changed.connect(_clear_queue)
	State.document_changed.connect(_clear_queue)
	State.model_settings_changed.connect(_on_model_settings_changed)


func _on_model_settings_changed() -> void:
	_clear_queue()
	for frame_index in State.get_frame_count():
		request_frame_render(frame_index)


func request_frame_render(frame_index: int) -> void:
	_render_due_ms[frame_index] = Time.get_ticks_msec() + RENDER_DELAY_MS
	if _pending_frames.has(frame_index):
		return
	_pending_frames.append(frame_index)
	if not _processing_queue:
		_processing_queue = true
		_process_queue.call_deferred()


func _clear_queue() -> void:
	_pending_frames.clear()
	_render_due_ms.clear()
	_queue_revision += 1


func _process_queue() -> void:
	while not _pending_frames.is_empty():
		var frame_index := -1
		for queued_frame_index in _pending_frames:
			if Time.get_ticks_msec() >= _render_due_ms.get(queued_frame_index, 0):
				frame_index = queued_frame_index
				break
		if frame_index == -1:
			await get_tree().process_frame
			continue
		_pending_frames.erase(frame_index)
		_render_due_ms.erase(frame_index)
		if frame_index < 0 or frame_index >= State.document.frames.size():
			continue
		var render_revision := _queue_revision
		var requested_frame := State.get_voxel_frame(frame_index)
		var thumbnail_texture := await _render_frame(frame_index)
		if render_revision == _queue_revision and State.get_voxel_frame(frame_index) == requested_frame:
			frame_rendered.emit(frame_index, thumbnail_texture)
	_processing_queue = false


func _render_frame(frame_index: int) -> ImageTexture:
	if DisplayServer.get_name() == "headless":
		return ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_RGBA8))
	if _thumbnail_renderer.frame == frame_index:
		_thumbnail_renderer.refresh()
	else:
		_thumbnail_renderer.frame = frame_index
	while not _thumbnail_renderer.is_settled():
		await get_tree().process_frame
	_frame_camera(State.document.bounds())
	for draw in 2:
		_thumbnail_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
	var thumbnail_image: Image = _thumbnail_viewport.get_texture().get_image()
	_thumbnail_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	return ImageTexture.create_from_image(thumbnail_image)


func _frame_camera(document_bounds: AABB) -> void:
	_thumbnail_camera.projection = Camera3D.PROJECTION_ORTHOGONAL if orthographic else Camera3D.PROJECTION_PERSPECTIVE
	if not document_bounds.has_volume():
		_thumbnail_camera.transform = parked_transform
		return
	frame_camera(_thumbnail_camera, document_bounds, yaw_degrees, pitch_degrees, orthographic)
	apply_directional_shadow(_thumbnail_viewport.get_node("Node3D/Light"), _thumbnail_camera)


# In orthographic projection, Godot derives the directional shadow depth range from the camera far plane.
# Keep the far plane just past the content so orthographic shadows stay crisp.
func apply_directional_shadow(light: DirectionalLight3D, camera: Camera3D) -> void:
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL if camera.projection == Camera3D.PROJECTION_ORTHOGONAL else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS


func frame_camera(camera: Camera3D, document_bounds: AABB, yaw: float, pitch: float, use_orthographic: bool) -> void:
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL if use_orthographic else Camera3D.PROJECTION_PERSPECTIVE
	if not document_bounds.has_volume():
		document_bounds = AABB(Vector3.ONE * -0.5, Vector3.ONE)
	var content_center: Vector3 = document_bounds.get_center()
	var camera_distance: float = document_bounds.size.length() * 1.25
	camera.far = maxf(2.0, camera_distance * 1.6) if use_orthographic else maxf(1000.0, camera_distance * 3.0)
	var camera_offset: Vector3 = Vector3(
		sin(deg_to_rad(yaw)) * cos(deg_to_rad(pitch)),
		sin(deg_to_rad(pitch)),
		cos(deg_to_rad(yaw)) * cos(deg_to_rad(pitch))
	) * camera_distance
	camera.position = content_center + camera_offset
	camera.look_at(content_center, Vector3.FORWARD if absf(pitch) >= 89.9 else Vector3.UP)
	if use_orthographic:
		camera.size = 2.0 * camera_distance * tan(deg_to_rad(camera.fov) / 2.0)


func apply_lighting(light: DirectionalLight3D, environment: Environment, settings: Dictionary) -> void:
	light.basis = settings.basis
	light.light_color = settings.color
	light.light_energy = settings.energy
	light.shadow_enabled = settings.shadows
	environment.ambient_light_color = settings.ambient_color
	environment.ambient_light_energy = settings.ambient_energy


func render_document_preview(document: VoxelDocument) -> Image:
	if DisplayServer.get_name() == "headless":
		return null
	var viewport: SubViewport = VIEWPORT_SCENE.instantiate()
	viewport.size = Vector2i(256, 256)
	add_child(viewport)
	var renderer: VoxelRenderer = viewport.get_node("%VoxelRenderer")
	renderer.source_frame = document.frames[0].copy_frame()
	var camera: Camera3D = viewport.get_node("Node3D/Camera3D")
	var light: DirectionalLight3D = viewport.get_node("Node3D/Light")
	var environment_node: WorldEnvironment = viewport.get_node("Node3D/WorldEnvironment")
	environment_node.environment = environment_node.environment.duplicate()
	var environment := environment_node.environment
	light.basis = document.lighting_settings.get("basis", light.basis)
	var color: Color = document.lighting_settings.get("color", light.light_color)
	light.light_energy = color.a
	color.a = 1.0
	light.light_color = color
	color = document.lighting_settings.get("ambient_color", environment.ambient_light_color)
	environment.ambient_light_energy = color.a
	color.a = 1.0
	environment.ambient_light_color = color
	frame_camera(camera, renderer.source_frame.get_bounds(), yaw_degrees, pitch_degrees, true)
	apply_directional_shadow(light, camera)
	while not renderer.is_settled():
		await get_tree().process_frame
		if document != State.document:
			viewport.free()
			return null
	for draw in 2:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		if document != State.document:
			viewport.free()
			return null
	var image := viewport.get_texture().get_image()
	image.convert(Image.FORMAT_RGBA8)
	viewport.free()
	return image
