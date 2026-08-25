class_name OptionBar
extends HBoxContainer

@onready var _options_box: HBoxContainer = $OptionsBox


func _ready() -> void:
	State.tool_changed.connect(func(_t): _rebuild())
	_rebuild()


func _rebuild() -> void:
	for c in _options_box.get_children():
		_options_box.remove_child(c)
		c.queue_free()
	if State.tool == null:
		return
	var group: String = State.tool.group
	for opt in State.tool.options:
		if opt.option_scene == "":
			push_warning("OptionBar: option '%s' has no option_scene" % opt.id)
			continue
		var w: Control = load(opt.option_scene).instantiate()
		w.option = opt
		w.group = group
		_options_box.add_child(w)
