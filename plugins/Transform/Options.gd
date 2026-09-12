extends HBoxContainer

var _settings := preload("./settings.tres")

func _ready() -> void:
	_settings.changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	$snap.visible = _settings.tool == _settings.Tools.ROTATE
	$snap.set_pressed_no_signal(_settings.snap)
	$uniform.visible = _settings.tool == _settings.Tools.SCALE
	$uniform.set_pressed_no_signal(_settings.uniform)
	$commit.disabled = not _settings.transforming
	$cancel.disabled = not _settings.transforming


func _on_snap_toggled(toggled_on: bool) -> void:
	_settings.snap = toggled_on


func _on_uniform_toggled(toggled_on: bool) -> void:
	_settings.uniform = toggled_on


func _on_commit_pressed() -> void:
	_settings.commit()


func _on_cancel_pressed() -> void:
	_settings.cancel()
