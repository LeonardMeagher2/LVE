class_name CelCell
extends Button


var layer_index := 0
var frame_index := 0
var _layer_name := ""

@onready var _marker: ColorRect = $Marker


func _ready() -> void:
	toggled.connect(_on_toggled)


func setup(layer: int, frame: int, layer_name: String, group: ButtonGroup) -> void:
	layer_index = layer
	frame_index = frame
	_layer_name = layer_name
	button_group = group
	tooltip_text = "%s, frame %d" % [layer_name, frame + 1]
	refresh_filled()


func refresh_filled() -> void:
	var cel := State.document.cel(layer_index, frame_index)
	_marker.visible = cel != null and cel.count() > 0


func set_active(active: bool) -> void:
	set_pressed_no_signal(active)


func _on_toggled(on: bool) -> void:
	if not on:
		return
	State.active_layer_index = layer_index
	State.current_frame = frame_index
