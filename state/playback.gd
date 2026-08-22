class_name Playback
extends RefCounted

signal playback_changed

var playing := false


func set_playing(p: bool) -> void:
	if p == playing:
		return
	playing = p
	playback_changed.emit()


func add_frame() -> void:
	set_playing(false)
	State.document.add_frame()
	State.current_frame = State.document.frames.size() - 1
	State.frames_changed.emit()


func duplicate_frame() -> void:
	set_playing(false)
	State.document.duplicate_frame(State.current_frame)
	State.current_frame += 1
	State.frames_changed.emit()


func delete_frame() -> void:
	if State.document.frames.size() <= 1:
		return
	set_playing(false)
	State.document.remove_frame(State.current_frame)
	if State.current_frame >= State.document.frames.size():
		State.current_frame = State.document.frames.size() - 1
	State.frames_changed.emit()


func select_frame(i: int) -> void:
	if i < 0 or i >= State.document.frames.size() or i == State.current_frame:
		return
	set_playing(false)
	State.current_frame = i
