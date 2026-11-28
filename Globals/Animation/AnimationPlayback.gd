class_name AnimationPlayback
extends RefCounted


signal frame_changing()
signal frame_changed()
signal is_playing_toggled(playing: bool)
signal tag_changed()

var document := VoxelDocument.new()

var current_frame: int:
	get:
		return document.edit_frame
	set(value):
		value = clampi(value, 0, document.frame_count() - 1)
		if value == document.edit_frame:
			return
		frame_changing.emit()
		document.edit_frame = value
		frame_changed.emit()

var is_playing: bool:
	get:
		return document.edit_playing
	set(value):
		if value == document.edit_playing:
			return
		document.edit_playing = value
		if value:
			_restart()
		is_playing_toggled.emit(document.edit_playing)

var active_tag: int:
	get:
		return document.edit_tag
	set(value):
		value = clampi(value, -1, document.tags.size() - 1)
		if value == document.edit_tag:
			return
		document.edit_tag = value
		if is_playing:
			_restart()
		tag_changed.emit()

const MAX_STEPS_PER_UPDATE := 256

var _play_dir := 1
var _play_passes := 0
var _play_elapsed := 0.0


func update(delta: float) -> void:
	if not is_playing:
		return
	_play_elapsed += delta
	var steps := 0
	while is_playing and _play_elapsed >= _current_delay():
		_play_elapsed -= _current_delay()
		advance()
		steps += 1
		if steps >= MAX_STEPS_PER_UPDATE:
			_play_elapsed = 0.0
			break


func _restart() -> void:
	_play_elapsed = 0.0
	_play_passes = 0
	_play_dir = 1
	current_frame = last_frame() if _play_mode() in [AnimationTag.LoopMode.REVERSE, AnimationTag.LoopMode.PING_PONG_REVERSE] else first_frame()
	if _play_mode() == AnimationTag.LoopMode.PING_PONG_REVERSE:
		_play_dir = -1


func restore_playback() -> void:
	if document.edit_playing:
		_restart()
	is_playing_toggled.emit(document.edit_playing)


func first_frame() -> int:
	var tag := document.get_tag(active_tag)
	if tag:
		return clampi(mini(tag.from, tag.to), 0, document.frame_count() - 1)
	return 0


func last_frame() -> int:
	var tag := document.get_tag(active_tag)
	if tag:
		return clampi(maxi(tag.from, tag.to), 0, document.frame_count() - 1)
	return document.frame_count() - 1


func _play_mode() -> AnimationTag.LoopMode:
	var tag := document.get_tag(active_tag)
	return tag.loop_mode if tag else AnimationTag.LoopMode.FORWARD


func _play_repeats() -> int:
	var tag := document.get_tag(active_tag)
	return tag.repeats if tag else 0


func advance() -> void:
	if current_frame < first_frame() or current_frame > last_frame():
		_restart()
		return
	if first_frame() == last_frame():
		_play_passes += 1
		if _finished():
			is_playing = false
		return
	match _play_mode():
		AnimationTag.LoopMode.FORWARD:
			if current_frame == last_frame():
				_play_passes += 1
				if _finished():
					is_playing = false
					return
				current_frame = first_frame()
			else:
				current_frame += 1
		AnimationTag.LoopMode.REVERSE:
			if current_frame == first_frame():
				_play_passes += 1
				if _finished():
					is_playing = false
					return
				current_frame = last_frame()
			else:
				current_frame -= 1
		_:
			if _play_dir == 1:
				if current_frame == last_frame():
					if _play_mode() == AnimationTag.LoopMode.PING_PONG_REVERSE:
						_play_passes += 1
						if _finished():
							is_playing = false
							return
					current_frame = last_frame() - 1
					_play_dir = -1
				else:
					current_frame += 1
			else:
				if current_frame == first_frame():
					if _play_mode() != AnimationTag.LoopMode.PING_PONG_REVERSE:
						_play_passes += 1
						if _finished():
							is_playing = false
							return
					current_frame = first_frame() + 1
					_play_dir = 1
				else:
					current_frame -= 1


func _finished() -> bool:
	return _play_repeats() > 0 and _play_passes >= _play_repeats()


func reset_passes() -> void:
	_play_passes = 0


func _current_delay() -> float:
	if current_frame < 0 or current_frame >= document.frame_count():
		return 1.0
	return maxf(document.frame_delay(current_frame), 1.0) / 1000.0
