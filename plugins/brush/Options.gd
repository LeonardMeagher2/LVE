extends HBoxContainer

## The brush option bar.
##
## It edits the brush diameter, the shape, and the pixel-perfect flag.

var _settings := preload("./BrushSettings.tres")


func _ready() -> void:
	_settings.changed.connect(_sync)
	_sync()


func _sync() -> void:
	$Diameter.set_value_no_signal(_settings.diameter)
	var shape_buttons := [$Shape/Cube, $Shape/Sphere]
	var shape: int = _settings.shape
	if shape < 0 or shape >= shape_buttons.size():
		shape = _settings.BrushShape.CUBE
	shape_buttons[shape].button_pressed = true
	$PixelPerfect.visible = _settings.mode != _settings.BrushMode.LINE
	$PixelPerfect.set_pressed_no_signal(_settings.pixel_perfect)


func _on_diameter_changed(value: float) -> void:
	_settings.diameter = int(value)


func _on_cube_pressed() -> void:
	_settings.shape = _settings.BrushShape.CUBE


func _on_sphere_pressed() -> void:
	_settings.shape = _settings.BrushShape.SPHERE


func _on_pixel_perfect_toggled(toggled_on: bool) -> void:
	_settings.pixel_perfect = toggled_on
