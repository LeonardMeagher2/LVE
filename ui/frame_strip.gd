class_name EditorFrameStrip
extends HBoxContainer

signal frame_selected(index: int)

var _frame_buttons: Array[Button] = []


func _ready() -> void:
	State.frame_changed.connect(_rebuild)
	_rebuild()


func highlight(i: int) -> void:
	for j in _frame_buttons.size():
		_frame_buttons[j].button_pressed = (j == i)
		if j == i:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.28, 0.42, 0.62)
			sb.set_corner_radius_all(3)
			_frame_buttons[j].add_theme_stylebox_override("normal", sb)
		else:
			_frame_buttons[j].remove_theme_stylebox_override("normal")


func _rebuild() -> void:
	for b in _frame_buttons:
		b.queue_free()
	_frame_buttons.clear()
	var group := ButtonGroup.new()
	for i in State.document.frames.size():
		var b := Button.new()
		b.text = str(i + 1)
		b.custom_minimum_size = Vector2(34, 30)
		b.toggle_mode = true
		b.button_group = group
		b.pressed.connect(_select.bind(i))
		add_child(b)
		_frame_buttons.append(b)
	highlight(State.current_frame)


func _select(i: int) -> void:
	frame_selected.emit(i)
