class_name ControlBar
extends HBoxContainer

signal zoom_requested(percent: float)
signal grid_toggled(visible: bool)

@onready var _slider: HSlider = $ZoomSlider
@onready var _grid: Button = $GridToggle

var _syncing := false


func set_zoom(percent: float) -> void:
	_syncing = true
	_slider.value = clampf(percent, _slider.min_value, _slider.max_value)
	_syncing = false


func set_grid_visible(v: bool) -> void:
	_grid.button_pressed = v


func _on_zoom_slider_changed(v: float) -> void:
	if _syncing:
		return
	zoom_requested.emit(v)


func _on_zoom_one_pressed() -> void:
	zoom_requested.emit(100.0)


func _on_grid_toggled(v: bool) -> void:
	grid_toggled.emit(v)
