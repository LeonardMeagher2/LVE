class_name EditorViewportPanel
extends SubViewportContainer

signal zoom_changed(percent: float)
signal grid_changed(visible: bool)

@onready var _vp: EditorViewport = $Viewport/Editor


func _ready() -> void:
	_vp.zoom_changed.connect(zoom_changed.emit)
	_vp.grid_changed.connect(grid_changed.emit)

func set_tool(t: ToolInfo) -> void:
	_vp.set_tool(t)


func play_preview() -> void:
	_vp.play_preview()


func stop_preview() -> void:
	_vp.stop_preview()


func is_playing() -> bool:
	return _vp.is_playing()


func reset_view() -> void:
	_vp.reset_view()


func toggle_grid() -> void:
	_vp.toggle_grid()


func set_view(name: String) -> void:
	_vp.set_view(name)


func set_zoom_percent(percent: float) -> void:
	_vp.set_zoom_percent(percent)


func set_grid_visible(v: bool) -> void:
	_vp.set_grid_visible(v)
