extends HBoxContainer

## The fill option bar.
##
## It edits the connected fill option. The option bar shares its settings with
## the fill tool.

var _settings := preload("./settings.tres")

func _on_connected_toggled(toggled_on: bool) -> void:
	_settings.connected = toggled_on
