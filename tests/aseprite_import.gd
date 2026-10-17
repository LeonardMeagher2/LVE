extends "res://tests/test.gd"

var importer: Node
var png_path := ""
var json_path := ""


func _ready() -> void:
	timeout = 30.0
	test("matching Aseprite JSON imports animation frames, timing, trim offsets, and tags", _run)


func _run() -> void:
	step("Given a hash-format sheet with two trimmed frames", func():
		importer = plugin("ImageImportPlugin")
		State.floor_axis = Vector3.Axis.AXIS_Y
		var image := Image.create(2, 1, false, Image.FORMAT_RGBA8)
		image.set_pixel(0, 0, Color.RED)
		image.set_pixel(1, 0, Color.BLUE)
		png_path = "user://voxel_aseprite_%s.png" % Time.get_ticks_usec()
		json_path = png_path.get_basename() + ".json"
		expect(image.save_png(png_path) == OK, "the trimmed PNG fixture is saved")
		var data := {
			"frames": {
				"frame 2": {"frame": {"x": 0, "y": 0, "w": 1, "h": 1}, "sourceSize": {"w": 6, "h": 4}, "spriteSourceSize": {"x": 1, "y": 1, "w": 1, "h": 1}, "trimmed": true, "duration": 90},
				"frame 10": {"frame": {"x": 1, "y": 0, "w": 1, "h": 1}, "sourceSize": {"w": 6, "h": 4}, "spriteSourceSize": {"x": 3, "y": 2, "w": 1, "h": 1}, "trimmed": true, "duration": 180}
			},
			"meta": {"frameTags": [
				{"name": "Reverse", "from": 0, "to": 1, "direction": "reverse", "repeat": "2"},
				{"name": "BackBounce", "from": 0, "to": 1, "direction": "pingpong_reverse", "repeat": "1"},
				{"name": "Once", "from": 0, "to": 1, "direction": "pingpong", "data": "no_loop"}
			]}
		}
		var file := FileAccess.open(json_path, FileAccess.WRITE)
		file.store_string(JSON.stringify(data, "", false))
		file.close()
	)
	var error: Error = await importer.import_image(png_path)
	step("Then frame order and source-canvas motion are preserved", func():
		expect(error == OK, "the trimmed hash animation opens")
		expect(State.document.frames.size() == 2, "both trimmed frames are present")
		expect(State.document.frames[0].get_color(Vector3i(-1, 0, -1)) == Color.RED, "the first trimmed frame keeps its source position")
		expect(State.document.frames[1].get_color(Vector3i(1, 0, 0)) == Color.BLUE, "the second trimmed frame keeps its motion offset")
		expect(State.document.frames[0].delay_ms == 90 and State.document.frames[1].delay_ms == 180, "hash frame order retains both durations")
		expect(State.document.palette == [VoxelFrame.material(Color.RED), VoxelFrame.material(Color.BLUE)], "the palette includes colors from both animation frames")
		expect(State.document.tags[0].loop_mode == AnimationTag.LoopMode.REVERSE and State.document.tags[0].repeats == 2, "the reverse tag retains its direction and repeat count")
		expect(State.document.tags[1].loop_mode == AnimationTag.LoopMode.PING_PONG_REVERSE, "reverse ping-pong is preserved")
		expect(State.document.tags[2].loop_mode == AnimationTag.LoopMode.PING_PONG and State.document.tags[2].repeats == 1, "the custom no_loop marker creates a one-shot ping-pong tag")
		var center := State.document.bounds().get_center().abs()
		expect(center.x <= 0.5 and center.y <= 0.5 and center.z <= 0.5, "the animation uses one shared origin-centered offset")
	)
	step("When the reverse ping-pong tag plays once", func():
		State.active_tag = 1
		State.is_playing = true
		expect(State.current_frame == 1, "reverse ping-pong starts at the final frame")
		State.playback.advance()
		expect(State.current_frame == 0, "reverse ping-pong first moves backward")
		State.playback.advance()
		expect(State.current_frame == 1, "reverse ping-pong returns to its starting frame")
		State.playback.advance()
		expect(not State.is_playing, "the finite reverse ping-pong tag stops after its cycle")
	)
	step("When the same sprite sheet is written with array-format metadata", func():
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(json_path))
		data.frames = data.frames.values()
		var file := FileAccess.open(json_path, FileAccess.WRITE)
		file.store_string(JSON.stringify(data))
		file.close()
	)
	error = await importer.import_image(png_path)
	step("Then array metadata preserves the same animation", func():
		expect(error == OK, "the array-format animation opens")
		expect(State.document.frames.size() == 2, "array metadata restores both frames")
		expect(State.document.frames[0].get_color(Vector3i(-1, 0, -1)) == Color.RED, "array metadata restores the first frame position")
		expect(State.document.frames[1].delay_ms == 180, "array metadata preserves the second frame duration")
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(png_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(json_path))
