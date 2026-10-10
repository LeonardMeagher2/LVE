extends ToolMenuButton

var _settings := preload("./settings.tres")

func _ready() -> void:
	get_popup().index_pressed.connect(_on_index_pressed)
	
func _on_index_pressed(index: int) -> void:
	var item_text = get_popup().get_item_text(index).to_upper()
	var item_icon = get_popup().get_item_icon(index)
	assert(_settings.Tools.has(item_text))
	_settings.tool = _settings.Tools[item_text]
	icon = item_icon
	button_pressed = true


func _shortcut_input(event: InputEvent) -> void:
	if disabled or not is_visible_in_tree() or event.is_echo():
		return
	for binding in [
		[&"tool_select", _settings.Tools.BOX],
		[&"tool_wand", _settings.Tools.WAND],
		[&"tool_lasso", _settings.Tools.LASSO],
	]:
		if event.is_action_pressed(binding[0], false, true):
			_on_index_pressed(binding[1])
			accept_event()
			return
	super._shortcut_input(event)