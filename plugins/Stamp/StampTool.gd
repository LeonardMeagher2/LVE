extends "res://plugins/brush/StrokeTool.gd"

## The stamp tool.
##
## It stamps a prepared pattern from a file frame or the current selection. The
## destination selection is not a mask. The source selection is captured once.


func _init() -> void:
	_settings = preload("./StampSettings.tres")


## Handles one input event. A press without a prepared stamp does nothing.
func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and _settings.pattern().is_empty():
		return false
	return super.handle_input(event, pos)


## Opens this tool's stroke and removes the destination selection from its
## context. Symmetry, the slice, and the document size still apply.
func open_stroke() -> VoxelEditTransaction:
	var tx := super.open_stroke()
	if tx != null and _edit_context != null:
		_edit_context = _edit_context.duplicate()
		_edit_context.selection = {}
	return tx


## Closes this tool's stroke as one history action.
func close_stroke(_action: String = "Stamp") -> void:
	var tx := _edit
	if tx == null:
		return
	_edit = null
	State.finish_edit(tx, "Stamp")
