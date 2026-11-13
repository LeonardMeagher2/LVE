extends ToolMenuButton

## The terrain tool menu button.
##
## It selects a terrain tool and shows that tool's icon.

# The popup item id of each terrain tool. The ids stay fixed, so a menu item and
# its icon select the same tool even when the enum changes.
const BUILD_ID := 0
const FLATTEN_ID := 1
const SMOOTH_ID := 2

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
		FLATTEN_ID:
			return _settings.Tools.FLATTEN
		SMOOTH_ID:
			return _settings.Tools.SMOOTH
	return _settings.Tools.BUILD
