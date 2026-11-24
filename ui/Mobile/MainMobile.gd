extends "res://Main.gd"

const SWIPE_DISTANCE := 48.0
const CORNER_MARGIN := 16.0
const MAX_SAFE_MARGIN := 64.0
const MAX_INSET := 160.0

var _drag_total := Vector2.ZERO
var _dragging := false


func _ready() -> void:
	super()
	_apply_safe_margins()
	get_window().size_changed.connect(_apply_safe_margins)


func _mobile_ui_scale() -> float:
	var width := float(DisplayServer.screen_get_size(DisplayServer.SCREEN_OF_MAIN_WINDOW).x)
	var palette: Control = %PalettePanel
	var needed: float = palette.get_combined_minimum_size().x + CORNER_MARGIN * 2.0
	if needed <= CORNER_MARGIN * 2.0:
		needed = MOBILE_LOGICAL_WIDTH
	if width <= 0.0:
		return MOBILE_MIN_SCALE
	return clampf(width / needed, MOBILE_MIN_SCALE, MOBILE_MAX_SCALE)


func _apply_safe_margins() -> void:
	var scale := maxf(get_window().content_scale_factor, 1.0)
	var margins := _insets() / scale
	var content: Control = $Content
	content.offset_left = clampf(margins.x, CORNER_MARGIN, MAX_SAFE_MARGIN)
	content.offset_top = clampf(margins.y, CORNER_MARGIN, MAX_SAFE_MARGIN)
	content.offset_right = -clampf(margins.z, CORNER_MARGIN, MAX_SAFE_MARGIN)
	content.offset_bottom = -clampf(margins.w, CORNER_MARGIN, MAX_SAFE_MARGIN)


func _insets() -> Vector4:
	var size := Vector2i(DisplayServer.window_get_size())
	var insets := Vector4.ZERO
	if size.x <= 0 or size.y <= 0:
		return insets
	var safe := DisplayServer.get_display_safe_area()
	if safe.size.x > 0 and safe.size.y > 0:
		insets.x = float(safe.position.x)
		insets.y = float(safe.position.y)
		insets.z = float(size.x - safe.position.x - safe.size.x)
		insets.w = float(size.y - safe.position.y - safe.size.y)
	for cutout in DisplayServer.get_display_cutouts():
		if cutout.position.x <= 0:
			insets.x = maxf(insets.x, float(cutout.position.x + cutout.size.x))
		if cutout.position.y <= 0:
			insets.y = maxf(insets.y, float(cutout.position.y + cutout.size.y))
		if cutout.position.x + cutout.size.x >= size.x:
			insets.z = maxf(insets.z, float(size.x - cutout.position.x))
		if cutout.position.y + cutout.size.y >= size.y:
			insets.w = maxf(insets.w, float(size.y - cutout.position.y))
	if maxf(maxf(insets.x, insets.y), maxf(insets.z, insets.w)) > MAX_INSET:
		return Vector4.ZERO
	return insets


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
