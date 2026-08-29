extends VoxelTool


func apply(_target: Vector3i, hit: Vector3i) -> bool:
	if hit == VoxelPicking.NONE or not State.can_edit(hit):
		return false
	State.document.erase(State.current_frame, hit)
	return true


func update_visual(pick: PickResult) -> void:
	var pos := pick.hit if pick.hit != VoxelPicking.NONE else pick.target
	if pos == VoxelPicking.NONE:
		visible = false
		return
	position = Vector3(pos)
	visible = true
