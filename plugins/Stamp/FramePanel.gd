extends ScrollContainer

## The stamp frame side panel.
##
## It shows one preview for each frame of the source file. The selected preview
## becomes the stamp.

## Emitted when the user selects a frame.
signal frame_selected(index: int)

## The preview edge length in pixels.
const THUMBNAIL_SIZE := 64
const PREVIEW_SCENE := preload("res://Globals/VoxelImageRenderer/RendererViewport.tscn")

var _frames: Array[VoxelFrame] = []
var _buttons: Array[Button] = []
var _button_group := ButtonGroup.new()
var _populating := false
var _preview_revision := 0
var _preview_running := false
var _preview_restart := false
var _preview_viewport: SubViewport
var _preview_renderer: VoxelRenderer
var _preview_camera: Camera3D
var _preview_light: DirectionalLight3D

@onready var _tiles: VBoxContainer = %Tiles


func _ready() -> void:
	_preview_viewport = PREVIEW_SCENE.instantiate()
	add_child(_preview_viewport)
	_preview_viewport.size = Vector2i(THUMBNAIL_SIZE, THUMBNAIL_SIZE)
	_preview_renderer = _preview_viewport.get_node("%VoxelRenderer")
	_preview_camera = _preview_viewport.get_node("Node3D/Camera3D")
	_preview_light = _preview_viewport.get_node("Node3D/Light")
	_preview_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if not _frames.is_empty():
		_build_buttons()
		visible = true
	_start_previews()


func _enter_tree() -> void:
	if is_node_ready():
		_start_previews.call_deferred()


func _exit_tree() -> void:
	_preview_revision += 1
	_preview_restart = false
	if is_instance_valid(_preview_viewport):
		_preview_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


## Fills the panel with one preview button for each frame.
func show_frames(frames: Array[VoxelFrame]) -> void:
	_frames = frames
	_preview_revision += 1
	if not is_node_ready():
		return
	_build_buttons()
	visible = true
	_start_previews()


## Removes every frame and hides the panel.
func clear() -> void:
	_frames = []
	_preview_revision += 1
	if is_node_ready():
		_clear_buttons()
	visible = false


func _build_buttons() -> void:
	_clear_buttons()
	_populating = true
	for index in _frames.size():
		var button := Button.new()
		button.name = "Frame%d" % (index + 1)
		button.toggle_mode = true
		button.button_group = _button_group
		button.custom_minimum_size = Vector2(THUMBNAIL_SIZE, THUMBNAIL_SIZE)
		button.expand_icon = true
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.tooltip_text = "Frame %d" % (index + 1)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_on_button_pressed.bind(index))
		_tiles.add_child(button)
		_buttons.append(button)
	_populating = false


func _clear_buttons() -> void:
	_populating = true
	for button in _buttons:
		if is_instance_valid(button):
			_tiles.remove_child(button)
			button.queue_free()
	_buttons.clear()
	_populating = false


## Selects one frame without emitting another request.
func select_frame(index: int) -> void:
	if index < 0 or index >= _buttons.size():
		return
	_populating = true
	_buttons[index].button_pressed = true
	_populating = false


## Clears the frame selection while the panel stays open.
func clear_selection() -> void:
	_populating = true
	for button in _buttons:
		if is_instance_valid(button):
			button.set_pressed_no_signal(false)
	_populating = false


## Disables the previews while a stamp prepares.
func set_busy(busy: bool) -> void:
	for button in _buttons:
		if is_instance_valid(button):
			button.disabled = busy


func _on_button_pressed(index: int) -> void:
	if _populating:
		return
	frame_selected.emit(index)


func _start_previews() -> void:
	if _preview_running:
		_preview_restart = true
		return
	if not is_inside_tree() or _frames.is_empty() or _preview_renderer == null or not _preview_viewport.is_inside_tree():
		return
	_preview_running = true
	_preview_restart = false
	_run_previews()


func _run_previews() -> void:
	var revision := _preview_revision
	for index in _frames.size():
		if revision != _preview_revision or not is_inside_tree():
			break
		if index >= _buttons.size():
			break
		var button := _buttons[index]
		if not is_instance_valid(button) or button.icon != null:
			continue
		var texture := await _render_frame(_frames[index], revision)
		if texture == null or revision != _preview_revision or not is_inside_tree():
			break
		if index < _buttons.size() and is_instance_valid(_buttons[index]):
			_buttons[index].icon = texture
	_preview_running = false
	if _preview_restart and is_inside_tree():
		_preview_restart = false
		_start_previews()


func _render_frame(frame: VoxelFrame, revision: int) -> ImageTexture:
	if DisplayServer.get_name() == "headless":
		var placeholder := Image.create(THUMBNAIL_SIZE, THUMBNAIL_SIZE, false, Image.FORMAT_RGBA8)
		placeholder.fill(Color(0.18, 0.18, 0.18, 1.0))
		return ImageTexture.create_from_image(placeholder)
	_preview_renderer.source_frame = frame.copy_frame()
	while not _preview_renderer.is_settled():
		if revision != _preview_revision or not is_inside_tree():
			return null
		await get_tree().process_frame
	if revision != _preview_revision or not is_inside_tree():
		return null
	VoxelImageRenderer.frame_camera(_preview_camera, frame.get_bounds(), -45.0, 45.0, true)
	VoxelImageRenderer.apply_directional_shadow(_preview_light, _preview_camera)
	for draw in 2:
		if revision != _preview_revision or not is_inside_tree():
			return null
		_preview_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
	if revision != _preview_revision or not is_inside_tree():
		return null
	var image := _preview_viewport.get_texture().get_image()
	_preview_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	image.convert(Image.FORMAT_RGBA8)
	return ImageTexture.create_from_image(image)
