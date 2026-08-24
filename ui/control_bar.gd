class_name ControlBar
extends HBoxContainer

signal zoom_requested(percent: float)
signal grid_toggled(visible: bool)
signal reset_view_requested

@onready var _slider: HSlider = $ZoomSlider
@onready var _grid: Button = $GridToggle
@onready var _reset: Button = $ResetViewBtn

var _syncing := false


func _ready() -> void:
	_reset.pressed.connect(reset_view_requested.emit)


func set_zoom(percent: float) -> void:
	_syncing = true
	_slider.value = percent
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
