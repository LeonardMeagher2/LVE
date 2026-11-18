extends ToolMenuButton

## The primitive tool menu button.
##
## It selects the Box, Ellipsoid, or Cylinder tool and shows that tool's icon.

var _settings := preload("./PrimitiveSettings.tres")


func _ready() -> void:
	get_popup().index_pressed.connect(_on_index_pressed)
	_settings.tool_changed.connect(_sync_icon)
	_sync_icon(_settings.tool)


func _on_index_pressed(index: int) -> void:
	var item_text: String = get_popup().get_item_text(index).to_upper()
	var item_icon: Texture2D = get_popup().get_item_icon(index)
	assert(_settings.Tools.has(item_text))
	_settings.tool = _settings.Tools[item_text]
	icon = item_icon
	button_pressed = true


func _sync_icon(tool: int) -> void:
	var item_index := get_popup().get_item_index(tool)
	if item_index >= 0:
		icon = get_popup().get_item_icon(item_index)
