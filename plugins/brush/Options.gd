extends HBoxContainer

var _settings := preload("./settings.tres")

func _on_pixel_perfect_toggled(toggled_on: bool) -> void:
	_settings.pixel_perfect = toggled_on
