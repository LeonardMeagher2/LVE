class_name EditorToolBar
extends HBoxContainer

var _tool_buttons: Array[Button] = []
var _button_members := {}
var _menu := PopupMenu.new()
var _press_timer: Timer
var _pressed_button: Button = null
var _long_pressed := false
var _menu_members: Array[ToolInfo] = []

@onready var _tool_buttons_box: HBoxContainer = $ToolButtons
@onready var _color_picker: ColorPickerButton = $ColorPicker
@onready var _recent_box: HBoxContainer = $RecentColors
@onready var _pixel_perfect: CheckButton = $PixelPerfect


func _ready() -> void:
	State.tool_changed.connect(_on_tool_changed)
	State.color_changed.connect(_on_color_changed)
	State.pixel_perfect_changed.connect(_on_pixel_perfect_changed)
	_pixel_perfect.button_pressed = State.pixel_perfect
	_color_picker.color = State.current_color
	_press_timer = Timer.new()
	_press_timer.wait_time = 0.5
	_press_timer.one_shot = true
	_press_timer.timeout.connect(_on_press_timeout)
	add_child(_press_timer)
	_menu.id_pressed.connect(_on_menu_selected)
	add_child(_menu)
	_build_tool_buttons()
	_update_tool_buttons()
	_update_recent()


func _build_tool_buttons() -> void:
	var grouped := {}
	for name in State.tools:
		var info: ToolInfo = State.tools[name]
		if info.group != "":
			if grouped.has(info.group):
				continue
			grouped[info.group] = true
		var members := _members_of(info)
		var b := Button.new()
		b.text = info.display_name
		b.custom_minimum_size = Vector2(56, 28)
		b.focus_mode = Control.FOCUS_NONE
		b.toggle_mode = true
		b.tooltip_text = info.tooltip
		if info.icon != null:
			b.icon = info.icon
		_button_members[b] = members
		b.button_down.connect(_on_button_down.bind(b))
		b.button_up.connect(_on_button_up.bind(b))
		_tool_buttons_box.add_child(b)
		_tool_buttons.append(b)


func _members_of(info: ToolInfo) -> Array:
	if info.group == "":
		return [info]
	var members: Array = []
	for name in State.tools:
		var m: ToolInfo = State.tools[name]
		if m.group == info.group:
			members.append(m)
	return members


func _active_member(members: Array) -> ToolInfo:
	for m in members:
		if m == State.tool:
			return m
	return members[0]


func _on_button_down(b: Button) -> void:
	_pressed_button = b
	_long_pressed = false
	_press_timer.start()


func _on_button_up(b: Button) -> void:
	_press_timer.stop()
	if _long_pressed:
		return
	_select_tool(_active_member(_button_members[b]))


func _on_press_timeout() -> void:
	if _pressed_button == null:
		return
	_long_pressed = true
	_open_menu(_pressed_button)


func _open_menu(b: Button) -> void:
	var members: Array = _button_members[b]
	_menu.clear()
	_menu_members = []
	var active := _active_member(members)
	for i in members.size():
		var m: ToolInfo = members[i]
		if m.icon != null:
			_menu.add_icon_check_item(m.icon, m.display_name, i)
		else:
			_menu.add_check_item(m.display_name, i)
		_menu.set_item_checked(i, m == active)
		_menu_members.append(m)
	_menu.position = Vector2i(b.global_position + b.size)
	_menu.popup()


func _on_menu_selected(id: int) -> void:
	if id >= 0 and id < _menu_members.size():
		_select_tool(_menu_members[id])


func _select_tool(info: ToolInfo) -> void:
	State.set_tool(info)


func _on_tool_changed(_t: ToolInfo) -> void:
	_update_tool_buttons()


func _update_tool_buttons() -> void:
	for b in _tool_buttons:
		var members: Array = _button_members[b]
		var active := _active_member(members)
		b.button_pressed = (active == State.tool)
		if members.size() > 1:
			b.text = active.display_name
			if active.icon != null:
				b.icon = active.icon


func _on_color_picked(c: Color) -> void:
	State.set_color(c)


func _on_color_changed(_c: Color) -> void:
	_color_picker.color = State.current_color
	_update_recent()


func _on_pixel_perfect_toggled(v: bool) -> void:
	State.set_pixel_perfect(v)


func _on_pixel_perfect_changed(v: bool) -> void:
	_pixel_perfect.button_pressed = v


func _update_recent() -> void:
	for child in _recent_box.get_children():
		child.queue_free()
	for c in State.recents.colors:
		var b := Button.new()
		b.custom_minimum_size = Vector2(22, 22)
		b.focus_mode = Control.FOCUS_NONE
		var sb := StyleBoxFlat.new()
		sb.bg_color = c
		sb.set_corner_radius_all(3)
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("pressed", sb)
		b.pressed.connect(_pick_recent.bind(c))
		_recent_box.add_child(b)


func _pick_recent(c: Color) -> void:
	State.set_color(c)
