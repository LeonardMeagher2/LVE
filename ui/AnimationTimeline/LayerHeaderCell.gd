class_name LayerHeaderCell
extends PanelContainer


signal rename_requested(index: int)

const EYE := preload("res://icons/eye.svg")
const EYE_OFF := preload("res://icons/eye_off.svg")
const LOCK := preload("res://icons/lock.svg")
const UNLOCK := preload("res://icons/unlock.svg")
const DRAG_TYPE := "voxel_layer"

var layer_index := 0

@onready var _eye: Button = %Eye
@onready var _lock: Button = %Lock
@onready var _name: Button = %Name


func _ready() -> void:
	_eye.toggled.connect(_on_eye_toggled)
	_lock.toggled.connect(_on_lock_toggled)
	_name.toggled.connect(_on_name_toggled)
	_name.gui_input.connect(_on_name_gui_input)
	_name.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)


func setup(index: int, layer: VoxelLayer, group: ButtonGroup) -> void:
	layer_index = index
	_name.button_group = group
	_name.text = layer.name
	_name.tooltip_text = "%s\nDouble-click to rename. Drag to reorder." % layer.name
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


func _on_name_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.double_click:
		rename_requested.emit(layer_index)
		accept_event()


func _get_drag_data(_at_position: Vector2) -> Variant:
	var preview := Label.new()
	preview.text = _name.text
	set_drag_preview(preview)
	return {"type": DRAG_TYPE, "from": layer_index}


func _can_drop_data(_at_position: Vector2, data) -> bool:
	return data is Dictionary and data.get("type", "") == DRAG_TYPE and data.get("from", -1) != layer_index


func _drop_data(_at_position: Vector2, data) -> void:
	if data is Dictionary and data.get("type", "") == DRAG_TYPE:
		State.move_layer(data["from"], layer_index)
