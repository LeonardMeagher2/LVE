extends HBoxContainer

## The deform option bar.
##
## It shows the shared size and falloff. Both deform tools use them.

var _settings: DeformToolSettings = preload("./settings.tres")


## Binds the shared deform settings. Call it before the bar enters the tree.
func bind(settings: DeformToolSettings) -> void:
	_settings = settings


func _ready() -> void:
	_settings.changed.connect(_sync)
	_sync()


func _sync() -> void:
	$Size.set_value_no_signal(_settings.size)
	$Falloff.set_value_no_signal(_settings.falloff)


func _on_size_changed(value: float) -> void:
	_settings.size = int(value)


func _on_falloff_changed(value: float) -> void:
	_settings.falloff = value
