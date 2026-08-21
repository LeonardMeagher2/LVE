class_name OptionBar
extends HBoxContainer

signal view_requested(name: String)

@onready var _pixel_perfect: CheckButton = $PixelPerfect
@onready var _view_menu: MenuButton = $View


func _ready() -> void:
	State.pixel_perfect_changed.connect(_on_pixel_perfect_changed)
	_pixel_perfect.button_pressed = State.pixel_perfect
	_view_menu.get_popup().id_pressed.connect(_on_view_selected)


func _on_pixel_perfect_toggled(v: bool) -> void:
	State.set_pixel_perfect(v)


func _on_pixel_perfect_changed(v: bool) -> void:
	_pixel_perfect.button_pressed = v


func _on_view_selected(index: int) -> void:
	match index:
		0: view_requested.emit("top")
		1: view_requested.emit("front")
		2: view_requested.emit("side")
		3: view_requested.emit("isometric")
		4: view_requested.emit("reset")
