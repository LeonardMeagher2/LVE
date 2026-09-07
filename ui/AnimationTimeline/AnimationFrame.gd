class_name AnimationFrame
extends PanelContainer

@export var texture:Texture : set=set_texture

func set_frame(value:int) -> void:
	%Button.button_pressed = State.current_frame == value
	%Number.text = str(value + 1)
	var voxel_frame = State.get_voxel_frame(value)
	if voxel_frame:
		%Delay.value = voxel_frame.delay_ms


func set_texture(value:Texture) -> void:
	if value == texture:
		return
	texture = value
	%Thumbnail.texture = texture

func _ready() -> void:
	set_frame(get_index())
	set_texture(texture)
	State.frame_changed.connect(_on_frame_changed)
	State.cells_changed.connect(_on_cells_changed)
	VoxelImageRenderer.frame_rendered.connect(_on_frame_rendered)
	VoxelImageRenderer.request_frame_render(get_index())

func _on_frame_changed() -> void:
	set_frame(get_index())

func _on_cells_changed(frame: int, _affected: Array[Vector3i]) -> void:
	if frame == get_index():
		VoxelImageRenderer.request_frame_render(get_index())

func _on_frame_rendered(frame_index: int, rendered: ImageTexture) -> void:
	if frame_index == get_index():
		set_texture(rendered)

func _on_delay_value_changed(value: float) -> void:
	var voxel_frame = State.get_voxel_frame(get_index())
	if voxel_frame:
		voxel_frame.delay_ms = int(value)

func _on_button_toggled(toggled_on: bool) -> void:
	if toggled_on:
		State.current_frame = get_index()
