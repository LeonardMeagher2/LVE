class_name EraserTool
extends VoxelTool


func apply(_target: Vector3i, hit: Vector3i) -> bool:
	if hit == State.NONE or not State.can_edit(hit):
		return false
	State.document.erase(State.current_frame, hit)
	return true


func update_visual(pick: PickResult) -> void:
	if visual == null:
		return
	var pos := pick.hit if pick.hit != State.NONE else pick.target
	if pos == State.NONE:
		visual.visible = false
		return
	visual.position = Vector3(pos)
	visual.visible = true


func _build_visual() -> Node3D:
	var v := super._build_visual()
	_hover_mat.albedo_color = Color(1.0, 0.35, 0.35, 0.4)
	return v


func _on_color_changed(_c: Color) -> void:
	if _hover_mat:
		_hover_mat.albedo_color = Color(1.0, 0.35, 0.35, 0.4)
