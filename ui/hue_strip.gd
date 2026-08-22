class_name HueStrip
extends Control

signal hue_picked(hue: float)

var value := 0.0
var _tex: ImageTexture

func _draw() -> void:
	if _tex == null:
		var h := maxi(2, int(size.y))
		var img := Image.create_empty(1, h, false, Image.FORMAT_RGBA8)
		for y in h:
			img.set_pixel(0, y, Color.from_hsv(y / float(h - 1), 1.0, 1.0))
		_tex = ImageTexture.create_from_image(img)
	draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false)
	var y := value * size.y
	draw_line(Vector2(0, y), Vector2(size.x, y), Color.WHITE, 1.5, true)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_pick(mb.position)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_pick(mm.position)

func _pick(pos: Vector2) -> void:
	if size.y > 0:
		hue_picked.emit(clampf(pos.y / size.y, 0.0, 1.0))
		accept_event()
