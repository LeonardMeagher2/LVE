extends HBoxContainer

## The plane option bar.
##
## It selects the floor axis. The number control sets the slice layer count. A
## count of zero shows every layer.

func _ready() -> void:
	State.floor_plane_changed.connect(_sync)
	State.slice_changed.connect(_sync)
	_sync()


func _sync() -> void:
	match State.floor_axis:
		Vector3.Axis.AXIS_X:
			$x.button_pressed = true
		Vector3.Axis.AXIS_Y:
			$y.button_pressed = true
		Vector3.Axis.AXIS_Z:
			$z.button_pressed = true
	if int($Layers.value) != State.slice_layers:
		$Layers.set_value_no_signal(State.slice_layers)


func _on_x_toggled(toggled_on: bool) -> void:
	if toggled_on:
		State.floor_axis = Vector3.Axis.AXIS_X


func _on_y_toggled(toggled_on: bool) -> void:
	if toggled_on:
		State.floor_axis = Vector3.Axis.AXIS_Y


func _on_z_toggled(toggled_on: bool) -> void:
	if toggled_on:
		State.floor_axis = Vector3.Axis.AXIS_Z


func _on_layers_changed(value: float) -> void:
	State.slice_layers = int(value)
