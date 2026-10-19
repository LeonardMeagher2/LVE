extends VoxelTool


func apply(_target: Vector3i, hit: Vector3i) -> bool:
	if hit == VoxelPicking.NONE or not State.can_edit(hit):
		return false
	if not State.has_cell(hit):
		return false
	var frame := State.get_current_voxel_frame()
	State.set_material(VoxelFrame.material(frame.get_color(hit), frame.get_emission(hit), frame.get_metallic(hit), frame.get_roughness(hit)))
	return false
