class_name ColorArea
extends Control

signal area_picked(saturation: float, value: float)

var hue := 0.0:
	set(value):
		hue = value
		_tex = null
var _tex: ImageTexture

func _draw() -> void:
	if _tex == null:
		_tex = _build()
	if _tex != null:
		draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false)

func _build() -> ImageTexture:
	var w := maxi(2, int(size.x))
	var h := maxi(2, int(size.y))
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var f := 1.0 - y / float(h - 1)
		for x in w:
			var c := Color.from_hsv(hue, x / float(w - 1), 1.0)
			img.set_pixel(x, y, Color(c.r * f, c.g * f, c.b * f, 1.0))
	return ImageTexture.create_from_image(img)

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
	if size.x > 0 and size.y > 0:
		area_picked.emit(clampf(pos.x / size.x, 0.0, 1.0), clampf(1.0 - pos.y / size.y, 0.0, 1.0))
		accept_event()
