extends "res://tests/test.gd"


func _ready() -> void:
	test("can shorten and shift tags when frames are removed", _run)


func _run() -> void:
	step("Given five frames and a tag over frames 2-4", func():
		State.document.add_frame()
		State.document.add_frame()
		State.document.add_frame()
		State.document.add_frame()
		State.document.add_tag("Middle", 1, 3)
	)

	step("When the user removes frame three", func():
		State.current_frame = 2
		State.delete_frame()
	)

	step("Then the tag covers frames 2-3", func():
		var tag: AnimationTag = State.document.tags[1]
		expect(State.document.frames.size() == 4, "four frames remain")
		expect(tag.from == 1 and tag.to == 2, "the tag covers frames 2-3")
		expect(tag.frame_count() == 2, "the tag holds two frames")
	)

	step("When the user undoes the frame removal", func():
		State.undo_redo.undo()
	)

	step("Then the frame returns and the tag range is restored", func():
		var tag: AnimationTag = State.document.tags[1]
		expect(State.document.frames.size() == 5, "five frames return")
		expect(tag.from == 1 and tag.to == 3, "the tag covers frames 2-4 again")
	)

	step("When the user redoes the frame removal", func():
		State.undo_redo.redo()
	)

	step("Then the frame is removed and the tag is trimmed again", func():
		var tag: AnimationTag = State.document.tags[1]
		expect(State.document.frames.size() == 4, "four frames remain")
		expect(tag.from == 1 and tag.to == 2, "the tag covers frames 2-3 again")
	)

	step("When the user plays the adjusted tag", func():
		State.current_frame = 1
		State.play_tag(1)
	)

	step("Then playback wraps within the shorter tag", func():
		State._advance_playback()
		expect(State.current_frame == 2, "playback reaches the new end")
		State._advance_playback()
		expect(State.current_frame == 1, "playback wraps to the new start")
		State.stop()
	)

	step("When the user removes a frame before the tag", func():
		State.current_frame = 0
		State.delete_frame()
	)

	step("Then the tag shifts back over frames 1-2", func():
		var tag: AnimationTag = State.document.tags[1]
		expect(State.document.frames.size() == 3, "three frames remain")
		expect(tag.from == 0 and tag.to == 1, "the tag covers frames 1-2")
		expect(tag.frame_count() == 2, "the tag still holds two frames")
	)

	step("Given a tag over a single frame and removing that frame", func():
		State.document.add_tag("One", 2, 2)
		State.current_frame = 2
		State.delete_frame()
	)

	step("Then the tag stays valid", func():
		var tag: AnimationTag = State.document.tags[2]
		expect(State.document.frames.size() == 2, "two frames remain")
		expect(tag.frame_count() == 1, "the tag still holds one frame")
	)
