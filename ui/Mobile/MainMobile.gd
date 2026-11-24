extends "res://Main.gd"

const DOCK_TITLES := ["Palette", "Frames"]


func _ready() -> void:
	super()
	var tabs: TabContainer = %DockTabs
	for index in mini(DOCK_TITLES.size(), tabs.get_tab_count()):
		tabs.set_tab_title(index, DOCK_TITLES[index])
