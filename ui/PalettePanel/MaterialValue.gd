extends Button

signal value_changed(value: float)
signal edit_started()
signal edit_finished(cancelled: bool)

var _value := 0.0

@export_range(0.0, 1.0, 0.01) var value: float = 0.0:
	get:
		return _value
	set(next):
		var previous := value
		set_value_no_signal(next)
		if value != previous:
			value_changed.emit(value)
@export var editable: bool = true:
	get:
		return not disabled
	set(next):
		disabled = not next
		if not next:
			reset_edit()

var _editing := false
var _pointer_down := false
var _dragging := false
var _press_position := Vector2.ZERO
var _original_value := 0.0
var _entry_initial_text := ""


func _ready() -> void:
	set_value_no_signal(value)


func set_value_no_signal(next: float) -> void:
	if not is_finite(next):
		return
	_value = clampf(next, 0.0, 1.0)
	text = "%.2f" % value
	var fill := get_node_or_null("Fill") as ProgressBar
	if fill:
		fill.value = value


func get_line_edit() -> LineEdit:
	return $LineEdit


func reset_edit() -> void:
	_editing = false
	_pointer_down = false
	_dragging = false
	set_pressed_no_signal(false)
	var entry := get_node_or_null("LineEdit") as LineEdit
	if entry:
		entry.hide()
	var fill := get_node_or_null("Fill") as ProgressBar
	if fill:
		fill.hide()


func _gui_input(event: InputEvent) -> void:
	if disabled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		if event.pressed:
			# Finish the previous field before starting this field's undo scope.
			grab_focus()
			_begin_edit()
			_pointer_down = _editing
			_press_position = event.position
			set_pressed_no_signal(_pointer_down)
		elif _pointer_down:
			_update_drag(event.position)
			_pointer_down = false
			set_pressed_no_signal(false)
			if _dragging:
				_finish_edit(false)
			elif _editing:
				_open_entry()
	elif event is InputEventMouseMotion and _pointer_down and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		accept_event()
		_update_drag(event.position)
	elif event.is_action("ui_accept"):
		accept_event()
		if event.is_action_pressed("ui_accept") and not event.is_echo():
			grab_focus()
			_begin_edit()
			_open_entry()
	elif event.is_action_pressed("ui_cancel") and _editing:
		accept_event()
		_finish_edit(true)


func _begin_edit() -> void:
	if _editing:
		return
	_original_value = value
	_editing = true
	edit_started.emit()


func _update_drag(position: Vector2) -> void:
	var delta := position - _press_position
	if not _dragging and delta.length() <= 4.0:
		return
	_dragging = true
	$Fill.show()
	# Use the press value, not the pointer's absolute position in the button.
	value = snappedf(_original_value + delta.x / 100.0, 0.01) if delta.x != 0.0 else _original_value


func _open_entry() -> void:
	if not _editing:
		return
	var entry := get_line_edit()
	entry.text = "%.2f" % value
	_entry_initial_text = entry.text
	entry.show()
	entry.grab_focus()
	entry.edit()
	entry.select_all()


func _finish_edit(cancelled: bool) -> void:
	if not _editing:
		return
	var next := value
	if get_line_edit().visible and not cancelled:
		var typed := get_line_edit().text.strip_edges()
		cancelled = not typed.is_valid_float() or not is_finite(typed.to_float())
		if not cancelled and typed != _entry_initial_text:
			next = snappedf(typed.to_float(), 0.01)
	value = _original_value if cancelled else next
	# A value listener can reset the control during a document switch.
	if not _editing:
		return
	reset_edit()
	edit_finished.emit(cancelled)


func _on_entry_gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_line_edit().accept_event()
		_finish_edit(true)
		grab_focus()


func _on_text_submitted(_text: String) -> void:
	_finish_edit(false)
	grab_focus()


func _on_entry_focus_exited() -> void:
	_finish_edit(false)


func _exit_tree() -> void:
	reset_edit()
