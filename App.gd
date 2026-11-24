extends Control

const DESKTOP_SCENE := preload("res://Main.tscn")
const MOBILE_SCENE := preload("res://ui/Mobile/MainMobile.tscn")


func _ready() -> void:
	var scene := MOBILE_SCENE if OS.has_feature("mobile") else DESKTOP_SCENE
	add_child(scene.instantiate())
