extends MeshInstance3D


func _ready() -> void:
	State.selection_changed.connect(sync_selection)


func sync_selection() -> void:
	if State.selection == null or State.selection.is_empty():
		visible = false
		return
	#mesh = SelectionPreview.outline_mesh(State.selection)
	visible = true
