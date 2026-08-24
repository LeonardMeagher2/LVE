class_name OptionBar
extends HBoxContainer

signal view_requested(name: String)

@onready var _options_box: HBoxContainer = $OptionsBox
@onready var _view_menu: MenuButton = $View

var _entries: Array[Dictionary] = []


func _ready() -> void:
	State.tool_changed.connect(func(_t): _rebuild())
	State.tool_option_changed.connect(_sync_values)
	_view_menu.get_popup().id_pressed.connect(_on_view_selected)
	_rebuild()


func _rebuild() -> void:
	for c in _options_box.get_children():
		_options_box.remove_child(c)
		c.queue_free()
	_entries.clear()
	if State.tool == null:
		return
	var group: String = State.tool.group
	for opt in State.tool.options:
		if opt.option_scene != "":
			var w: Control = load(opt.option_scene).instantiate()
			w.option = opt
			w.group = group
			_options_box.add_child(w)
		else:
			_add_toggle(opt, group)


func _add_toggle(opt: ToolOption, group: String) -> void:
	var cb := CheckButton.new()
	cb.text = opt.label.capitalize()
	cb.focus_mode = Control.FOCUS_NONE
	var on: bool = State.get_tool_option(State.tool, opt.id)
	cb.button_pressed = on
	cb.toggled.connect(func(v: bool): State.set_tool_option(group, opt.id, v))
	_options_box.add_child(cb)
	_entries.append({"button": cb, "group": group, "id": opt.id, "value": true})


func _sync_values(group: String, id: String, value: Variant) -> void:
	for e in _entries:
		if e.group == group and e.id == id:
			(e.button as BaseButton).button_pressed = e.value == value


func _on_view_selected(index: int) -> void:
	match index:
		0: view_requested.emit("top")
		1: view_requested.emit("front")
		2: view_requested.emit("side")
		3: view_requested.emit("isometric")
		4: view_requested.emit("reset")
