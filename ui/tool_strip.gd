class_name EditorToolStrip
extends VBoxContainer

@onready var button_template = $Button
@onready var menu_button_template = $MenuButton

func _ready() -> void:
	remove_child(button_template)
	remove_child(menu_button_template)
	_build_tool_buttons()

func _build_tool_buttons() -> void:
	var groups: Dictionary[String, int] = {}
	for tool_name in State.tools:
		var info: ToolInfo = State.tools[tool_name]
		if not info.group:
			continue
		groups[info.group] = groups.get(info.group, 0) + 1
			
	for tool_name in State.tools:
		var info: ToolInfo = State.tools[tool_name]
		var button_name = info.group if info.group else tool_name
		var button = get_node_or_null(button_name)
		
		if not button:
			if groups.has(info.group):
				button = menu_button_template.duplicate()
				button.get_popup().index_pressed.connect(_tool_menu_item_selected.bind(button))
			else:
				button = button_template.duplicate()
				button.toggled.connect(_tool_selected.bind(button, tool_name))
			button.name = button_name
			button.icon = info.icon
			button.tooltip_text = info.tooltip
			button.button_pressed = get_child_count() == 0
			add_child(button)
		
		if groups.has(info.group):
			var popup = button.get_popup()
			var index = popup.item_count
			popup.add_icon_item(info.icon, info.display_name)
			popup.set_item_metadata(index, tool_name)
			

func _tool_selected(toggled_on:bool, button:Button, tool_name:String) -> void:
	if toggled_on:
		button.button_pressed = true
		var info: ToolInfo = State.tools[tool_name]
		State.set_tool(info)

func _tool_menu_item_selected(index:int, button:MenuButton) -> void:
	var popup:PopupMenu = button.get_popup()
	var tool_name:String = popup.get_item_metadata(index)
	var info: ToolInfo = State.tools[tool_name]
	button.icon = info.icon
	button.tooltip_text = info.tooltip
	button.button_pressed = true
	State.set_tool(info)
