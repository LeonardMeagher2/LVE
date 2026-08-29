extends HBoxContainer

@export var option: ToolOption
@export var group := ""


func _ready() -> void:
	if option == null:
		return
	var btn_group := ButtonGroup.new()
	for btn in get_children():
		if not (btn is Button):
			continue
		if btn.name == "clear":
			btn.pressed.connect(_on_clear)
			continue
		btn.button_group = btn_group
		btn.button_pressed = State.get_tool_option(State.tool, option.id) == btn.name
		#btn.pressed.connect(_on_pressed.bind(btn.name))
	#State.tool_option_changed.connect(_on_option_changed)
	State.selection_changed.connect(_sync_clear)
	_sync_clear()


#func _on_option_changed(changed_group: String, id: String, value: Variant) -> void:
	#if changed_group != group or id != option.id:
		#return
	#for btn in get_children():
		#if btn is Button and btn.name != "clear":
			#(btn as Button).button_pressed = btn.name == value
#
#
#func _on_pressed(value: String) -> void:
	#State.set_tool_option(group, option.id, value)


func _on_clear() -> void:
	State.clear_selection()


func _sync_clear() -> void:
	var clear := get_node_or_null("clear")
	if clear is Button:
		(clear as Button).disabled = State.selection.is_empty()
