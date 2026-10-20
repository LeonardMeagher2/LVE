class_name AnimationPlayback
extends RefCounted

## Advances the current frame for animation playback.
##
## The playback owns the current frame index, the playing flag, and the active
## tag. It reads the frame durations from a [VoxelDocument].

## Emitted before the current frame changes.
signal frame_changing()
## Emitted after the current frame changes.
signal frame_changed()
## Emitted when playback starts or stops.
signal is_playing_toggled(playing: bool)
## Emitted when the active tag changes.
signal tag_changed()

## The document that supplies the frames and the tags.
var document := VoxelDocument.new()

## The current frame index. A write clamps to the frame range.
var current_frame := 0:
	set(value):
		value = clampi(value, 0, document.frames.size() - 1)
		if value == current_frame:
			return
		frame_changing.emit()
		current_frame = value
		frame_changed.emit()

## Whether playback runs. Setting it to [code]true[/code] restarts the range.
var is_playing := false:
	set(value):
		if value == is_playing:
			return
		is_playing = value
		if is_playing:
			_restart()
		is_playing_toggled.emit(is_playing)

## The active tag index, or -1 when no tag is active.
var active_tag := 0:
	set(value):
		value = clampi(value, -1, document.tags.size() - 1)
		if value == active_tag:
			return
		active_tag = value
		if is_playing:
			_restart()
		tag_changed.emit()

var _play_dir := 1
var _play_passes := 0
var _play_elapsed := 0.0


## Advances the playback by one time step. Call it once per frame. It advances
## the frame when the elapsed time reaches the frame duration.
func update(delta: float) -> void:
	if not is_playing:
		return
	_play_elapsed += delta
	if _play_elapsed >= _current_delay():
		_play_elapsed = 0.0
		advance()


func _restart() -> void:
	_play_elapsed = 0.0
	_play_passes = 0
	_play_dir = 1
	current_frame = last_frame() if _play_mode() in [AnimationTag.LoopMode.REVERSE, AnimationTag.LoopMode.PING_PONG_REVERSE] else first_frame()
	if _play_mode() == AnimationTag.LoopMode.PING_PONG_REVERSE:
		_play_dir = -1


## Returns the first frame of the active tag, or frame zero.
func first_frame() -> int:
	var tag := document.get_tag(active_tag)
	if tag:
		return clampi(mini(tag.from, tag.to), 0, document.frames.size() - 1)
	return 0


## Returns the last frame of the active tag, or the last frame of the document.
func last_frame() -> int:
	var tag := document.get_tag(active_tag)
	if tag:
		return clampi(maxi(tag.from, tag.to), 0, document.frames.size() - 1)
	return document.frames.size() - 1


func _play_mode() -> AnimationTag.LoopMode:
	var tag := document.get_tag(active_tag)
	return tag.loop_mode if tag else AnimationTag.LoopMode.FORWARD


func _play_repeats() -> int:
	var tag := document.get_tag(active_tag)
	return tag.repeats if tag else 0


## Advances to the next frame for the active loop mode. It stops playback when
## the repeat count finishes.
func advance() -> void:
	if current_frame < first_frame() or current_frame > last_frame():
		_restart()
		return
	if first_frame() == last_frame():
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


func _current_delay() -> float:
	if current_frame < 0 or current_frame >= document.frames.size():
		return 1.0
	return maxf(document.frames[current_frame].delay_ms, 1.0) / 1000.0
