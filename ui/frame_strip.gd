class_name EditorFrameStrip
extends HBoxContainer

signal frame_selected(index: int)
signal delay_changed

var _buttons: Array[EditorFrameButton] = []
var _template: EditorFrameButton

func _ready() -> void:
	_template = get_child(0)
	remove_child(_template)
	State.frames_changed.connect(_rebuild)
	State.document_changed.connect(_rebuild)
	State.cells_changed.connect(_refresh_previews)
	_rebuild()


func highlight(i: int) -> void:
	for j in _buttons.size():
		_buttons[j].set_highlighted(j == i)


func _rebuild() -> void:
	for b in _buttons:
		b.queue_free()
	_buttons.clear()
	var group := ButtonGroup.new()
	for i in State.document.frames.size():
		var b: EditorFrameButton = _template.duplicate()
		add_child(b)
		b.setup(i, State.document.frames[i], State.document, group)
		b.frame_selected.connect(frame_selected.emit)
		b.delay_changed.connect(delay_changed.emit)
		_buttons.append(b)
	highlight(State.current_frame)


func _refresh_previews() -> void:
	for i in _buttons.size():
		_buttons[i].refresh(State.document.frames[i], State.document)
