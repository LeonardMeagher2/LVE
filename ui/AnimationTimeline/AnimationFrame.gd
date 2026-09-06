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

func _on_delay_value_changed(value: float) -> void:
	var voxel_frame = State.get_voxel_frame(get_index())
	if voxel_frame:
		voxel_frame.delay_ms = int(value)

func _on_button_toggled(toggled_on: bool) -> void:
	if toggled_on:
		State.current_frame = get_index()
