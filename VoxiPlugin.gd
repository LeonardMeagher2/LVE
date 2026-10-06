class_name VoxiPlugin extends Node

func _safe_add(parent:Node, child:Node) -> void:
	if child.get_parent():
		child.reparent(parent)
		return
	parent.add_child(child)
	
func _safe_remove(parent:Node, child:Node) -> void:
	if not child.get_parent() == parent:
		return
	parent.remove_child(child)

func add_menu_bar_item(control:Control) -> void:
	var menu_bar := get_node("/root/Main").get_node("%MenuBar")
	_safe_add(menu_bar, control)
	var separator_index := menu_bar.get_node("Sep1").get_index()
	if control.get_index() < separator_index:
		separator_index -= 1
	menu_bar.move_child(control, separator_index)

func remove_menu_bar_item(control:Control) -> void:
	_safe_remove(get_node("/root/Main").get_node("%MenuBar"), control)

func add_tab(control: Control) -> void:
	var tabs: TabContainer = get_node("/root/Main").get_node("%TabContainer")
	_safe_add(tabs, control)
	control.process_mode = Node.PROCESS_MODE_INHERIT if tabs.get_current_tab_control() == control else Node.PROCESS_MODE_DISABLED

func remove_tab(control: Control) -> void:
	var main := get_node_or_null("/root/Main")
	if main == null:
		return
	var tabs: TabContainer = main.get_node("%TabContainer")
	if tabs.get_current_tab_control() == control:
		show_editor_tab()
	_safe_remove(tabs, control)

func show_tab(control: Control) -> void:
	var tabs: TabContainer = get_node("/root/Main").get_node("%TabContainer")
	if control.get_parent() == tabs:
		tabs.current_tab = tabs.get_tab_idx_from_control(control)

func show_editor_tab() -> void:
	show_tab(get_node("/root/Main").get_node("%Editor"))

func add_option_bar_item(control: Control) -> void:
	_safe_add(get_node("/root/Main").get_node("%OptionBar"), control)

func remove_option_bar_item(control: Control) -> void:
	_safe_remove(get_node("/root/Main").get_node("%OptionBar"), control)

func add_control_bar_item(control:Control) -> void:
	_safe_add(get_node("/root/Main").get_node("%Viewport").get_node("%ControlBar"), control)

func remove_control_bar_item(control:Control) -> void:
	_safe_remove(get_node("/root/Main").get_node("%Viewport").get_node("%ControlBar"), control)

func add_tool_bar_item(control:Control) -> void:
	_safe_add(get_node("/root/Main").get_node("%ToolBar"), control)

func remove_tool_bar_item(control:Control) -> void:
	_safe_remove(get_node("/root/Main").get_node("%ToolBar"), control)

func add_editor_node(node:Node3D) -> void:
	_safe_add(get_node("/root/Main").get_node("%Viewport").get_node("%ViewportScene"), node)
	
func remove_editor_node(node:Node3D) -> void:
	_safe_remove(get_node("/root/Main").get_node("%Viewport").get_node("%ViewportScene"), node)
	
