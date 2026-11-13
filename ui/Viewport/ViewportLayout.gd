extends Control

## Keeps the viewport panel above the control bar. The environment row floats
## above the bar. Both use the theme separation.

@onready var _panel: PanelContainer = $PanelContainer
@onready var _bar: HBoxContainer = %ControlBar
@onready var _environment_layer: MarginContainer = %EnvironmentLayer


func _ready() -> void:
	_bar.resized.connect(_sync_spacing)
	_sync_spacing()


func _sync_spacing() -> void:
	var bar_height := _bar.get_combined_minimum_size().y
	_panel.offset_bottom = -bar_height - get_theme_constant("separation", "VBoxContainer")
	_environment_layer.offset_top = -bar_height
	_environment_layer.offset_bottom = -bar_height
