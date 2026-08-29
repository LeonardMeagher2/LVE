extends VBoxContainer

const PLAY_ICON := preload("res://icons/play.svg")
const PAUSE_ICON := preload("res://icons/pause.svg")

var _frame_template: Control


func _ready() -> void:
	_frame_template = %FrameStrip.get_child(0)
	%FrameStrip.remove_child(_frame_template)
	State.is_playing_toggled.connect(_on_is_playing_toggled)
	State.frames_changed.connect(_rebuild_strip)
	_rebuild_strip()

func _rebuild_strip() -> void:
	for frame in %FrameStrip.get_children():
		%FrameStrip.remove_child(frame)
		frame.queue_free()
	
	for i in State.document.frames.size():
		var frame: Control = _frame_template.duplicate()
		%FrameStrip.add_child(frame)


func _on_is_playing_toggled(toggled_on: bool) -> void:
	%Play.icon = PAUSE_ICON if toggled_on else PLAY_ICON
	%Play.tooltip_text = "Pause" if toggled_on else "Play"
	%Play.set_pressed_no_signal(toggled_on)

func _on_prev_pressed() -> void:
	State.prev_frame()


func _on_next_pressed() -> void:
	State.next_frame()


func _on_to_start_pressed() -> void:
	State.to_start()


func _on_to_end_pressed() -> void:
	State.to_end()


func _on_frame_add() -> void:
	State.add_frame()


func _on_frame_dup() -> void:
	State.duplicate_frame()


func _on_frame_del() -> void:
	State.delete_frame()


func _on_play_toggled(toggled_on: bool) -> void:
	State.is_playing = toggled_on
