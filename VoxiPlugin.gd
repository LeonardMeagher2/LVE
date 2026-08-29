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
	_safe_add(get_node("/root/Main").get_node("%MenuBar"), control)

func remove_menu_bar_item(control:Control) -> void:
	_safe_remove(get_node("/root/Main").get_node("%MenuBar"), control)

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
	
