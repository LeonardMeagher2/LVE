extends ToolMenuButton

## The brush tool menu button.
##
## It selects a brush mode and shows that mode's icon. The brush mode shortcuts
## select a mode too.

# The popup item id of each brush mode. The ids stay fixed, so a menu item and
# its shortcut select the same mode even when the enum changes.
const PENCIL_ID := 0
const LINE_ID := 1
const ERASER_ID := 2

var _settings := preload("./settings.tres")

func _ready() -> void:
	get_popup().index_pressed.connect(_on_index_pressed)

func _on_index_pressed(index: int) -> void:
	_select_id(get_popup().get_item_id(index))


# Select one mode by its popup item id. The icon comes from the matching item,
# so the button shows the active mode.
func _select_id(id: int) -> void:
	var item_index := get_popup().get_item_index(id)
	if item_index < 0:
		return
	_settings.mode = _mode_for_id(id)
	icon = get_popup().get_item_icon(item_index)
	button_pressed = true


func _mode_for_id(id: int) -> int:
	match id:
		LINE_ID:
			return _settings.BrushMode.LINE
		ERASER_ID:
			return _settings.BrushMode.ERASER
	return _settings.BrushMode.PENCIL


func _shortcut_input(event: InputEvent) -> void:
	if disabled or not is_visible_in_tree() or event.is_echo():
		return
	for binding in [
		[&"tool_pencil", PENCIL_ID],
		[&"tool_line", LINE_ID],
		[&"tool_eraser", ERASER_ID],
	]:
		if event.is_action_pressed(binding[0], false, true):
			_select_id(binding[1])
			accept_event()
			return
	super._shortcut_input(event)
