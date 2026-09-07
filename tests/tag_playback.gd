extends "res://tests/test.gd"


func _ready() -> void:
	test("can play a tag's frames with its loop mode and repeats", _run)


func _run() -> void:
	step("Given a document with four frames", func():
		State.document.add_frame()
		State.document.add_frame()
		State.document.add_frame()
		for f in State.document.frames:
			f.delay_ms = 100000
	)

	step("When the user plays a forward tag over frames 2-4", func():
		State.document.add_tag("Fwd", 1, 3, AnimationTag.LoopMode.FORWARD, 0)
		State.current_frame = 2
		State.play_tag(0)
	)

	step("Then playback continues from the current frame and wraps", func():
		expect(State.current_frame == 2, "playback keeps the current frame")
		State._advance_playback()
		expect(State.current_frame == 3, "frame advances to the tag end")
		State._advance_playback()
		expect(State.current_frame == 1, "frame wraps to the tag start")
		State.stop()
	)

	step("When the user plays a reverse tag over frames 1-3", func():
		State.document.add_tag("Rev", 0, 2, AnimationTag.LoopMode.REVERSE, 0)
		State.current_frame = 2
		State.play_tag(1)
	)

	step("Then the frames advance in reverse and wrap", func():
		expect(State.current_frame == 2, "playback starts at the tag end")
		State._advance_playback()
		expect(State.current_frame == 1, "frame advances down the tag")
		State._advance_playback()
		expect(State.current_frame == 0, "frame advances to the tag start")
		State._advance_playback()
		expect(State.current_frame == 2, "frame wraps to the tag end")
		State.stop()
	)

	step("When the user plays a ping-pong tag over frames 1-3", func():
		State.document.add_tag("Ping", 0, 2, AnimationTag.LoopMode.PING_PONG, 0)
		State.current_frame = 0
		State.play_tag(2)
	)

	step("Then the frames ping-pong within the tag", func():
		expect(State.current_frame == 0, "playback starts at the tag start")
		State._advance_playback()
		expect(State.current_frame == 1, "frame advances forward")
		State._advance_playback()
		expect(State.current_frame == 2, "frame reaches the tag end")
		State._advance_playback()
		expect(State.current_frame == 1, "frame bounces back down")
		State._advance_playback()
		expect(State.current_frame == 0, "frame returns to the tag start")
		State.stop()
	)

	step("When the user plays a finite-repeat forward tag", func():
		State.document.add_tag("Fin", 0, 1, AnimationTag.LoopMode.FORWARD, 2)
		State.current_frame = 0
		State.play_tag(3)
	)

	step("Then playback stops after the repeats", func():
		State._advance_playback()
		State._advance_playback()
		State._advance_playback()
		State._advance_playback()
		expect(not State.is_playing, "playback stops after the repeats")
		expect(State.current_frame == 1, "playback rests on the final frame")
	)

	step("When the user plays an infinite-repeat forward tag", func():
		State.document.add_tag("Inf", 0, 1, AnimationTag.LoopMode.FORWARD, 0)
		State.current_frame = 0
		State.play_tag(4)
	)

	step("Then playback keeps looping", func():
		State._advance_playback()
		State._advance_playback()
		State._advance_playback()
		expect(State.is_playing, "playback keeps running")
		State.stop()
	)
