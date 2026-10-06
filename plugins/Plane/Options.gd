extends HBoxContainer

func _ready() -> void:
	State.floor_plane_changed.connect(_sync)
	_sync()


func _sync() -> void:
	match State.floor_axis:
		Vector3.Axis.AXIS_X:
			$x.button_pressed = true
		Vector3.Axis.AXIS_Y:
			$y.button_pressed = true
		Vector3.Axis.AXIS_Z:
			$z.button_pressed = true


func _on_x_toggled(toggled_on: bool) -> void:
	if toggled_on:
		State.floor_axis = Vector3.Axis.AXIS_X


func _on_y_toggled(toggled_on: bool) -> void:
	if toggled_on:
		State.floor_axis = Vector3.Axis.AXIS_Y


func _on_z_toggled(toggled_on: bool) -> void:
	if toggled_on:
		State.floor_axis = Vector3.Axis.AXIS_Z
