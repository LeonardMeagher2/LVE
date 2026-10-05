extends "res://Plugins/Selection/SelectionPreview.gd"


func _ready() -> void:
	material_override = preload("res://Plugins/cursor_material.tres").duplicate()
	super._ready()
