extends Button

## A button that shows one numeric value.
##
## A drag changes the value. A click opens a text entry. The button shows a
## fill bar behind its label. Escape cancels the edit and restores the start
## value.

## Emitted when the value changes.
signal value_changed(value: float)
## Emitted when an edit gesture starts.
signal edit_started()
## Emitted when an edit gesture finishes. [param cancelled] reports a rollback.
signal edit_finished(cancelled: bool)

# Pixels of accumulated horizontal movement that cross the whole value range.
## The drag distance in pixels that crosses the whole value range.
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
## The minimum value.
@export var min_value: float = 0.0:
	set(next):
		min_value = next
		set_value_no_signal(value)
## The maximum value.
@export var max_value: float = 1.0:
	set(next):
		max_value = next
		set_value_no_signal(value)
## The value step. A value of zero disables snapping.
@export var step: float = 0.01
## The number of decimal places.
@export var decimals: int = 2:
	set(next):
		decimals = maxi(next, 0)
		set_value_no_signal(value)
## The current value. A write emits [signal value_changed] when it changes.
@export var value: float = 0.0:
	get:
		return _value
	set(next):
		var previous := value
		set_value_no_signal(next)
		if value != previous:
			value_changed.emit(value)
## Whether the user can edit the value. A false value resets an open edit.
@export var editable: bool = true:
	get:
		return not disabled
	set(next):
		disabled = not next
		if not next:
			reset_edit()


func _ready() -> void:
	set_value_no_signal(value)


## Sets the value without emitting [signal value_changed]. It clamps to the
## bounds.
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


## Returns the text entry that edits the value.
func get_line_edit() -> LineEdit:
	return $LineEdit


## Clears the edit state and hides the entry and the fill.
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


# Handle the pointer in the GUI stage. The GUI keeps the pointer on the pressed
# button until the release, so this receives the drag outside the button's rect.
# It also needs the release, because the release clears that state. A mouse event
# consumed in the input stage stops before the GUI, so a drag must not use _input.
func _gui_input(event: InputEvent) -> void:
	if disabled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			accept_event()
			# Finish the previous field before starting this field's undo scope.
			grab_focus()
			_begin_edit()
			_pointer_down = _editing
			set_pressed_no_signal(_pointer_down)
		elif _pointer_down:
			_end_drag()
	elif event is InputEventMouseMotion and _pointer_down:
		# A release outside the window delivers no button event, so the button
		# state on the motion ends the drag instead.
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_update_drag(event.relative)
		else:
			_end_drag()
	elif event.is_action("ui_accept"):
		accept_event()
		if event.is_action_pressed("ui_accept") and not event.is_echo():
			grab_focus()
			_begin_edit()
			_open_entry()
	elif event.is_action_pressed("ui_cancel") and _editing:
		accept_event()
		_finish_edit(true)


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
