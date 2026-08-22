class_name PickTool
extends VoxelTool


func apply(_target: Vector3i, hit: Vector3i) -> bool:
	if hit == State.NONE or not State.can_edit(hit):
		return false
	if not State.document.has_cell(State.current_frame, hit):
		return false
	State.set_color(State.document.color_at(State.current_frame, hit))
	return false
