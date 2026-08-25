extends HBoxContainer

@export var option: ToolOption
@export var group := ""

@onready var _icon: TextureRect = $Icon
@onready var _spin: SpinBox = $Spin


func _ready() -> void:
	if option == null:
		return
	var tip := option.label.capitalize()
	_icon.tooltip_text = tip
	_spin.tooltip_text = tip
	_spin.value = State.get_tool_option(State.tool, option.id) * _spin.max_value
	_spin.value_changed.connect(_on_value_changed)
	State.tool_option_changed.connect(_on_option_changed)


func _on_value_changed(v: float) -> void:
	State.set_tool_option(group, option.id, v / _spin.max_value)


func _on_option_changed(changed_group: String, id: String, value: Variant) -> void:
	if changed_group != group or id != option.id:
		return
	_spin.value = value
