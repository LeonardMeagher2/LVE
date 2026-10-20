class_name VoxelPlugin extends Node

## Base class for an editor plugin.
##
## A plugin adds its controls to the main scene and its tool node to the
## viewport. It registers the controls through the helpers in this class.

func _safe_add(parent:Node, child:Node) -> void:
	if child.get_parent():
		child.reparent(parent)
		return
	parent.add_child(child)
	
func _safe_remove(parent:Node, child:Node) -> void:
	if not child.get_parent() == parent:
		return
	parent.remove_child(child)

## Adds a control to the menu bar before its separator.
func add_menu_bar_item(control:Control) -> void:
	var menu_bar := get_node("/root/Main").get_node("%MenuBar")
	_safe_add(menu_bar, control)
	var separator_index := menu_bar.get_node("Sep1").get_index()
	if control.get_index() < separator_index:
		separator_index -= 1
	menu_bar.move_child(control, separator_index)

## Removes a control from the menu bar.
func remove_menu_bar_item(control:Control) -> void:
	_safe_remove(get_node("/root/Main").get_node("%MenuBar"), control)

## Adds a control as a tab. A control that is not current is disabled.
func add_tab(control: Control) -> void:
	var tabs: TabContainer = get_node("/root/Main").get_node("%TabContainer")
	_safe_add(tabs, control)
	control.process_mode = Node.PROCESS_MODE_INHERIT if tabs.get_current_tab_control() == control else Node.PROCESS_MODE_DISABLED

## Removes a tab. It shows the editor tab when the removed tab was current.
func remove_tab(control: Control) -> void:
	var main := get_node_or_null("/root/Main")
	if main == null:
		return
	var tabs: TabContainer = main.get_node("%TabContainer")
	if tabs.get_current_tab_control() == control:
		show_editor_tab()
	_safe_remove(tabs, control)

## Shows one tab. It does nothing when the control is not a tab.
func show_tab(control: Control) -> void:
	var tabs: TabContainer = get_node("/root/Main").get_node("%TabContainer")
	if control.get_parent() == tabs:
		tabs.current_tab = tabs.get_tab_idx_from_control(control)

## Shows the editor tab.
func show_editor_tab() -> void:
	show_tab(get_node("/root/Main").get_node("%Editor"))

## Adds a control to the option bar.
func add_option_bar_item(control: Control) -> void:
	_safe_add(get_node("/root/Main").get_node("%OptionBar"), control)

## Removes a control from the option bar.
func remove_option_bar_item(control: Control) -> void:
	_safe_remove(get_node("/root/Main").get_node("%OptionBar"), control)

## Adds a control to the viewport control bar.
func add_control_bar_item(control:Control) -> void:
	_safe_add(get_node("/root/Main").get_node("%Viewport").get_node("%ControlBar"), control)

## Removes a control from the viewport control bar.
func remove_control_bar_item(control:Control) -> void:
	_safe_remove(get_node("/root/Main").get_node("%Viewport").get_node("%ControlBar"), control)

## Adds a control to the tool bar.
func add_tool_bar_item(control:Control) -> void:
	_safe_add(get_node("/root/Main").get_node("%ToolBar"), control)

## Removes a control from the tool bar.
func remove_tool_bar_item(control:Control) -> void:
	_safe_remove(get_node("/root/Main").get_node("%ToolBar"), control)

## Adds a tool node to the viewport scene.
func add_editor_node(node:Node3D) -> void:
	_safe_add(get_node("/root/Main").get_node("%Viewport").get_node("%ViewportScene"), node)
	
## Removes a tool node from the viewport scene.
func remove_editor_node(node:Node3D) -> void:
	_safe_remove(get_node("/root/Main").get_node("%Viewport").get_node("%ViewportScene"), node)
	
