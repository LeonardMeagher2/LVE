extends PanelContainer

func _ready() -> void:
	#State.cells_changed.connect(_update)
	_update()


func _update(frame: int = 0, affected: Array[Vector3i] = []) -> void:
	var index = get_index()
	%Number.text = str(index + 1)
	%Delay.value = State.document.frames[index].delay_ms
	%Button.set_pressed_no_signal(State.current_frame == index)
	if not affected.is_empty() and frame != index:
		return


func _on_delay_value_changed(value: float) -> void:
	var index = get_index()
	State.document.frames[index].delay_ms = int(value)


func _on_button_toggled(toggled_on: bool) -> void:
	if toggled_on:
		State.current_frame = get_index()
