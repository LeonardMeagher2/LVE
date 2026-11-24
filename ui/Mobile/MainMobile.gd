extends "res://Main.gd"

const SWIPE_DISTANCE := 48.0

var _drag_total := Vector2.ZERO
var _dragging := false


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = _is_dock_point(event.position)
			_drag_total = Vector2.ZERO
		elif _dragging:
			_dragging = false
			_apply_dock_swipe(_drag_total)
		return
	if event is InputEventMouseMotion and _dragging:
		_drag_total += event.relative


func _is_dock_point(point: Vector2) -> bool:
	var body: Control = %DockBody
	if not body.is_visible_in_tree():
		return false
	if not body.get_global_rect().has_point(point):
		return false
	var control := get_viewport().gui_get_hovered_control()
	while control != null:
		if control is Range or control is ColorPicker:
			return false
		control = control.get_parent_control()
	return true


func _apply_dock_swipe(offset: Vector2) -> void:
	if absf(offset.x) < SWIPE_DISTANCE or absf(offset.x) <= absf(offset.y):
		return
	var show_palette: bool = offset.x > 0.0
	%PalettePanel.visible = show_palette
	%BottomDock.visible = not show_palette
