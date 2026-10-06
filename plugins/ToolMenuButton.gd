class_name ToolMenuButton
extends MenuButton

func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		_select_or_open()
		accept_event()
		return
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_select_or_open()
		accept_event()

func _shortcut_input(event: InputEvent) -> void:
	if disabled or not is_visible_in_tree() or event.is_echo() or not event.is_pressed() \
			or shortcut == null or not shortcut.matches_event(event):
		return
	_select_or_open()
	accept_event()

func _select_or_open() -> void:
	if button_pressed:
		show_popup()
	else:
		button_pressed = true

func _on_popup_hide() -> void:
	if not button_pressed:
		button_pressed = true
		
func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		get_popup().popup_hide.connect(_on_popup_hide)
