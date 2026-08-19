class_name OptionBar
extends HBoxContainer

@onready var _pixel_perfect: CheckButton = $PixelPerfect


func _ready() -> void:
	State.pixel_perfect_changed.connect(_on_pixel_perfect_changed)
	_pixel_perfect.button_pressed = State.pixel_perfect


func _on_pixel_perfect_toggled(v: bool) -> void:
	State.set_pixel_perfect(v)


func _on_pixel_perfect_changed(v: bool) -> void:
	_pixel_perfect.button_pressed = v
