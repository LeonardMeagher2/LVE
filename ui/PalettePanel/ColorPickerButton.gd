extends ColorPickerButton

func _ready() -> void:
	var color_picker = get_picker()
	color_picker.edit_alpha = false
	color_picker.edit_intensity = false
	color_picker.picker_shape = ColorPicker.SHAPE_NONE
	color_picker.can_add_swatches = false
	color_picker.sampler_visible = true
	color_picker.color_modes_visible = true
	color_picker.sliders_visible = true
	color_picker.hex_visible = true
	color_picker.presets_visible = false
	await get_tree().process_frame
	color_picker.custom_minimum_size = size
