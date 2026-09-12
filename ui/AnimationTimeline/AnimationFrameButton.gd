extends Button

const DRAG_TYPE := "voxi_frame"


func _get_drag_data(_at_position: Vector2) -> Variant:
	var frame := get_parent() as AnimationFrame
	if frame == null:
		return null
	var data := {"type": DRAG_TYPE, "from": frame.frame_index}
	if get_viewport() and get_viewport().gui_is_dragging():
		var preview := Label.new()
		preview.text = "Frame %d" % (frame.frame_index + 1)
		set_drag_preview(preview)
	return data


func _can_drop_data(_at_position: Vector2, data) -> bool:
	return data is Dictionary and data.get("type", "") == DRAG_TYPE


func _drop_data(_at_position: Vector2, data) -> void:
	var frame := get_parent() as AnimationFrame
	if frame == null:
		return
	if data is Dictionary and data.get("type", "") == DRAG_TYPE:
		State.move_frame(data["from"], frame.frame_index)
