extends VoxelTool


func apply(_target: Vector3i, hit: Vector3i) -> bool:
	if hit == VoxelPicking.NONE or not State.can_edit(hit):
		return false
	if not State.has_cell(hit):
		return false
	State.set_color(State.get_color_at(hit))
	return false
