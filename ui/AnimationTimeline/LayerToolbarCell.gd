class_name LayerToolbarCell
extends HBoxContainer


@onready var _delete: Button = %Delete


func _ready() -> void:
	%Add.pressed.connect(_on_add)
	%Duplicate.pressed.connect(_on_duplicate)
	_delete.pressed.connect(_on_delete)
	_delete.disabled = State.document.layers.size() <= 1


func _on_add() -> void:
	State.add_layer()


func _on_duplicate() -> void:
	State.duplicate_layer(State.active_layer_index)


func _on_delete() -> void:
	State.delete_layer(State.active_layer_index)
