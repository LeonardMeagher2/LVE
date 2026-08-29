extends HBoxContainer

@export var option: ToolOption
@export var group := ""

@onready var _button: Button = $Button


func _ready() -> void:
	if option == null:
		return
	_button.tooltip_text = option.label.capitalize()
	_button.button_pressed = State.get_tool_option(State.tool, option.id) == true
	_button.toggled.connect(_on_toggled)
	State.tool_option_changed.connect(_on_option_changed)


#func _on_toggled(v: bool) -> void:
	#State.set_tool_option(group, option.id, v)


func _on_option_changed(changed_group: String, id: String, value: Variant) -> void:
	if changed_group != group or id != option.id:
		return
	_button.button_pressed = value == true
