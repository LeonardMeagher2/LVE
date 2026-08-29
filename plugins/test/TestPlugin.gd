extends VoxiPlugin

func _ready() -> void:
	var label := Label3D.new()
	label.text = "test"
	add_editor_node(label)
