extends HBoxContainer

## The terrain option bar.
##
## It shows the options of the active terrain tool. The Build section selects the
## add or the remove direction. Every tool shares the radius, the falloff, and
## the radius bound of the shared settings.

var _settings: TerrainToolSettings = preload("./settings.tres")


## Binds the shared terrain settings. Call it before the bar enters the tree.
func bind(settings: TerrainToolSettings) -> void:
	_settings = settings


func _ready() -> void:
	_settings.changed.connect(_sync)
	_sync()


func _sync() -> void:
	var tool: int = _settings.tool
	$Build.visible = tool == _settings.Tools.BUILD
	$Build/Add.set_pressed_no_signal(_settings.build_mode == _settings.BuildMode.ADD)
	$Build/Remove.set_pressed_no_signal(_settings.build_mode == _settings.BuildMode.REMOVE)
	$Radius.set_value_no_signal(_settings.radius)
	$Strength.set_value_no_signal(_settings.strength)
	$Falloff.set_value_no_signal(_settings.falloff)


func _on_add_pressed() -> void:
	_settings.build_mode = _settings.BuildMode.ADD


func _on_remove_pressed() -> void:
	_settings.build_mode = _settings.BuildMode.REMOVE


func _on_radius_changed(value: float) -> void:
	_settings.radius = int(value)


func _on_strength_changed(value: float) -> void:
	_settings.strength = int(value)


func _on_falloff_changed(value: float) -> void:
	_settings.falloff = value
