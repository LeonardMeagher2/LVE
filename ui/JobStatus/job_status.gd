class_name JobStatus
extends HBoxContainer

## Shows the one operation that State selects. It follows State.activity_changed,
## so it updates on each operation change. It hides when no operation runs.
##
## The progress fill sits behind the label, like the ValueButton fill. A
## determinate operation fills the bar and the label shows its percentage. An
## operation with an unknown total uses the ProgressBar's indeterminate
## animation, so it never shows a false percentage.
##
## The label shows the artist action from begin_operation, never a worker stage,
## a detail line, or a count. A measured operation reads "Filling · 42%". An
## unknown operation reads "Filling…". A pending cancellation reads "Cancelling…"
## until the owner finishes the operation.
##
## The row keeps the natural width of its text and stops at a cap. The label is
## anchored behind the fill, so it cannot size the row itself. The row measures
## the text instead, grows to that width up to the cap, and shrinks below it when
## space is short. The label trims with an ellipsis past that. The full text is on
## the tooltip and the accessible name.
##
## The cancel button appears only for an operation that is explicitly
## cancellable. A mouse press captures the shown operation id, and the release
## rechecks it, so a replaced operation cannot be cancelled by a stale click. The
## button and Escape share State.cancel_operation, so both use one cancel path.

const CANCEL_TOOLTIP := "Cancel operation"
const CANCELLING_TOOLTIP := "Cancelling…"
## The content keeps this small width when space is short.
const MIN_CONTENT_WIDTH := 24.0
## The content stops growing here, so a long label cannot push the status bar out.
const MAX_CONTENT_WIDTH := 320.0
## A small slack, so a fitted label is not trimmed by a rounding difference.
const CONTENT_SLACK := 4.0
const MIN_ROW_HEIGHT := 20.0

## A short operation does not flash the display. The caller can lower it, and a
## zero value shows every operation at once.
var delay_ms := 200

var _operation: State.Operation = null
var _pressed_id := 0
var _ready_done := false

@onready var _job: Control = $Job
@onready var _label: Label = $Job/ActivityLabel
@onready var _progress: ProgressBar = $Job/ActivityProgress
@onready var _cancel: Button = $Cancel
@onready var _delay: Timer = $Delay


func _ready() -> void:
	_cancel.tooltip_text = CANCEL_TOOLTIP
	_cancel.accessibility_name = CANCEL_TOOLTIP
	_cancel.button_down.connect(_on_cancel_button_down)
	_cancel.pressed.connect(_on_cancel_pressed)
	_delay.timeout.connect(_refresh_from_state)
	_ready_done = true
	_refresh_from_state()


func _notification(what: int) -> void:
	if what == NOTIFICATION_POST_ENTER_TREE:
		# Subscribe on every tree entry and unsubscribe on exit, so a re-entry
		# never adds a second connection.
		if not State.activity_changed.is_connected(_refresh_from_state):
			State.activity_changed.connect(_refresh_from_state)
		if _ready_done:
			_refresh_from_state()
	elif what == NOTIFICATION_EXIT_TREE:
		if State.activity_changed.is_connected(_refresh_from_state):
			State.activity_changed.disconnect(_refresh_from_state)


func _refresh_from_state() -> void:
	if not _ready_done:
		return
	_operation = State.get_activity()
	if _operation == null:
		_delay.stop()
		visible = false
		return
	var elapsed := State.activity_elapsed_ms()
	if elapsed >= delay_ms:
		_delay.stop()
		visible = true
	else:
		visible = false
		# Keep an active wait. A content update must not restart the delay.
		if _delay.is_stopped():
			_delay.start(maxf(0.001, (delay_ms - elapsed) / 1000.0))
	_refresh()


func _refresh() -> void:
	var operation := _operation
	if operation == null:
		return
	_progress.indeterminate = operation.total <= 0
	var text := operation.label
	if operation.cancel_requested:
		# The owner finishes the operation, so the display stays until cleanup.
		text = CANCELLING_TOOLTIP
	elif operation.total > 0:
		var percent := clampf(operation.completed * 100.0 / operation.total, 0.0, 100.0)
		_progress.value = percent
		text = "%s · %d%%" % [operation.label, floori(percent)]
	else:
		text = "%s…" % operation.label
	_label.text = text
	# The row can trim the label, so keep the full text on the tooltip and the
	# accessible name. The tooltip carries no internal stage or count.
	tooltip_text = text
	accessibility_name = text
	_refresh_cancel()
	_update_width()


# Size the row to the text. The label trims with an ellipsis, so its own minimum
# is one pixel and cannot size the row. Measure the text instead, cap it, and set
# the row maximum. The row expands to that maximum and shrinks below it when
# space is short, so a short job stays compact and a long job is bounded.
func _update_width() -> void:
	if _operation == null:
		return
	var content := MAX_CONTENT_WIDTH
	var font := _label.get_theme_font("font")
	if font != null:
		var font_size := _label.get_theme_font_size("font_size")
		var wanted := font.get_string_size(_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + CONTENT_SLACK
		content = clampf(wanted, MIN_CONTENT_WIDTH, MAX_CONTENT_WIDTH)
	_job.custom_minimum_size = Vector2(MIN_CONTENT_WIDTH, MIN_ROW_HEIGHT)
	_job.custom_maximum_size.x = content
	var cancel_width := _cancel.get_combined_minimum_size().x if _cancel.visible else 0.0
	custom_maximum_size.x = content + cancel_width


func _refresh_cancel() -> void:
	var operation := _operation
	var pending := operation != null and operation.cancel_requested
	var shown := operation != null and (operation.can_cancel() or pending)
	_cancel.visible = shown
	_cancel.disabled = pending
	var tooltip := CANCELLING_TOOLTIP if pending else CANCEL_TOOLTIP
	_cancel.tooltip_text = tooltip
	_cancel.accessibility_name = tooltip


func _on_cancel_button_down() -> void:
	# Capture the target at the press, so a change before the release cannot
	# cancel a replacement operation.
	_pressed_id = _operation.id if _operation != null else 0


func _on_cancel_pressed() -> void:
	var target := _pressed_id
	_pressed_id = 0
	if _operation == null:
		return
	# A mouse press captured the target. A keyboard activation has no press, so
	# the shown operation is the target. Both must match the shown operation.
	if target != 0 and _operation.id != target:
		return
	# The button and Escape use one path. A stale or already pending operation is
	# refused inside State.cancel_operation.
	State.cancel_operation(_operation.id)
