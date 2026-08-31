extends HBoxContainer

const AXES := {
	"x": Vector3.Axis.AXIS_X,
	"y": Vector3.Axis.AXIS_Y,
	"z": Vector3.Axis.AXIS_Z,
}


func _enter_tree() -> void:
	for b in get_children():
		if b is Button and AXES.has(str(b.name)):
			(b as Button).pressed.connect(_on_pressed.bind(str(b.name)))
	State.floor_plane_changed.connect(_sync)
	_sync()


func _exit_tree() -> void:
	if State.floor_plane_changed.is_connected(_sync):
		State.floor_plane_changed.disconnect(_sync)


func _on_pressed(btn_name: String) -> void:
	State.floor_axis = AXES[btn_name]


func _sync() -> void:
	for b in get_children():
		if b is Button and AXES.has(str(b.name)):
			(b as Button).set_pressed_no_signal(State.floor_axis == AXES[str(b.name)])
