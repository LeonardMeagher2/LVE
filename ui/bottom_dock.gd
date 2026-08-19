class_name EditorBottomDock
extends VBoxContainer

signal play_toggled
signal prev
signal next
signal to_start
signal to_end
signal frame_add
signal frame_dup
signal frame_del
signal frame_selected(index: int)

@onready var _play_button: Button = $PlaybackRow/Play
@onready var _frame_strip: EditorFrameStrip = $FrameRow/FrameScroll/FrameStrip


func _ready() -> void:
	_frame_strip.frame_selected.connect(frame_selected.emit)


func set_playing(playing: bool) -> void:
	_play_button.text = "Pause" if playing else "Play"


func highlight_frame(i: int) -> void:
	_frame_strip.highlight(i)


func _on_play_pressed() -> void:
	play_toggled.emit()


func _on_prev_pressed() -> void:
	prev.emit()


func _on_next_pressed() -> void:
	next.emit()


func _on_to_start_pressed() -> void:
	to_start.emit()


func _on_to_end_pressed() -> void:
	to_end.emit()


func _on_frame_add() -> void:
	frame_add.emit()


func _on_frame_dup() -> void:
	frame_dup.emit()


func _on_frame_del() -> void:
	frame_del.emit()
