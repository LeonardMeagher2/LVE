class_name BrushTool
extends VoxelTool


func _pick_start(origin: Vector3, dir: Vector3) -> PickResult:
	var pick := super._pick_start(origin, dir)
	if not _add_mode() or pick.add_target == State.NONE:
		return pick
	pick.target = pick.add_target
	pick.plane = VoxelPicking.view_plane(pick.target, origin, dir)
	return pick


func apply(target: Vector3i, hit: Vector3i) -> bool:
	if _add_mode():
		if State.document.has_cell(State.current_frame, target):
			return false
		State.document.paint(State.current_frame, target, State.current_color)
		State.recents.add(State.current_color)
		return true
	if hit == State.NONE:
		return false
	State.document.paint(State.current_frame, hit, State.current_color)
	State.recents.add(State.current_color)
	return true


func _add_mode() -> bool:
	return info.id == "brush"
