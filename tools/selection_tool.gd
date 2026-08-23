class_name SelectionTool
extends VoxelTool


func _build_visual() -> Node3D:
	var ps: PackedScene = load("res://viewport/selection_preview.tscn")
	return ps.instantiate()


func update_visual(pick: PickResult) -> void:
	if visual == null:
		return
	(visual as SelectionPreview).show_cell(pick.target)
