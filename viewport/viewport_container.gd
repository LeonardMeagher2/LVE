class_name EditorViewportPanel
extends SubViewportContainer

signal zoom_changed(percent: float)
signal frame_displayed(index: int)

@onready var _vp: EditorViewport = $Viewport/Editor


func _ready() -> void:
	_vp.zoom_changed.connect(zoom_changed.emit)
	_vp.frame_displayed.connect(frame_displayed.emit)


func configure() -> void:
	_vp.configure()


func sync_to(frame_index: int) -> void:
	_vp.sync_to(frame_index)


func sync_selection(selection: VoxelSelection) -> void:
	_vp.sync_selection(selection)


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
