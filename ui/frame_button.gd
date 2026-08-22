class_name EditorFrameButton
extends VBoxContainer

signal frame_selected(index: int)
signal delay_changed

var index := 0

@onready var _preview: FramePreview = %Preview
@onready var _number: Label = %Number
@onready var _delay: LineEdit = %Delay


func _ready() -> void:
	_preview.toggle_mode = true
	_preview.pressed.connect(_emit_selected)
	_delay.text_submitted.connect(_on_delay_submitted)


func setup(i: int, frame: VoxelFrame, document: VoxiDocument, group: ButtonGroup) -> void:
	index = i
	_preview.button_group = group
	_number.text = str(i + 1)
	_delay.placeholder_text = "ms"
	_delay.text = str(frame.delay_ms)
	refresh(frame, document)


func refresh(frame: VoxelFrame, document: VoxiDocument) -> void:
	_preview.set_frame(frame, document)


func set_highlighted(selected: bool) -> void:
	_preview.button_pressed = selected
	if selected:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.192, 0.318, 0.478)
		sb.set_corner_radius_all(3)
		add_theme_stylebox_override("normal", sb)
	else:
		remove_theme_stylebox_override("normal")
	_delay.editable = selected


func _emit_selected() -> void:
	frame_selected.emit(index)


func _on_delay_submitted(text: String) -> void:
	var v := text.strip_edges().to_int()
	if v < 1:
		_delay.text = str(State.document.frames[index].delay_ms)
		return
	State.document.frames[index].delay_ms = clampi(v, 1, 10000)
	_delay.text = str(State.document.frames[index].delay_ms)
	delay_changed.emit()
