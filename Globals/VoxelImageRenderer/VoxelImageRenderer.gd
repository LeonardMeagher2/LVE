extends Node

signal frame_rendered(frame_index: int, texture: ImageTexture)

const VIEWPORT_SCENE := preload("res://Globals/VoxelImageRenderer/RendererViewport.tscn")

var parked_transform := Transform3D.IDENTITY

var resolution := 64
var yaw_degrees := -45.0
var pitch_degrees := 45.0
var orthographic := true

var _viewport: SubViewport
var _renderer: VoxelRenderer
var _camera: Camera3D
var _queue: Array[int] = []
var _busy := false


func _ready() -> void:
	_viewport = VIEWPORT_SCENE.instantiate()
	add_child(_viewport)
	_viewport.size = Vector2i(resolution, resolution)
	_renderer = _viewport.get_node("%VoxelRenderer")
	_camera = _viewport.get_node("Node3D/Camera3D")
	parked_transform = _camera.transform
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	State.frames_changed.connect(_clear_queue)


func request_frame_render(frame_index: int) -> void:
	if _queue.has(frame_index):
		return
	_queue.append(frame_index)
	if not _busy:
		_busy = true
		_process_queue.call_deferred()


func _clear_queue() -> void:
	_queue.clear()


func _process_queue() -> void:
	if _queue.is_empty():
		_busy = false
		return
	var index: int = _queue.pop_front()
	if index < 0 or index >= State.document.frames.size():
		_process_queue()
		return
	var texture := await _render_frame(index)
	frame_rendered.emit(index, texture)
	_process_queue()


func _render_frame(index: int) -> ImageTexture:
	if DisplayServer.get_name() == "headless":
		return ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_RGBA8))
	_renderer.frame = index
	_frame_camera(State.document.bounds())
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var image: Image = _viewport.get_texture().get_image()
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	return ImageTexture.create_from_image(image)


func _frame_camera(bounds: AABB) -> void:
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL if orthographic else Camera3D.PROJECTION_PERSPECTIVE
	if not bounds.has_volume():
		_camera.transform = parked_transform
		return
	var target: Vector3 = bounds.get_center()
	var dist: float = bounds.size.length() * 1.25
	var off: Vector3 = Vector3(
		sin(deg_to_rad(yaw_degrees)) * cos(deg_to_rad(pitch_degrees)),
		sin(deg_to_rad(pitch_degrees)),
		cos(deg_to_rad(yaw_degrees)) * cos(deg_to_rad(pitch_degrees))
	) * dist
	_camera.position = target + off
	_camera.look_at(target, Vector3.UP)
	if orthographic:
		_camera.size = 2.0 * dist * tan(deg_to_rad(_camera.fov) / 2.0)
