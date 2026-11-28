class_name LayerHeaderCell
extends PanelContainer


const EYE := preload("res://icons/eye.svg")
const EYE_OFF := preload("res://icons/eye_off.svg")
const LOCK := preload("res://icons/lock.svg")
const UNLOCK := preload("res://icons/unlock.svg")

var layer_index := 0

@onready var _eye: Button = %Eye
@onready var _lock: Button = %Lock
@onready var _name: Button = %Name


func _ready() -> void:
	_eye.toggled.connect(_on_eye_toggled)
	_lock.toggled.connect(_on_lock_toggled)
	_name.toggled.connect(_on_name_toggled)


func setup(index: int, layer: VoxelLayer, group: ButtonGroup) -> void:
	layer_index = index
	_name.button_group = group
	_name.text = layer.name
	_name.tooltip_text = layer.name
	_eye.set_pressed_no_signal(layer.visible)
	_eye.icon = EYE if layer.visible else EYE_OFF
	_eye.tooltip_text = "Hide layer" if layer.visible else "Show layer"
	_lock.set_pressed_no_signal(layer.locked)
	_lock.icon = LOCK if layer.locked else UNLOCK
	_lock.tooltip_text = "Unlock layer" if layer.locked else "Lock layer"
	modulate = Color(1, 1, 1, 1) if layer.visible else Color(1, 1, 1, 0.55)


func set_active(active: bool) -> void:
	_name.set_pressed_no_signal(active)


func _on_eye_toggled(on: bool) -> void:
	State.set_layer_visible(layer_index, on)


func _on_lock_toggled(on: bool) -> void:
	State.set_layer_locked(layer_index, on)


func _on_name_toggled(on: bool) -> void:
	if on:
		State.active_layer_index = layer_index
