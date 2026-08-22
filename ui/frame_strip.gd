class_name EditorFrameStrip
extends HBoxContainer

signal frame_selected(index: int)
signal delay_changed

var _frame_buttons: Array[Button] = []
var _previews: Array[FramePreview] = []
var _delay_fields: Array[LineEdit] = []


func _ready() -> void:
	State.frames_changed.connect(_rebuild)
	State.document_changed.connect(_rebuild)
	State.cells_changed.connect(_refresh_previews)
	_rebuild()


func highlight(i: int) -> void:
	for j in _frame_buttons.size():
		_frame_buttons[j].button_pressed = (j == i)
		if j == i:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.192, 0.318, 0.478)
			sb.set_corner_radius_all(3)
			_frame_buttons[j].add_theme_stylebox_override("normal", sb)
		else:
			_frame_buttons[j].remove_theme_stylebox_override("normal")
		_delay_fields[j].editable = (j == i)


func _rebuild() -> void:
	for b in _frame_buttons:
		b.queue_free()
	_frame_buttons.clear()
	_previews.clear()
	_delay_fields.clear()
	var group := ButtonGroup.new()
	for i in State.document.frames.size():
		var b := _make_button(i, group)
		add_child(b)
		_frame_buttons.append(b)
	highlight(State.current_frame)


func _make_button(i: int, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(56, 0)
	b.toggle_mode = true
	b.button_group = group
	b.pressed.connect(_select.bind(i))
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 1)
	b.add_child(col)
	var prev := FramePreview.new()
	prev.set_frame(State.document.frames[i], State.document)
	col.add_child(prev)
	_previews.append(prev)
	var num := Label.new()
	num.text = str(i + 1)
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(num)
	var d := LineEdit.new()
	d.custom_minimum_size = Vector2(44, 0)
	d.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	d.alignment = HORIZONTAL_ALIGNMENT_CENTER
	d.placeholder_text = "ms"
	d.text = str(State.document.frames[i].delay_ms)
	d.text_submitted.connect(_on_delay_submitted.bind(i))
	col.add_child(d)
	_delay_fields.append(d)
	return b


func _refresh_previews() -> void:
	for i in _previews.size():
		_previews[i].set_frame(State.document.frames[i], State.document)


func _on_delay_submitted(text: String, i: int) -> void:
	var v := text.strip_edges().to_int()
	if v < 1:
		_delay_fields[i].text = str(State.document.frames[i].delay_ms)
		return
	State.document.frames[i].delay_ms = clampi(v, 1, 10000)
	_delay_fields[i].text = str(State.document.frames[i].delay_ms)
	delay_changed.emit()


func _select(i: int) -> void:
	frame_selected.emit(i)
