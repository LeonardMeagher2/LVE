extends "res://tests/test.gd"

# One process runs the tag and frame tests. Each test keeps the steps and checks
# of its original scene. The user arguments after `--` name the tests to run, so
# an old scene name still selects its own test.

const FRAME_DELAY_MS := 100000


func _ready() -> void:
	test("can group frames into animation tags with a default tag present", _tags, "tags")
	test("can play a tag's frames with its loop mode and repeats", _tag_playback, "tag_playback")
	test("can shorten and shift tags when frames are removed", _tag_frame_remove, "tag_frame_remove")
	test("can add a frame to the document", _frames, "frames")


# Each test starts from a fresh one-frame document with its default tag.
func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.current_frame = 0
	State.active_tag = 0


# Shared fixture: add frames beside the first one.
func _add_frames(extra: int) -> void:
	for i in extra:
		State.document.add_frame()


func _tags() -> void:
	step("Given a document with three frames", func():
		_add_frames(2)
	)

	step("Then a default tag covers all the frames", func():
		expect(State.document.tags.size() == 1, "the document holds one default tag")
		var base: AnimationTag = State.document.tags[0]
		expect(base.name == "Default", "the default tag is named Default")
		expect(base.from == 0 and base.to == 2, "the default tag covers all frames")
		expect(base.loop_mode == AnimationTag.LoopMode.FORWARD, "the default tag plays forward")
	)

	step("When the user adds a ping-pong tag over the last two frames", func():
		State.document.add_tag("Spin", 1, 2, AnimationTag.LoopMode.PING_PONG, 3)
	)

	step("Then the tag holds the range, loop mode, and repeats", func():
		expect(State.document.tags.size() == 2, "the document holds two tags")
		var tag: AnimationTag = State.document.tags[1]
		expect(tag.name == "Spin", "tag has a name")
		expect(tag.from == 1 and tag.to == 2, "tag covers the last two frames")
		expect(tag.loop_mode == AnimationTag.LoopMode.PING_PONG, "tag ping-pongs")
		expect(tag.repeats == 3, "tag repeats three times")
		expect(tag.frame_count() == 2, "tag holds two frames")
	)


func _tag_playback() -> void:
	step("Given a document with four frames", func():
		_add_frames(3)
		for frame in State.document.frames:
			frame.delay_ms = FRAME_DELAY_MS
	)

	step("When the user plays a forward tag over frames 2-4", func():
		State.document.add_tag("Fwd", 1, 3, AnimationTag.LoopMode.FORWARD, 0)
		State.current_frame = 2
		State.play_tag(1)
	)

	step("Then playback starts at the tag boundary and wraps", func():
		expect(State.current_frame == 1, "playback starts at the tag start")
		State.playback.advance()
		expect(State.current_frame == 2, "playback advances inside the tag")
		State.playback.advance()
		expect(State.current_frame == 3, "frame advances to the tag end")
		State.playback.advance()
		expect(State.current_frame == 1, "frame wraps to the tag start")
		State.stop()
	)

	step("When the user plays a reverse tag over frames 1-3", func():
		State.document.add_tag("Rev", 0, 2, AnimationTag.LoopMode.REVERSE, 0)
		State.current_frame = 2
		State.play_tag(2)
	)

	step("Then the frames advance in reverse and wrap", func():
		expect(State.current_frame == 2, "playback starts at the tag end")
		State.playback.advance()
		expect(State.current_frame == 1, "frame advances down the tag")
		State.playback.advance()
		expect(State.current_frame == 0, "frame advances to the tag start")
		State.playback.advance()
		expect(State.current_frame == 2, "frame wraps to the tag end")
		State.stop()
	)

	step("When the user plays a ping-pong tag over frames 1-3", func():
		State.document.add_tag("Ping", 0, 2, AnimationTag.LoopMode.PING_PONG, 0)
		State.current_frame = 0
		State.play_tag(3)
	)

	step("Then the frames ping-pong within the tag", func():
		expect(State.current_frame == 0, "playback starts at the tag start")
		State.playback.advance()
		expect(State.current_frame == 1, "frame advances forward")
		State.playback.advance()
		expect(State.current_frame == 2, "frame reaches the tag end")
		State.playback.advance()
		expect(State.current_frame == 1, "frame bounces back down")
		State.playback.advance()
		expect(State.current_frame == 0, "frame returns to the tag start")
		State.stop()
	)

	step("When the user plays a finite-repeat forward tag", func():
		State.document.add_tag("Fin", 0, 1, AnimationTag.LoopMode.FORWARD, 2)
		State.current_frame = 0
		State.play_tag(4)
	)

	step("Then playback stops after the repeats", func():
		State.playback.advance()
		State.playback.advance()
		State.playback.advance()
		State.playback.advance()
		expect(not State.is_playing, "playback stops after the repeats")
		expect(State.current_frame == 1, "playback rests on the final frame")
	)

	step("When the user plays an infinite-repeat forward tag", func():
		State.document.add_tag("Inf", 0, 1, AnimationTag.LoopMode.FORWARD, 0)
		State.current_frame = 0
		State.play_tag(5)
	)

	step("Then playback keeps looping", func():
		State.playback.advance()
		State.playback.advance()
		State.playback.advance()
		expect(State.is_playing, "playback keeps running")
		State.stop()
	)
	step("When the selected tag changes during playback", func():
		State.play_tag(1)
		State.current_frame = 3
		State.active_tag = 4
	)
	step("Then playback snaps into the selected tag range", func():
		expect(State.current_frame == 0, "switching tags starts at the new tag boundary")
		var bounded := true
		for _tick in 8:
			State.playback.advance()
			bounded = bounded and State.current_frame >= 0 and State.current_frame <= 1
		expect(bounded, "playback stays inside the selected tag")
		State.stop()
	)
	step("When a single-frame tag is selected during playback", func():
		var index := State.document.add_tag("Single", 2, 2)
		State.play_tag(1)
		State.active_tag = index
		State.playback.advance()
	)
	step("Then the selected single frame is displayed", func():
		expect(State.current_frame == 2, "the single-frame tag snaps to its only frame")
		State.stop()
	)
	step("When a stale tag range extends past the document", func():
		State.document.tags[1].to = 100
		State.play_tag(1)
	)
	step("Then playback exposes only valid frames", func():
		var valid := true
		for _tick in 8:
			State.playback.advance()
			valid = valid and State.get_current_voxel_frame() != null
		expect(valid, "every displayed playback frame exists")
		State.stop()
	)


func _tag_frame_remove() -> void:
	step("Given five frames and a tag over frames 2-4", func():
		_add_frames(4)
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
		State.playback.advance()
		expect(State.current_frame == 2, "playback reaches the new end")
		State.playback.advance()
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


func _frames() -> void:
	step("Given an editor with a fresh document", func():
		expect(State != null, "editor state exists")
	)

	step("When the user adds a frame", func():
		State.add_frame()
	)

	step("Then the document has 2 frames and the new frame is current", func():
		expect(State.document.frames.size() == 2, "document has 2 frames")
		expect(State.current_frame == 1, "new frame is current")
	)

	step("When the user undoes the frame", func():
		State.undo_redo.undo()
	)

	step("Then the document has 1 frame again", func():
		expect(State.document.frames.size() == 1, "document has 1 frame")
		expect(State.current_frame == 0, "the original frame is current")
	)

	step("When the user redoes the frame", func():
		State.undo_redo.redo()
	)

	step("Then the document has 2 frames again", func():
		expect(State.document.frames.size() == 2, "document has 2 frames")
		expect(State.current_frame == 1, "the new frame is current again")
	)
