extends Control


signal resize_requested(delta: float)
signal resize_finished()
signal toggle_requested()

var _dragging := false

@onready var _line: ColorRect = $Line


func _ready() -> void:
	mouse_entered.connect(_set_highlight.bind(true))
	mouse_exited.connect(_set_highlight.bind(false))


func _set_highlight(on: bool) -> void:
	_line.color = Color(1, 1, 1, 0.35 if on or _dragging else 0.2)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.double_click:
		toggle_requested.emit()
		accept_event()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		_set_highlight(_dragging)
		if not _dragging:
			resize_finished.emit()
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		resize_requested.emit(-event.relative.y)
		accept_event()
