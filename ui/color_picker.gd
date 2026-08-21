class_name CompactColorPicker
extends Control

signal color_changed(color: Color)

const AREA_HEIGHT := 140.0

var color: Color:
	get:
		return _color
	set(value):
		if value == _color:
			return
		_hue = value.h
		_color = value
		_refresh()

var _color := Color.WHITE
var _hue := 0.0
var _root: VBoxContainer
var _area: ColorArea
var _hue_strip: HueStrip
var _alpha_strip: AlphaStrip
var _hex: LineEdit


func _ready() -> void:
	custom_minimum_size = Vector2(0, 190)
	_root = VBoxContainer.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_theme_constant_override("separation", 4)
	add_child(_root)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(row)
	_area = ColorArea.new()
	_area.custom_minimum_size = Vector2(120, AREA_HEIGHT)
	_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(_area)
	_hue_strip = HueStrip.new()
	_hue_strip.custom_minimum_size = Vector2(14, AREA_HEIGHT)
	_hue_strip.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(_hue_strip)
	_alpha_strip = AlphaStrip.new()
	_alpha_strip.custom_minimum_size = Vector2(0, 14)
	_root.add_child(_alpha_strip)
	var hex_row := HBoxContainer.new()
	hex_row.add_theme_constant_override("separation", 6)
	_root.add_child(hex_row)
	var hex_label := Label.new()
	hex_label.text = "Hex"
	hex_row.add_child(hex_label)
	_hex = LineEdit.new()
	_hex.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hex.placeholder_text = "#rrggbb"
	hex_row.add_child(_hex)
	_area.area_picked.connect(_on_area_picked)
	_hue_strip.hue_picked.connect(_on_hue_picked)
	_alpha_strip.alpha_picked.connect(_on_alpha_picked)
	_hex.text_submitted.connect(_apply_hex)
	_hex.text_changed.connect(_apply_hex)
	_refresh()


func _set_color(c: Color, emit: bool) -> void:
	if c == _color:
		return
	_hue = c.h
	_color = c
	_refresh()
	if emit:
		color_changed.emit(_color)


func _refresh() -> void:
	if _area == null:
		return
	_area.hue = _hue
	_area.queue_redraw()
	_hue_strip.value = _hue
	_hue_strip.queue_redraw()
	_alpha_strip.value = _color.a
	_alpha_strip.queue_redraw()
	if _hex != null and not _hex.has_focus():
		_hex.text = "#" + _color.to_html(false)


func _on_area_picked(s: float, v: float) -> void:
	_set_color(Color.from_hsv(_hue, s, v, _color.a), true)


func _on_hue_picked(h: float) -> void:
	_set_color(Color.from_hsv(h, _color.s, _color.v, _color.a), true)


func _on_alpha_picked(a: float) -> void:
	_set_color(Color(_color.r, _color.g, _color.b, a), true)


func _apply_hex(text: String) -> void:
	var t := text.trim_prefix("#").strip_edges().to_lower()
	if t.length() != 6:
		return
	for ch in t:
		if "0123456789abcdef".find(ch) < 0:
			return
	_set_color(Color(t, false), true)


class ColorArea:
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


class HueStrip:
	extends Control
	signal hue_picked(hue: float)
	var value := 0.0
	var _tex: ImageTexture

	func _draw() -> void:
		if _tex == null:
			var img := Image.create_empty(64, 1, false, Image.FORMAT_RGBA8)
			for x in 64:
				img.set_pixel(x, 0, Color.from_hsv(x / 63.0, 1.0, 1.0))
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


class AlphaStrip:
	extends Control
	signal alpha_picked(alpha: float)
	var value := 1.0
	var _tex: ImageTexture

	func _draw() -> void:
		if _tex == null:
			var img := Image.create_empty(64, 1, false, Image.FORMAT_RGBA8)
			for x in 64:
				img.set_pixel(x, 0, Color(1, 1, 1, x / 63.0))
			_tex = ImageTexture.create_from_image(img)
		var w := int(size.x)
		var h := int(size.y)
		var step := 8
		var x := 0
		while x < w:
			var y := 0
			while y < h:
				var c := Color(0.22, 0.22, 0.22) if (x + y) % 2 == 0 else Color(0.35, 0.35, 0.35)
				draw_rect(Rect2(Vector2(x, y), Vector2(step, step)), c)
				y += step
			x += step
		draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false)
		var y := (1.0 - value) * size.y
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
			alpha_picked.emit(clampf(1.0 - pos.y / size.y, 0.0, 1.0))
			accept_event()
