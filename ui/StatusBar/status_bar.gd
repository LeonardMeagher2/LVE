class_name EditorStatusBar
extends HBoxContainer

@onready var _left: Label = $StatusLeft
@onready var _right: Label = $StatusRight


func set_status(color_html: String, frame: int, frame_count: int, zoom: int) -> void:
	_left.text = "#%s" % [color_html]
	_right.text = "Frame %d/%d   %d%%" % [frame + 1, frame_count, zoom]
