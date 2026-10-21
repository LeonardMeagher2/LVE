extends ToolMenuButton

## The paint tool menu button.
##
## It selects a paint tool and shows that tool's icon. The paint tool shortcuts
## select a tool too.

# The popup item id of each paint tool. The ids stay fixed, so a menu item and
# its shortcut select the same tool even when the enum changes.
const PAINTBRUSH_ID := 0
const FILL_ID := 1
const SPRAY_ID := 2

var _settings := preload("./settings.tres")

func _ready() -> void:
	get_popup().index_pressed.connect(_on_index_pressed)

func _on_index_pressed(index: int) -> void:
	_select_id(get_popup().get_item_id(index))


# Select one tool by its popup item id. The icon comes from the matching item,
# so the button shows the active tool.
func _select_id(id: int) -> void:
	var item_index := get_popup().get_item_index(id)
	if item_index < 0:
		return
	_settings.tool = _tool_for_id(id)
	icon = get_popup().get_item_icon(item_index)
	button_pressed = true


func _tool_for_id(id: int) -> int:
	match id:
		FILL_ID:
			return _settings.Tools.FILL
		SPRAY_ID:
			return _settings.Tools.SPRAY
	return _settings.Tools.PAINTBRUSH


func _shortcut_input(event: InputEvent) -> void:
	if disabled or not is_visible_in_tree() or event.is_echo():
		return
	for binding in [
		[&"tool_paint", PAINTBRUSH_ID],
		[&"tool_fill", FILL_ID],
		[&"tool_spray", SPRAY_ID],
	]:
		if event.is_action_pressed(binding[0], false, true):
			_select_id(binding[1])
			accept_event()
			return
	super._shortcut_input(event)
