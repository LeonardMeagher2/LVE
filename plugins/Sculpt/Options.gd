extends HBoxContainer

## The sculpt option bar.
##
## It shows the options of the active sculpt tool. The Grow section selects the
## add or the remove direction. Every tool shares the radius and the falloff.
## The Grab tool has a smaller radius bound, so its radius control shows that
## bound. The strength control is hidden for Grab, because Grab does not use it.
##
## Grow, Flatten, and Smooth share one normal source toggle. The button shows the
## current source as an icon, and its pressed state marks the Face source. The
## Grab tool hides the toggle, because Grab drags on the view plane.

const SculptToolScript := preload("./SculptTool.gd")

## The icon of each normal source, indexed by the enum value.
const NORMAL_ICONS := [
	preload("res://icons/sculpt_surface.svg"),
	preload("res://icons/sculpt_face.svg"),
]
## The tooltip of each normal source, indexed by the enum value.
const NORMAL_TOOLTIPS := [
	"Surface normal: fit the plane to nearby voxels. Press for the exact face.",
	"Face normal: use the exact face of the hovered voxel. Press for the fitted surface.",
]

var _settings: SculptToolSettings = preload("./settings.tres")


## Binds the shared sculpt settings. Call it before the bar enters the tree.
func bind(settings: SculptToolSettings) -> void:
	_settings = settings


func _ready() -> void:
	_settings.changed.connect(_sync)
	_sync()


func _sync() -> void:
	var tool: int = _settings.tool
	var radius_max := float(SculptToolScript.GRAB_MAX_RADIUS) if tool == _settings.Tools.GRAB else 32.0
	if float(_settings.radius) > radius_max:
		_settings.radius = int(radius_max)
	$Grow.visible = tool == _settings.Tools.GROW
	$Grow/Add.set_pressed_no_signal(_settings.grow_mode == _settings.GrowMode.ADD)
	$Grow/Remove.set_pressed_no_signal(_settings.grow_mode == _settings.GrowMode.REMOVE)
	# The Grab tool drags on the view plane, so the normal source does not apply.
	$Normal.visible = tool != _settings.Tools.GRAB
	var source := int(_settings.normal_source)
	$Normal.set_pressed_no_signal(source == _settings.NormalSource.FACE)
	$Normal.icon = NORMAL_ICONS[source]
	$Normal.tooltip_text = NORMAL_TOOLTIPS[source]
	$Strength.visible = tool != _settings.Tools.GRAB
	$Radius.max_value = radius_max
	$Radius.set_value_no_signal(_settings.radius)
	$Strength.set_value_no_signal(_settings.strength)
	$Falloff.set_value_no_signal(_settings.falloff)


func _on_normal_toggled(pressed: bool) -> void:
	_settings.normal_source = _settings.NormalSource.FACE if pressed else _settings.NormalSource.SURFACE


func _on_add_pressed() -> void:
	_settings.grow_mode = _settings.GrowMode.ADD


func _on_remove_pressed() -> void:
	_settings.grow_mode = _settings.GrowMode.REMOVE


func _on_radius_changed(value: float) -> void:
	_settings.radius = int(value)


func _on_strength_changed(value: float) -> void:
	_settings.strength = value


func _on_falloff_changed(value: float) -> void:
	_settings.falloff = value
