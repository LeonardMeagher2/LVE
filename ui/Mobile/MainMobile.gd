extends "res://Main.gd"

const SWIPE_DISTANCE := 48.0
const CORNER_MARGIN := 16.0
const MAX_SAFE_MARGIN := 64.0
const MAX_INSET := 160.0

var _drag_total := Vector2.ZERO
var _dragging := false


func _ready() -> void:
	super()
	_apply_safe_margin()
	get_window().size_changed.connect(_apply_safe_margin)


func _apply_safe_margin() -> void:
	var margin := _safe_margin()
	var content: Control = $Content
	content.offset_left = margin
	content.offset_top = margin
	content.offset_right = -margin
	content.offset_bottom = -margin


func _safe_margin() -> float:
	var size := Vector2i(DisplayServer.window_get_size())
	if size.x <= 0 or size.y <= 0:
		return CORNER_MARGIN
	var left := 0.0
	var top := 0.0
	var right := 0.0
	var bottom := 0.0
	var safe := DisplayServer.get_display_safe_area()
	if safe.size.x > 0 and safe.size.y > 0:
		left = float(safe.position.x)
		top = float(safe.position.y)
		right = float(size.x - safe.position.x - safe.size.x)
		bottom = float(size.y - safe.position.y - safe.size.y)
	for cutout in DisplayServer.get_display_cutouts():
		if cutout.position.y <= 0:
			top = maxf(top, float(cutout.position.y + cutout.size.y))
		if cutout.position.x <= 0:
			left = maxf(left, float(cutout.position.x + cutout.size.x))
		if cutout.position.x + cutout.size.x >= size.x:
			right = maxf(right, float(size.x - cutout.position.x))
		if cutout.position.y + cutout.size.y >= size.y:
			bottom = maxf(bottom, float(size.y - cutout.position.y))
	var inset := maxf(maxf(left, top), maxf(right, bottom))
	if inset <= 0.0 or inset > MAX_INSET:
		return CORNER_MARGIN
	return clampf(inset / maxf(get_window().content_scale_factor, 1.0), CORNER_MARGIN, MAX_SAFE_MARGIN)


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
