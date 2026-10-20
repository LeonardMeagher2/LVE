extends Control

## Shows one sprite sheet preview.
##
## The preview draws the sheet over a checkerboard. The pointer wheel zooms. A
## middle or right drag pans. The left drag pans in pan mode.

const CHECKER := preload("res://ui/Checker.png")

## Emitted when the zoom changes.
signal zoom_changed(percent: float)

## The preview texture. A write refits the view.
var texture: Texture2D:
	set(value):
		texture = value
		if texture and _fitted:
			fit()
		queue_redraw()
## Whether a left drag pans the view.
var pan_mode := false
var _zoom := 100.0
var _pan := Vector2.ZERO
var _fitted := true


func _ready() -> void:
	resized.connect(_on_resized)


func _on_resized() -> void:
	if _fitted:
		fit()
	queue_redraw()


## Fits the sheet into the control and clears the pan.
func fit() -> void:
	_fitted = true
	_pan = Vector2.ZERO
	if texture:
		var image_size := Vector2(texture.get_size())
		_zoom = maxf(1.0, minf(size.x / image_size.x, size.y / image_size.y) * 100.0)
		zoom_changed.emit(_zoom)
	queue_redraw()


## Enables or disables pan mode.
func set_pan_mode(enabled: bool) -> void:
	pan_mode = enabled


## Sets the zoom percent and leaves the fitted view.
func set_zoom_percent(percent: float) -> void:
	_fitted = false
	_zoom = clampf(percent, 1.0, 100000.0)
	zoom_changed.emit(_zoom)
	queue_redraw()


## Multiplies the zoom by one factor.
func zoom(factor: float) -> void:
	set_zoom_percent(_zoom * factor)


func _draw() -> void:
	draw_texture_rect(CHECKER, Rect2(Vector2.ZERO, size), true)
	if texture:
		var image_size := Vector2(texture.get_size())
		var scale_factor := _zoom / 100.0
		var display_size := image_size * scale_factor
		draw_texture_rect(texture, Rect2((size - display_size) * 0.5 + _pan, display_size), false)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom(1.2 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.2)
			accept_event()
	elif event is InputEventMouseMotion and (event.button_mask & (MOUSE_BUTTON_MASK_MIDDLE | MOUSE_BUTTON_MASK_RIGHT) or (pan_mode and event.button_mask & MOUSE_BUTTON_MASK_LEFT)):
		_fitted = false
		_pan += event.relative
		queue_redraw()
		accept_event()
