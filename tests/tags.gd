extends "res://tests/test.gd"


func _ready() -> void:
	test("can group frames into animation tags", _run)


func _run() -> void:
	step("Given a document with three frames", func():
		State.document.add_frame()
		State.document.add_frame()
	)

	step("When the user adds a ping-pong tag over the last two frames", func():
		State.document.add_tag("Spin", 1, 2, AnimationTag.LoopMode.PING_PONG, 3)
	)

	step("Then the tag holds the range, loop mode, and repeats", func():
		expect(State.document.tags.size() == 1, "document has one tag")
		var tag: AnimationTag = State.document.tags[0]
		expect(tag.name == "Spin", "tag has a name")
		expect(tag.from == 1 and tag.to == 2, "tag covers the last two frames")
		expect(tag.loop_mode == AnimationTag.LoopMode.PING_PONG, "tag ping-pongs")
		expect(tag.repeats == 3, "tag repeats three times")
		expect(tag.frame_count() == 2, "tag holds two frames")
	)
