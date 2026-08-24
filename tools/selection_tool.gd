class_name SelectionTool
extends VoxelTool

var _shift := false


func _build_visual() -> Node3D:
	var ps: PackedScene = load("res://viewport/selection_preview.tscn")
	return ps.instantiate()


func update_visual(pick: PickResult) -> void:
	if visual == null:
		return
	(visual as SelectionPreview).show_cell(pick.target)


func _mode() -> String:
	if _shift:
		return "add"
	return State.get_tool_option(info, "mode")


func _apply_mode(drag: VoxelSelection) -> VoxelSelection:
	match _mode():
		"add":
			var out := VoxelSelection.new()
			out.cells = State.selection.cells.duplicate()
			out.union(drag)
			return out
		"subtract":
			var out := VoxelSelection.new()
			out.cells = State.selection.cells.duplicate()
			out.subtract(drag)
			return out
	return drag
