extends "res://tests/test.gd"

var play_button: Button
var idle_size := Vector2.ZERO


func _ready() -> void:
	test("can play the voxel animation", _run)


func _run() -> void:
	step("Given a document with two distinct frames", func():
		State.document.add_frame()
		State.document.set_cell(1, Vector3i(9, 0, 9), VoxelFrame.material(State.current_color))
		State.document.frames[0].delay_ms = 250
		State.document.frames[1].delay_ms = 250
		play_button = main.find_child("BottomDock", true, false).get_node("%Play")
		idle_size = play_button.size
	)

	step("When the user plays the animation", func():
		play_button.button_pressed = true
	)

	var seen := {}
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < 800:
		await get_tree().process_frame
		seen[State.current_frame] = true
	step("Then the animation plays with stable controls", func():
		expect(seen.size() > 1, "the displayed frame changes while playing")
		expect(play_button.size == idle_size, "the Play button keeps its size during playback")
	)
	step("When the user pauses the animation", func():
		play_button.button_pressed = false
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the controls return to their idle state", func():
		expect(not State.is_playing, "the animation is paused")
		expect(play_button.size == idle_size, "the Play button keeps its size after playback")
	)
