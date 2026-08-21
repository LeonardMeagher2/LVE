class_name EditorStatusBar
extends HBoxContainer

@onready var _left: Label = $StatusLeft
@onready var _right: Label = $StatusRight


func set_status(tool_name: String, color_html: String, delay_ms: int, total_ms: int, frame: int, frame_count: int, zoom: int) -> void:
	_left.text = "%s  #%s" % [tool_name, color_html]
	_right.text = "%dms / %.2fs   Frame %d/%d   %d%%" % [delay_ms, total_ms / 1000.0, frame + 1, frame_count, zoom]
