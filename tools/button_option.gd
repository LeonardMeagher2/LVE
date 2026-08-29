extends HBoxContainer

@export var option: ToolOption
@export var group := ""

@onready var _button: Button = $Button


func _ready() -> void:
	if option == null:
		return
	_button.tooltip_text = option.label.capitalize()
	_button.pressed.connect(_on_pressed)


func _on_pressed() -> void:
	State.set_tool_option(group, option.id, null)
