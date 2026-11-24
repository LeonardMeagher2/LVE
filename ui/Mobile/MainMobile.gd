extends "res://Main.gd"

const CORNER_MARGIN := 16.0
const MAX_SAFE_MARGIN := 64.0
const MAX_INSET := 160.0


func _ready() -> void:
	super()
	_apply_safe_margins()
	get_window().size_changed.connect(_apply_safe_margins)
	%PaletteToggle.toggled.connect(_on_dock_toggled)
	%FramesToggle.toggled.connect(_on_dock_toggled)
	_sync_dock()


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


func _on_dock_toggled(_pressed: bool) -> void:
	_sync_dock()


func _sync_dock() -> void:
	var palette_on: bool = %PaletteToggle.button_pressed
	var frames_on: bool = %FramesToggle.button_pressed
	%PalettePanel.visible = palette_on
	%BottomDock.visible = frames_on
	%DockBody.visible = palette_on or frames_on
