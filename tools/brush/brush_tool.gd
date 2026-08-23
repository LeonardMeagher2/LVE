class_name BrushTool
extends VoxelTool


func _pick_start(origin: Vector3, dir: Vector3) -> PickResult:
	var pick := super._pick_start(origin, dir)
	if not _add_mode() or pick.add_target == State.NONE:
		return pick
	pick.target = pick.add_target
	pick.plane = VoxelPicking.view_plane(pick.target, origin, _forward())
	return pick


func pick_drag(request: PickRequest) -> PickResult:
	if _add_mode():
		return super.pick_drag(request)
	return VoxelPicking.start_pick(request.origin, request.dir, request.cells, request.forward)


func apply(target: Vector3i, hit: Vector3i) -> bool:
	if _add_mode():
		if not State.can_edit(target):
			return false
		if State.document.has_cell(State.current_frame, target):
			return false
		State.document.paint(State.current_frame, target, State.current_color)
		return true
	if hit == State.NONE or not State.can_edit(hit):
		return false
	State.document.paint(State.current_frame, hit, State.current_color)
	return true


func _add_mode() -> bool:
	return info.id == "brush"
