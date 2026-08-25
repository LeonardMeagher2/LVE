class_name EditorViewportPanel
extends SubViewportContainer

signal zoom_changed(percent: float)
signal grid_changed(visible: bool)

@onready var _vp: EditorViewport = %Editor

var _tool_group := ""


func _ready() -> void:
	_vp.zoom_changed.connect(zoom_changed.emit)
	_vp.grid_changed.connect(grid_changed.emit)
	State.view_mode_changed.connect(_on_view_mode_changed)

func set_tool(t: ToolInfo) -> void:
	_vp.set_tool(t)
	_tool_group = t.group
	@warning_ignore("int_as_enum_without_cast")
	mouse_default_cursor_shape = _cursor()


func play_preview() -> void:
	_vp.play_preview()


func stop_preview() -> void:
	_vp.stop_preview()


func is_playing() -> bool:
	return _vp.is_playing()


func center_content() -> void:
	_vp.center_content()


func toggle_grid() -> void:
	_vp.toggle_grid()


@warning_ignore("shadowed_variable_base_class")
func set_view(name: String) -> void:
	_vp.set_view(name)


func set_projection(orthogonal: bool) -> void:
	_vp.set_projection(orthogonal)


func set_unshaded(on: bool) -> void:
	_vp.set_unshaded(on)


func _on_view_mode_changed(_mode) -> void:
	@warning_ignore("int_as_enum_without_cast")
	mouse_default_cursor_shape = _cursor()


func _cursor() -> int:
	if State.view_mode != State.ViewMode.NONE:
		return Control.CURSOR_DRAG
	return Control.CURSOR_CROSS if _tool_group == "select" else Control.CURSOR_ARROW


func set_zoom_percent(percent: float) -> void:
	_vp.set_zoom_percent(percent)


func set_grid_visible(v: bool) -> void:
	_vp.set_grid_visible(v)
