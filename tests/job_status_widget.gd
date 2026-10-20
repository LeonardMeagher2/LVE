extends "res://tests/test.gd"

const CANCEL_TOOLTIP := "Cancel operation"
const LONG_LABEL := "Filling a very large connected selection across many chunks and animation frames"
const LONG_DETAIL := "twelve thousand cells remaining in the current region"

# The widget script is preloaded as a type alias. A new class_name is not in the
# global class cache until the editor regenerates it.
const JobStatusWidget = preload("res://ui/JobStatus/job_status.gd")

var widget: JobStatusWidget
var _status: Node
var _cancel_count := 0
var _first_id := 0
var _second_id := 0
var _operation_id := 0
var _short_width := 0.0
var _viewport: SubViewport


func _ready() -> void:
	test("the job widget shows a determinate operation", _determinate, "job_determinate")
	test("the job widget shows unknown work as indeterminate", _unknown, "job_unknown")
	test("the job widget hides the operation detail", _detail, "job_detail")
	test("the job widget hides a detail for measured work", _determinate_detail, "job_determinate_detail")
	test("the job widget keeps the begin label through worker phases", _stable_identity, "job_stable_identity")
	test("the job widget cancels a cancellable operation", _cancellable, "job_cancellable")
	test("the job widget hides the cancel button for a plain operation", _plain, "job_plain")
	test("the job widget shows a pending cancellation", _pending, "job_pending")
	test("the job widget shows the foreground operation first", _foreground_first, "job_foreground_first")
	test("Escape targets only the displayed foreground operation", _escape_target, "job_escape_target")
	test("the job widget can cancel selection deletion", _delete_cancel, "job_delete_cancel")
	test("the job widget hides a completed operation", _completion, "job_completion")
	test("a stale cancel press cannot cancel a replacement operation", _stale_target, "job_stale_target")
	test("a real stale press cannot cancel a replacement operation", _stale_mouse, "job_stale_mouse")
	test("a repeated cancel click cancels once", _repeat_click, "job_repeat_click")
	test("the cancel button takes keyboard focus and cancels", _keyboard, "job_keyboard")
	test("a real mouse press and release cancels the operation", _mouse, "job_mouse")
	test("the progress fill sits behind the visible label", _fill_behind_label, "job_fill_behind_label")
	test("a long label keeps the status bar inside a narrow window", _long_label, "job_long_label")
	test("a short label fits without trimming", _short_label, "job_short_label")
	test("the job widget keeps one subscription across a tree re-entry", _reentry, "job_reentry")
	test("the display delay survives a tree re-entry", _reentry_delay, "job_reentry_delay")


func _setup_test() -> void:
	_cancel_count = 0
	_first_id = 0
	_second_id = 0
	_operation_id = 0
	_short_width = 0.0
	_status = null
	_viewport = null
	while State.get_activity() != null:
		await get_tree().process_frame
	widget = load("res://ui/JobStatus/job_status.tscn").instantiate()
	# Show every operation at once, so the tests do not wait for the display delay.
	widget.delay_ms = 0
	main.add_child(widget)
	# A plain Control parent does not size its children, so give the widget a real
	# rectangle for layout and GUI hit tests.
	widget.size = Vector2(360, 40)
	await get_tree().process_frame


func _cleanup_test() -> void:
	if is_instance_valid(_viewport):
		# Freeing the viewport frees the widget or status bar inside it.
		_viewport.queue_free()
		_viewport = null
	if is_instance_valid(widget) and widget.get_parent() == main:
		widget.queue_free()
	widget = null
	_status = null
	while State.get_activity() != null:
		State.finish_operation(State.get_activity().id)
	await get_tree().process_frame


func _cancel_callback() -> void:
	_cancel_count += 1


func _start(label: String, total: int, foreground: bool, cancellable: bool) -> int:
	if cancellable:
		return State.begin_operation(label, total, foreground, self, _cancel_callback)
	return State.begin_operation(label, total, foreground, self)


func _job_label() -> Label:
	return widget.get_node("Job/ActivityLabel")


func _job_progress() -> ProgressBar:
	return widget.get_node("Job/ActivityProgress")


func _job_cancel() -> Button:
	return widget.get_node("Cancel")


func _delete_cancel() -> void:
	step("Given a selected block larger than the inline erase limit", func():
		State.document = VoxelDocument.new()
		var cells := {}
		var material := VoxelFrame.material(Color.RED)
		for x in 32:
			for y in 16:
				for z in 16:
					var cell := Vector3i(x, y, z)
					cells[cell] = material
					State.selection.add(cell)
		State.get_current_voxel_frame().set_cells(cells)
		State.undo_redo.clear_history()
	)
	step("When the user requests deletion and presses its cancel button", func():
		State.erase_selection()
		expect(State.get_activity() != null and State.get_activity().can_cancel(), "deletion registers a cancel action")
		expect(_job_cancel().visible and not _job_cancel().disabled, "the widget exposes deletion cancellation")
		_job_cancel().button_down.emit()
		_job_cancel().pressed.emit()
	)
	while not State._erase_jobs.is_empty():
		await get_tree().process_frame
	step("Then deletion preserves the frame and selection without history", func():
		expect(State.get_current_voxel_frame().count() == 8192, "the cancelled deletion keeps every voxel")
		expect(State.selection.count() == 8192, "the cancelled deletion keeps the selection")
		expect(not State.edit_busy(), "the cancelled deletion releases editing")
		expect(not State.undo_redo.has_undo(), "the cancelled deletion adds no undo action")
	)
	State.document = VoxelDocument.new()


func _escape_target() -> void:
	step("Given a plain foreground job before a cancellable foreground job", func():
		_first_id = _start("Displayed job", 100, true, false)
		_second_id = _start("Waiting job", 100, true, true)
	)
	step("Then Escape leaves the undisplayed job running", func():
		expect(State.get_activity().id == _first_id, "the first foreground job is displayed")
		expect(not State.cancel_activity(), "the displayed plain job refuses cancellation")
		expect(_cancel_count == 0, "the undisplayed callback stays untouched")
	)
	step("When the first job finishes", func():
		State.finish_operation(_first_id)
	)
	step("Then Escape cancels the newly displayed job once", func():
		expect(State.get_activity().id == _second_id, "the waiting job is now displayed")
		expect(State.cancel_activity(), "the displayed cancellable job accepts cancellation")
		expect(State.cancel_activity(), "a repeat Escape is consumed while the cancellation is pending")
		expect(_cancel_count == 1, "the displayed callback runs once")
	)


func _determinate() -> void:
	step("Given a measured operation at twenty-five percent", func():
		var operation_id := _start("Filling", 100, true, false)
		State.update_operation(operation_id, 25, 100)
	)
	await get_tree().process_frame
	step("Then the widget shows the action and the percentage", func():
		expect(widget.visible, "the running operation is visible")
		expect(not _job_progress().indeterminate, "a measured operation uses percentage progress")
		expect(_job_progress().value == 25.0, "the progress bar shows twenty-five percent")
		expect(_job_label().text == "Filling · 25%", "the label shows the action and the percentage")
		expect(not _job_label().text.contains("…"), "a measured label shows no ellipsis")
	)


func _unknown() -> void:
	step("Given an operation with unknown work", func():
		_start("Building surfaces", -1, true, false)
	)
	await get_tree().process_frame
	step("Then the progress is indeterminate and the label ends with an ellipsis", func():
		expect(widget.visible, "the unknown operation is visible")
		expect(_job_progress().indeterminate, "unknown work uses animated progress")
		expect(_job_label().text == "Building surfaces…", "an unknown label ends with an ellipsis")
	)


func _detail() -> void:
	step("Given an operation with an internal detail line", func():
		var operation_id := _start("Filling", -1, true, false)
		State.update_operation(operation_id, 0, -1, "", "3 chunks remaining")
	)
	await get_tree().process_frame
	step("Then the display hides the detail and keeps the action", func():
		expect(_job_label().text == "Filling…", "the label shows the action with an ellipsis")
		expect(not _job_label().text.contains("3 chunks remaining"), "the label hides the internal detail")
		expect(not widget.tooltip_text.contains("3 chunks remaining"), "the tooltip hides the internal detail")
		expect(not widget.accessibility_name.contains("3 chunks remaining"), "the accessible name hides the internal detail")
	)


func _determinate_detail() -> void:
	step("Given a measured operation with an internal detail line", func():
		_operation_id = _start("Filling", 100, true, false)
		State.update_operation(_operation_id, 40, 100, "", "12 chunks remaining")
	)
	await get_tree().process_frame
	step("Then the label shows the percentage and hides the detail", func():
		expect(_job_label().text == "Filling · 40%", "the label keeps the action and the percentage")
		expect(not _job_label().text.contains("12 chunks remaining"), "the label hides the measured detail")
		expect(not widget.tooltip_text.contains("12 chunks remaining"), "the tooltip hides the measured detail")
	)


func _stable_identity() -> void:
	step("Given an operation whose worker reports several stages", func():
		_operation_id = _start("Filling", 100, true, false)
		State.update_operation(_operation_id, 10, 100, "Finding matching voxels")
		State.update_operation(_operation_id, 40, 100, "Applying fill")
	)
	await get_tree().process_frame
	step("Then the label keeps the begin action and the stage stays internal", func():
		expect(_job_label().text == "Filling · 40%", "the label keeps the begin action through stage changes")
		expect(State.get_activity().phase == "Applying fill", "the internal stage keeps the latest worker stage")
		expect(not widget.tooltip_text.contains("Applying fill"), "the tooltip hides the worker stage")
	)


func _cancellable() -> void:
	step("Given a cancellable operation", func():
		_start("Filling", 100, true, true)
	)
	await get_tree().process_frame
	step("Then the cancel button is shown and enabled", func():
		expect(_job_cancel().visible, "a cancellable operation shows the cancel button")
		expect(not _job_cancel().disabled, "the cancel button starts enabled")
		expect(_job_cancel().tooltip_text == CANCEL_TOOLTIP, "the cancel button names its action")
	)
	step("When the user clicks the cancel button", func():
		_job_cancel().button_down.emit()
		_job_cancel().pressed.emit()
	)
	await get_tree().process_frame
	step("Then the operation records one cancel request", func():
		expect(_cancel_count == 1, "the cancel callback runs once")
		expect(State.get_activity().cancel_requested, "the operation records the cancel request")
	)


func _plain() -> void:
	step("Given an operation without a cancel callback", func():
		_start("Building surfaces", -1, true, false)
	)
	await get_tree().process_frame
	step("Then the cancel button is hidden", func():
		expect(not _job_cancel().visible, "an operation without a callback hides the cancel button")
	)


func _pending() -> void:
	step("Given a cancellable operation", func():
		_operation_id = _start("Filling", 100, true, true)
	)
	await get_tree().process_frame
	step("When the operation requests cancellation", func():
		State.cancel_operation(_operation_id)
	)
	await get_tree().process_frame
	step("Then the display shows Cancelling until cleanup", func():
		expect(_job_cancel().visible, "the pending job keeps its cancel button")
		expect(_job_cancel().disabled, "the pending cancellation disables the button")
		expect(_job_cancel().tooltip_text == "Cancelling…", "the pending button tooltip names the cancellation")
		expect(widget.visible, "the pending job stays visible until it finishes")
		expect(_job_label().text == "Cancelling…", "the pending label shows Cancelling")
		expect(widget.tooltip_text == "Cancelling…", "the pending tooltip shows Cancelling")
		expect(widget.accessibility_name == "Cancelling…", "the pending accessible name shows Cancelling")
	)


func _foreground_first() -> void:
	step("Given a background operation", func():
		_start("Building surfaces", -1, false, false)
	)
	step("When a foreground operation starts", func():
		_start("Filling", 10, true, false)
	)
	await get_tree().process_frame
	step("Then the widget shows the foreground operation", func():
		expect(_job_label().text.contains("Filling"), "the foreground operation owns the label")
	)


func _completion() -> void:
	step("Given a running operation", func():
		_operation_id = _start("Filling", 10, true, false)
	)
	await get_tree().process_frame
	step("Then the widget shows it", func():
		expect(widget.visible, "the running operation is visible")
	)
	step("When the operation finishes", func():
		State.finish_operation(_operation_id)
	)
	await get_tree().process_frame
	step("Then the widget hides", func():
		expect(not widget.visible, "a finished operation hides the display")
	)


func _stale_target() -> void:
	step("Given a cancellable operation", func():
		_first_id = _start("First", 10, true, true)
	)
	await get_tree().process_frame
	step("When the user presses the cancel button", func():
		_job_cancel().button_down.emit()
	)
	step("And the shown operation is replaced before the release", func():
		State.finish_operation(_first_id)
		_second_id = _start("Second", 10, true, true)
	)
	await get_tree().process_frame
	step("Then the release cancels nothing", func():
		_job_cancel().pressed.emit()
		expect(_cancel_count == 0, "a stale press cannot cancel the replacement operation")
		expect(not State.get_activity().cancel_requested, "the replacement operation stays active")
	)


func _stale_mouse() -> void:
	step("Given a widget in a sized viewport with a cancellable operation", func():
		_first_id = _start("First", 10, true, true)
		# The headless window is tiny, so a real GUI hit test needs its own sized
		# viewport for the widget.
		_viewport = SubViewport.new()
		_viewport.size = Vector2i(360, 40)
		_viewport.gui_disable_input = false
		main.add_child(_viewport)
		main.remove_child(widget)
		_viewport.add_child(widget)
		widget.size = Vector2(360, 40)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("When the user presses the cancel button", func():
		_button(_job_cancel().get_global_rect().get_center(), true)
	)
	step("And the shown operation is replaced before the release", func():
		State.finish_operation(_first_id)
		_second_id = _start("Second", 10, true, true)
	)
	await get_tree().process_frame
	step("Then the release cancels nothing", func():
		_button(_job_cancel().get_global_rect().get_center(), false)
		expect(_cancel_count == 0, "a real stale press cannot cancel the replacement operation")
		expect(not State.get_activity().cancel_requested, "the replacement operation stays active")
	)


func _repeat_click() -> void:
	step("Given a cancellable operation", func():
		_start("Filling", 10, true, true)
	)
	await get_tree().process_frame
	step("When the user cancels twice", func():
		_job_cancel().button_down.emit()
		_job_cancel().pressed.emit()
		_job_cancel().button_down.emit()
		_job_cancel().pressed.emit()
	)
	await get_tree().process_frame
	step("Then the callback runs once", func():
		expect(_cancel_count == 1, "a repeated click cancels once")
	)


func _keyboard() -> void:
	step("Given a cancellable operation", func():
		_start("Filling", 10, true, true)
	)
	await get_tree().process_frame
	step("Then the cancel button accepts keyboard focus", func():
		expect(_job_cancel().focus_mode != Control.FOCUS_NONE, "the cancel button keeps keyboard focus")
		_job_cancel().grab_focus()
	)
	await get_tree().process_frame
	step("When the user presses Enter on the focused button", func():
		expect(_job_cancel().has_focus(), "the cancel button holds focus")
		_key(KEY_ENTER)
	)
	await get_tree().process_frame
	step("Then the operation is cancelled", func():
		expect(_cancel_count == 1, "keyboard activation cancels the operation")
	)


func _mouse() -> void:
	step("Given a widget in a sized viewport with a cancellable operation", func():
		_start("Filling", 10, true, true)
		# The headless window is tiny, so a real GUI hit test needs its own sized
		# viewport for the widget.
		_viewport = SubViewport.new()
		_viewport.size = Vector2i(360, 40)
		_viewport.gui_disable_input = false
		main.add_child(_viewport)
		main.remove_child(widget)
		_viewport.add_child(widget)
		widget.size = Vector2(360, 40)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("When the user presses and releases on the cancel button", func():
		var center := _job_cancel().get_global_rect().get_center()
		expect(_job_cancel().size.x > 0.0, "the cancel button has a laid-out rectangle")
		_button(center, true)
		_button(center, false)
	)
	await get_tree().process_frame
	step("Then the operation is cancelled", func():
		expect(_cancel_count == 1, "a real mouse press and release cancels the operation")
	)


func _fill_behind_label() -> void:
	step("Given a measured operation", func():
		var operation_id := _start("Filling", 100, true, false)
		State.update_operation(operation_id, 40, 100)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the fill sits behind the visible label", func():
		var job: Control = widget.get_node("Job")
		expect(job.get_child(0) == _job_progress(), "the fill is the first overlay child")
		expect(job.get_child(1) == _job_label(), "the label draws after the fill")
		expect(_job_label().visible, "the label stays visible over the fill")
		expect(_job_label().text.contains("40%"), "the label keeps its percentage")
		expect(_job_progress().mouse_filter == Control.MOUSE_FILTER_IGNORE, "the fill ignores the mouse")
		expect(_job_label().mouse_filter == Control.MOUSE_FILTER_IGNORE, "the label ignores the mouse")
		expect(_job_label().get_global_rect().size.x > 0.0, "the label has a laid-out rectangle")
		expect(_job_progress().get_global_rect().intersects(_job_label().get_global_rect()), "the fill and the label share the row")
	)


func _reentry() -> void:
	step("Given a cancellable operation", func():
		_start("Filling", 10, true, true)
	)
	await get_tree().process_frame
	step("When the widget leaves and re-enters the tree", func():
		main.remove_child(widget)
		main.add_child(widget)
	)
	await get_tree().process_frame
	step("Then it still shows the operation", func():
		expect(widget.visible, "the re-entered widget shows the operation")
		expect(_job_label().text.contains("Filling"), "the re-entered widget keeps the label")
		expect(_activity_subscriptions() == 1, "the widget keeps one activity subscription")
	)
	step("And a click still cancels once", func():
		_job_cancel().button_down.emit()
		_job_cancel().pressed.emit()
		expect(_cancel_count == 1, "the re-entered widget cancels exactly once")
	)


func _activity_subscriptions() -> int:
	var count := 0
	for connection in State.activity_changed.get_connections():
		if connection["callable"].get_object() == widget:
			count += 1
	return count


func _long_label() -> void:
	var full_text := "%s · 40%%" % LONG_LABEL
	var unknown_text := "%s…" % LONG_LABEL
	step("Given a status bar in a narrow viewport with a long operation", func():
		_viewport = SubViewport.new()
		_viewport.size = Vector2i(520, 40)
		_viewport.gui_disable_input = false
		main.add_child(_viewport)
		_status = load("res://ui/StatusBar/status_bar.tscn").instantiate()
		_viewport.add_child(_status)
		_status.size = Vector2(520, 40)
		# Show the operation at once, so the geometry is ready without the delay.
		_status.get_node("Activity").delay_ms = 0
		_operation_id = _start(LONG_LABEL, 100, true, true)
		State.update_operation(_operation_id, 40, 100, "", LONG_DETAIL)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the right status stays inside the narrow bar", func():
		var right: Label = _status.get_node("StatusRight")
		var scale: OptionButton = _status.get_node("%UIScale")
		expect(right.get_global_rect().end.x <= 520.5, "the right status stays inside the narrow bar")
		expect(scale.get_global_rect().end.x <= 520.5, "the UI scale stays inside the narrow bar")
		expect(right.get_global_rect().size.x > 0.0, "the right status keeps a visible size")
	)
	step("Then the long job caps its width and trims the text", func():
		var job: Control = _status.get_node("Activity/Job")
		var label: Label = _status.get_node("Activity/Job/ActivityLabel")
		expect(job.custom_maximum_size.x <= JobStatusWidget.MAX_CONTENT_WIDTH + 0.5, "the long job caps its width")
		expect(job.custom_maximum_size.x > JobStatusWidget.MIN_CONTENT_WIDTH, "the cap is above the small minimum")
		expect(job.size.x <= job.custom_maximum_size.x + 1.0, "the long job stays within its cap")
		expect(label.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING, "the long label trims with an ellipsis")
		expect(label.get_global_rect().end.x <= job.get_global_rect().end.x + 0.5, "the label stays inside the job row")
		expect(label.text == full_text, "the label keeps the full operation text before trimming")
	)
	step("Then the full text stays on the tooltip", func():
		expect(_status.get_node("Activity").tooltip_text == full_text, "the tooltip keeps the full operation text")
	)
	step("When the operation switches to unknown work with the same detail", func():
		State.update_operation(_operation_id, 0, -1, "Applying fill", LONG_DETAIL)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the unknown text stays complete and capped", func():
		var job: Control = _status.get_node("Activity/Job")
		var label: Label = _status.get_node("Activity/Job/ActivityLabel")
		expect(label.text == unknown_text, "the label keeps the unknown text before trimming")
		expect(_status.get_node("Activity").tooltip_text == unknown_text, "the tooltip keeps the unknown detail")
		expect(job.custom_maximum_size.x <= JobStatusWidget.MAX_CONTENT_WIDTH + 0.5, "the unknown job keeps the cap")
	)
	step("Then the cancel button stays inside the narrow bar", func():
		var cancel: Button = _status.get_node("Activity/Cancel")
		expect(cancel.visible, "the narrow bar keeps the cancel button")
		expect(cancel.get_global_rect().end.x <= 520.5, "the cancel button stays inside the narrow bar")
	)
	step("When the bar widens to the default window", func():
		_viewport.size = Vector2i(1000, 40)
		_status.size = Vector2(1000, 40)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the long job reaches its cap and the right status stays inside", func():
		var job: Control = _status.get_node("Activity/Job")
		var right: Label = _status.get_node("StatusRight")
		expect(job.custom_maximum_size.x <= JobStatusWidget.MAX_CONTENT_WIDTH + 0.5, "the wide bar caps the long job")
		expect(job.size.x <= job.custom_maximum_size.x + 1.0, "the long job stays within its cap")
		expect(job.size.x > 200.0, "the long job uses the available width")
		expect(right.get_global_rect().end.x <= 1000.5, "the right status stays inside the wide bar")
	)
	step("When the user clicks the cancel button", func():
		var cancel: Button = _status.get_node("Activity/Cancel")
		var center := cancel.get_global_rect().get_center()
		_button(center, true)
		_button(center, false)
	)
	await get_tree().process_frame
	step("Then the narrow bar cancels through the button", func():
		expect(_cancel_count == 1, "the narrow bar cancels through the button")
	)


func _short_label() -> void:
	step("Given a status bar with a short operation", func():
		_viewport = SubViewport.new()
		_viewport.size = Vector2i(1000, 40)
		_viewport.gui_disable_input = false
		main.add_child(_viewport)
		_status = load("res://ui/StatusBar/status_bar.tscn").instantiate()
		_viewport.add_child(_status)
		_status.size = Vector2(1000, 40)
		_status.get_node("Activity").delay_ms = 0
		_operation_id = _start("Go", 100, true, false)
		State.update_operation(_operation_id, 50, 100)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the short job stays compact", func():
		var activity: Control = _status.get_node("Activity")
		var job: Control = _status.get_node("Activity/Job")
		var label: Label = _status.get_node("Activity/Job/ActivityLabel")
		var font: Font = label.get_theme_font("font")
		var font_size := label.get_theme_font_size("font_size")
		var wanted := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		expect(label.text == "Go · 50%", "the short label shows the action and the percentage")
		expect(activity.size.x < 100.0, "a short job stays under one hundred pixels")
		expect(job.size.x < 100.0, "the short job content stays under one hundred pixels")
		expect(job.size.x < JobStatusWidget.MAX_CONTENT_WIDTH, "the short job stays under the maximum")
		expect(job.custom_maximum_size.x < 100.0, "the short job keeps a natural maximum")
		expect(label.size.x >= wanted.x, "a short label fits without trimming")
		_short_width = job.size.x
	)
	step("When a longer operation replaces it", func():
		State.finish_operation(_operation_id)
		_operation_id = _start("Going farther", 100, true, false)
		State.update_operation(_operation_id, 50, 100)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the natural width follows the text", func():
		var job: Control = _status.get_node("Activity/Job")
		expect(job.size.x > _short_width, "a longer short label grows the natural width")
		expect(job.size.x < 200.0, "the longer short label stays compact")
		expect(job.size.x <= job.custom_maximum_size.x + 1.0, "the natural width respects its maximum")
	)
	step("When the short operation is cancellable", func():
		State.finish_operation(_operation_id)
		_operation_id = _start("Go", 100, true, true)
		State.update_operation(_operation_id, 50, 100)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the cancel button adds only its own width", func():
		var activity: Control = _status.get_node("Activity")
		var job: Control = _status.get_node("Activity/Job")
		expect(activity.size.x > job.size.x, "the cancel button adds its own width")
		expect(activity.size.x < 140.0, "a short cancellable job stays compact")
		_short_width = activity.size.x
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the compact width does not oscillate", func():
		expect(is_equal_approx(_status.get_node("Activity").size.x, _short_width), "the natural width is stable")
	)


func _reentry_delay() -> void:
	step("Given a widget with the default display delay", func():
		widget.delay_ms = 200
		_start("Filling", 100, true, false)
	)
	await get_tree().process_frame
	step("When the widget leaves and re-enters while the delay runs", func():
		expect(not widget.visible, "the display delay hides the young operation")
		main.remove_child(widget)
		main.add_child(widget)
	)
	await get_tree().process_frame
	step("Then the operation stays hidden after the re-entry", func():
		expect(not widget.visible, "the re-entered widget does not show the operation early")
	)
	await get_tree().create_timer(0.3).timeout
	await get_tree().process_frame
	step("Then the operation appears after the delay", func():
		expect(widget.visible, "the re-entered widget shows the operation after the delay")
	)


func _button(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.position = position
	event.global_position = position
	if _viewport != null:
		# The event position is already in the subviewport's coordinates.
		_viewport.push_input(event, true)
	else:
		get_tree().root.push_input(event)


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	get_tree().root.push_input(event)
	event = InputEventKey.new()
	event.keycode = code
	event.pressed = false
	get_tree().root.push_input(event)
