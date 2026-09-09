extends "res://tests/test.gd"


func _ready() -> void:
	test("can group frames into animation tags with a default tag present", _run)


func _run() -> void:
	step("Given a document with three frames", func():
		State.document.add_frame()
		State.document.add_frame()
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
