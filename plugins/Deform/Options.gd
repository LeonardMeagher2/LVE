extends HBoxContainer

## The deform option bar.
##
## It shows the shared radius and falloff, and the Pose reach. Grab uses the
## radius and the falloff only, so the Pose reach hides for Grab.

const LIMB_ICON := preload("res://icons/connected.svg")
const SPHERE_ICON := preload("res://icons/cube.svg")

var _settings: DeformToolSettings = preload("./settings.tres")


## Binds the shared deform settings. Call it before the bar enters the tree.
func bind(settings: DeformToolSettings) -> void:
	_settings = settings


func _ready() -> void:
	_settings.changed.connect(_sync)
	_sync()


func _sync() -> void:
	$Reach.visible = _settings.tool == _settings.Tools.POSE
	$Radius.set_value_no_signal(_settings.radius)
	$Falloff.set_value_no_signal(_settings.falloff)
	$Reach.set_pressed_no_signal(_settings.reach == _settings.Reach.LIMB)
	_sync_reach_icon()


# The reach button shows the set that the next press will move.
func _sync_reach_icon() -> void:
	var limb: bool = _settings.reach == _settings.Reach.LIMB
	$Reach.icon = LIMB_ICON if limb else SPHERE_ICON
	$Reach.tooltip_text = "Pose moves the whole connected limb" if limb else "Pose moves only the cells inside the ring"


func _on_radius_changed(value: float) -> void:
	_settings.radius = int(value)


func _on_falloff_changed(value: float) -> void:
	_settings.falloff = value


func _on_reach_toggled(on: bool) -> void:
	_settings.reach = _settings.Reach.LIMB if on else _settings.Reach.SPHERE
