extends Button

signal value_changed(value: float)
signal edit_started()
signal edit_finished(cancelled: bool)

# Pixels of accumulated horizontal movement that cross the whole value range.
const DRAG_RANGE_PIXELS := 200.0

var _value := 0.0
var _editing := false
var _pointer_down := false
var _dragging := false
var _drag_distance := 0.0
var _drag_value := 0.0
var _original_value := 0.0
var _entry_initial_text := ""

# Declared before `value` so a saved scene applies the bounds before the value.
@export var min_value: float = 0.0:
	set(next):
		min_value = next
		set_value_no_signal(value)
@export var max_value: float = 1.0:
	set(next):
		max_value = next
		set_value_no_signal(value)
@export var step: float = 0.01
@export var decimals: int = 2:
	set(next):
		decimals = maxi(next, 0)
		set_value_no_signal(value)
@export var value: float = 0.0:
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


func _ready() -> void:
	set_value_no_signal(value)


func set_value_no_signal(next: float) -> void:
	if not is_finite(next):
		return
	var upper := maxf(min_value, max_value)
	_value = clampf(next, min_value, upper)
	text = _format(value)
	var fill := get_node_or_null("Fill") as ProgressBar
	if fill:
		fill.max_value = upper
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


func _format(next: float) -> String:
	return ("%." + str(decimals) + "f") % next


func _gui_input(event: InputEvent) -> void:
	if disabled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			return
		accept_event()
		# Finish the previous field before starting this field's undo scope.
		grab_focus()
		_begin_edit()
		_pointer_down = _editing
		set_pressed_no_signal(_pointer_down)
	elif event.is_action("ui_accept"):
		accept_event()
		if event.is_action_pressed("ui_accept") and not event.is_echo():
			grab_focus()
			_begin_edit()
			_open_entry()
	elif event.is_action_pressed("ui_cancel") and _editing:
		accept_event()
		_finish_edit(true)


# Track the drag in the input stage. The pointer can leave the button's rect
# during a drag, so hover-based GUI events are not enough.
func _input(event: InputEvent) -> void:
	if disabled or not _pointer_down:
		return
	if event is InputEventMouseMotion:
		get_viewport().set_input_as_handled()
		# A release outside the window delivers no button event, so the button
		# state on the motion ends the drag instead.
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_update_drag(event.relative)
		else:
			_end_drag()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		get_viewport().set_input_as_handled()
		_end_drag()


func _end_drag() -> void:
	_pointer_down = false
	set_pressed_no_signal(false)
	if _dragging:
		_finish_edit(false)
	elif _editing:
		_open_entry()


func _begin_edit() -> void:
	if _editing:
		return
	_original_value = value
	_drag_value = value
	_drag_distance = 0.0
	_editing = true
	edit_started.emit()


func _update_drag(relative: Vector2) -> void:
	_drag_distance += relative.length()
	if not _dragging and _drag_distance <= 4.0:
		return
	_dragging = true
	$Fill.show()
	# Track the accumulated movement, not the pointer's position, so the drag
	# does not depend on where the press landed.
	var span := max_value - min_value
	_drag_value = clampf(_drag_value + relative.x / DRAG_RANGE_PIXELS * span, min_value, max_value)
	value = snappedf(_drag_value, step) if step > 0.0 else _drag_value


func _open_entry() -> void:
	if not _editing:
		return
	var entry := get_line_edit()
	entry.text = _format(value)
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
			var typed_value := typed.to_float()
			next = snappedf(typed_value, step) if step > 0.0 else typed_value
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
