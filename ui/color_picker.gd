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

@onready var _area: ColorArea = $Root/Row/Area
@onready var _hue_strip: HueStrip = $Root/Row/HueStrip
@onready var _hex: LineEdit = $Root/HexRow/Hex


func _ready() -> void:
	_area.area_picked.connect(_on_area_picked)
	_hue_strip.hue_picked.connect(_on_hue_picked)
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
	if _hex != null and not _hex.has_focus():
		_hex.text = "#" + _color.to_html(false)


func _on_area_picked(s: float, v: float) -> void:
	_set_color(Color.from_hsv(_hue, s, v, 1.0), true)


func _on_hue_picked(h: float) -> void:
	_hue = h
	_refresh()
	if _color.s > 0.0:
		_set_color(Color.from_hsv(h, _color.s, _color.v, 1.0), true)


func _apply_hex(text: String) -> void:
	var t := text.trim_prefix("#").strip_edges().to_lower()
	if t.length() != 6:
		return
	for ch in t:
		if "0123456789abcdef".find(ch) < 0:
			return
	_set_color(Color(t, false), true)
