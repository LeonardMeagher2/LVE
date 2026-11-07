extends "res://plugins/brush/StrokeTool.gd"

## The paintbrush tool.
##
## The tool recolors the cells that the frame already holds. It never adds a
## cell. A large stamp runs on the worker pool. A stroke commits as one history
## action on release or on a tool switch. Escape and an edit context change roll
## the stroke back.


func _init() -> void:
	_settings = preload("./settings.tres")


## Returns [code]true[/code] when a press pick uses the add target in front of
## the clicked face. A paint press uses the picked cell.
func _pick_adds() -> bool:
	return false


## Returns [code]true[/code] when the cursor needs an occupied cell.
func _requires_hit() -> bool:
	return true


## Returns [code]true[/code] when the tool changes only cells that already
## exist.
func _paints_existing() -> bool:
	return true


## Returns the drag pick. A paint drag picks the surface cell, so the pointer
## stays on the surface.
func pick_drag(request: PickRequest) -> PickResult:
	return VoxelPicking.start_pick(request.origin, request.dir, request.frame, request.forward, State.slice_enabled)
