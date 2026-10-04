extends VoxelTool

var _settings := preload("../settings.tres")


func _apply_mode(drag: VoxelSelection) -> VoxelSelection:
	match _settings.mode:
		_settings.SelectMode.ADD:
			var out := VoxelSelection.new()
			out.restore(State.selection.capture())
			out.union(drag)
			return out
		_settings.SelectMode.SUBTRACT:
			var out := VoxelSelection.new()
			out.restore(State.selection.capture())
			out.subtract(drag)
			return out
	return drag

func begin_stroke() -> void:
	super()
	$SelectionPreview.visible = true
	$Cursor.visible = false


func end_stroke() -> void:
	super()
	$Cursor.visible = true
	$SelectionPreview.visible = false
