class_name AnimationFrame
extends PanelContainer

## One frame cell of the animation timeline.
##
## It shows the frame number, the duration, and a thumbnail. A press selects
## the frame. A duration edit records one history action.

## The thumbnail texture of this frame.
@export var texture:Texture : set=set_texture

## The frame index that this cell shows.
var frame_index := 0

## Shows one frame. It sets the number, the duration, and the pressed state.
func set_frame(value:int) -> void:
	%Button.button_pressed = State.current_frame == value
	%Number.text = str(value + 1)
	#%Delay.editable = State.current_frame == value
	var voxel_frame = State.get_voxel_frame(value)
	if voxel_frame:
		%Delay.value = voxel_frame.delay_ms


## Sets the thumbnail texture.
func set_texture(value:Texture) -> void:
	if value == texture:
		return
	texture = value
	%Thumbnail.texture = texture

func _ready() -> void:
	set_frame(frame_index)
	set_texture(texture)
	State.frame_changed.connect(_on_frame_changed)
	State.cells_changed.connect(_on_cells_changed)
	State.chunks_changed.connect(_on_cells_changed)
	VoxelImageRenderer.frame_rendered.connect(_on_frame_rendered)
	VoxelImageRenderer.request_frame_render(frame_index)

func _on_frame_changed() -> void:
	set_frame(frame_index)

func _on_cells_changed(frame: int, _affected: Array[Vector3i]) -> void:
	if frame == frame_index:
		VoxelImageRenderer.request_frame_render(frame_index)

func _on_frame_rendered(rendered_index: int, rendered: ImageTexture) -> void:
	if rendered_index == frame_index:
		set_texture(rendered)

func _on_delay_value_changed(value: float) -> void:
	State.set_frame_delay(frame_index, int(value))

func _on_button_toggled(toggled_on: bool) -> void:
	if toggled_on:
		State.current_frame = frame_index
