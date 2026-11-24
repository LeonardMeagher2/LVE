extends "res://Main.gd"


func _ready() -> void:
	super()
	%PaletteToggle.toggled.connect(_on_dock_toggled)
	%FramesToggle.toggled.connect(_on_dock_toggled)
	_sync_dock()


func _on_dock_toggled(_pressed: bool) -> void:
	_sync_dock()


func _sync_dock() -> void:
	var palette_on: bool = %PaletteToggle.button_pressed
	var frames_on: bool = %FramesToggle.button_pressed
	%PalettePanel.visible = palette_on
	%BottomDock.visible = frames_on
	%DockBody.visible = palette_on or frames_on
