extends ToolMenuButton

var _settings := preload("./settings.tres")

func _ready() -> void:
	get_popup().index_pressed.connect(_on_index_pressed)
	
func _on_index_pressed(index: int) -> void:
	var item_text = get_popup().get_item_text(index).to_upper()
	var item_icon = get_popup().get_item_icon(index)
	assert(_settings.BrushMode.has(item_text))
	_settings.mode = _settings.BrushMode[item_text]
	icon = item_icon
	button_pressed = true


func _shortcut_input(event: InputEvent) -> void:
	if not disabled and is_visible_in_tree() and event.is_action_pressed("tool_eraser") and not event.is_echo():
		_on_index_pressed(_settings.BrushMode.ERASER)
		accept_event()
		return
	super._shortcut_input(event)
