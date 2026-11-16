extends HBoxContainer

## The paint option bar.
##
## It shows the options of the active paint tool. The brush section edits the
## paintbrush diameter, the shape, and the pixel-perfect flag. The fill section
## edits the connected option. The spray section edits the spot diameter, the
## spray search size, and the speed. The spot diameter and the search size are
## voxel widths, not radii.

var _settings := preload("./PaintSettings.tres")


func _ready() -> void:
	_settings.changed.connect(_sync)
	_sync()


func _sync() -> void:
	var tool: int = _settings.tool
	$Brush.visible = tool == _settings.Tools.PAINTBRUSH
	$Fill.visible = tool == _settings.Tools.FILL
	$Spray.visible = tool == _settings.Tools.SPRAY
	$Brush/Diameter.set_value_no_signal(_settings.diameter)
	var shape_buttons := [$Brush/Shape/Cube, $Brush/Shape/Sphere]
	var shape: int = _settings.shape
	if shape < 0 or shape >= shape_buttons.size():
		shape = _settings.BrushShape.CUBE
	shape_buttons[shape].button_pressed = true
	$Brush/PixelPerfect.set_pressed_no_signal(_settings.pixel_perfect)
	$Fill/Connected.set_pressed_no_signal(_settings.connected)
	$Spray/SpotSize.set_value_no_signal(_settings.spot_diameter)
	$Spray/SpraySize.set_value_no_signal(_settings.spray_size)
	$Spray/Speed.set_value_no_signal(_settings.speed)


func _on_diameter_changed(value: float) -> void:
	_settings.diameter = int(value)


func _on_cube_pressed() -> void:
	_settings.shape = _settings.BrushShape.CUBE


func _on_sphere_pressed() -> void:
	_settings.shape = _settings.BrushShape.SPHERE


func _on_pixel_perfect_toggled(toggled_on: bool) -> void:
	_settings.pixel_perfect = toggled_on


func _on_connected_toggled(toggled_on: bool) -> void:
	_settings.connected = toggled_on


func _on_spot_size_changed(value: float) -> void:
	_settings.spot_diameter = int(value)


func _on_spray_size_changed(value: float) -> void:
	_settings.spray_size = int(value)


func _on_speed_changed(value: float) -> void:
	_settings.speed = int(value)
