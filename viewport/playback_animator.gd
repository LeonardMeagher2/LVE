class_name PlaybackAnimator
extends Node3D

@onready var _anim_player: AnimationPlayer = $AnimationPlayer

var _anim_library: AnimationLibrary

var display_frame := 0:
	set(value):
		if value >= 0 and value < State.document.frames.size():
			State.current_frame = value


func _ready() -> void:
	_anim_library = AnimationLibrary.new()
	_anim_player.add_animation_library("", _anim_library)


func play_preview() -> void:
	_rebuild_animation()
	_anim_player.play("preview")
	_anim_player.seek(_frame_time(State.current_frame), true)


func stop_preview() -> void:
	if _anim_player.is_playing():
		_anim_player.stop()


func is_playing() -> bool:
	return _anim_player.is_playing()


func _rebuild_animation() -> void:
	var d := State.document
	if d == null:
		return
	var anim := Animation.new()
	anim.loop_mode = Animation.LOOP_LINEAR
	anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(0, NodePath(".:display_frame"))
	anim.track_set_interpolation_type(0, Animation.INTERPOLATION_NEAREST)
	var t := 0.0
	for i in d.frames.size():
		anim.track_insert_key(0, t, i)
		t += float(d.frames[i].delay_ms) / 1000.0
	anim.length = t
	if _anim_library.has_animation("preview"):
		_anim_library.remove_animation("preview")
	_anim_library.add_animation("preview", anim)


func _frame_time(frame: int) -> float:
	var t := 0.0
	for i in frame:
		t += float(State.document.frames[i].delay_ms) / 1000.0
	return t
