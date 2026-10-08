extends Button

const DRAG_TYPE := "voxel_palette_color"

@export var color:Color :
	set(value):
		color = value
		tooltip_text = color.to_html(true)
		var sb_normal:StyleBoxFlat = get_theme_stylebox("normal")
		var sb_pressed:StyleBoxFlat = get_theme_stylebox("pressed")
		sb_normal.bg_color = color
		sb_pressed.bg_color = color


func _get_drag_data(_at_position: Vector2) -> Variant:
	if State.edit_busy():
		return null
	var data := {"type": DRAG_TYPE, "from": get_index(), "color": color, "document": State.document}
	if get_viewport() and get_viewport().gui_is_dragging():
		var preview := ColorRect.new()
		preview.color = color
		preview.size = size
		set_drag_preview(preview)
	return data


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if State.edit_busy() or not data is Dictionary or data.get("type", "") != DRAG_TYPE or data.get("document") != State.document:
		return false
	var from_index: int = data.get("from", -1)
	var colors := State.get_palette()
	return from_index >= 0 and from_index < colors.size() and colors[from_index] == data.get("color")


func _drop_data(at_position: Vector2, data: Variant) -> void:
	if _can_drop_data(at_position, data):
		State.move_palette_color(data["from"], get_index())
