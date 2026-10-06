extends Control


func _ready() -> void:
	%TabContainer.tab_changed.connect(_on_tab_changed)
	_on_tab_changed(%TabContainer.current_tab)


func _on_tab_changed(_index: int) -> void:
	var current: Control = %TabContainer.get_current_tab_control()
	for tab in %TabContainer.get_children():
		if tab is Control:
			tab.process_mode = Node.PROCESS_MODE_INHERIT if tab == current else Node.PROCESS_MODE_DISABLED
	var viewport: SubViewport = %Viewport.get_node("PanelContainer/SubViewportContainer/Viewport")
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if current == %Editor else SubViewport.UPDATE_DISABLED
	if current != %Editor:
		State.stop()
