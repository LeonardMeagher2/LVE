extends "res://tests/test.gd"


const GIF_READER := preload("res://tests/gif_reader.gd")

var exporter: Node
var sheet_path := ""
var gif_path := ""
var alone_path := ""
var original_lighting: Dictionary = {}


func _ready() -> void:
	timeout = 40.0
	test("the sprite sheet and the GIF keep one frame anchor", _anchor_run, "frame_anchor")
	test("a blank frame does not shrink the shared frame box", _blank_run, "frame_anchor_blank")
	test("the sprite sheet and the GIF show the visible layer composite", _layers_run, "export_layers")


func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	State.clear_selection()
	State.current_frame = 0
	exporter = plugin("ExportPlugin")
	exporter.show_editor_tab()
	exporter._model_playback.is_playing = false
	exporter._model_camera.is_orthogonal = true
	exporter._model_camera.size = 16.0
	exporter._sheet_settings.get_node("ViewRow/Center").set_pressed_no_signal(false)
	exporter._sheet_settings.get_node("TurntableRow/Turntable").set_pressed_no_signal(false)
	original_lighting = exporter._model_scene.get_lighting_settings()
	var lighting := original_lighting.duplicate()
	lighting.shaded = false
	exporter._model_scene.set_lighting_settings(lighting)


func after_test() -> void:
	if is_instance_valid(exporter):
		exporter._restore_export_settings()
		exporter.show_editor_tab()
		if not original_lighting.is_empty():
			exporter._model_scene.set_lighting_settings(original_lighting)
	for path in [sheet_path, gif_path, alone_path]:
		if not path.is_empty() and FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _anchor_run() -> void:
	sheet_path = "user://frame_anchor_%s.png" % Time.get_ticks_usec()
	gif_path = "user://frame_anchor_%s.gif" % Time.get_ticks_usec()
	step("Given three frames with one voxel at a different x", func():
		State.document.set_cell(0, Vector3i(-6, 0, 0), VoxelFrame.material(Color.RED))
		State.document.add_frame()
		State.document.set_cell(1, Vector3i(0, 0, 0), VoxelFrame.material(Color.RED))
		State.document.add_frame()
		State.document.set_cell(2, Vector3i(6, 0, 0), VoxelFrame.material(Color.RED))
		State.frames_changed.emit()
	)
	var sheet_error: Error = await exporter.export_sprite_sheet(sheet_path, 0, 2, 64, 0, false)
	step("Then the sheet tiles keep the voxel positions", func():
		expect(sheet_error == OK, "the sheet exports")
		var image := Image.new()
		expect(image.load(sheet_path) == OK, "the sheet loads")
		var rects: Array = exporter.sheet_layout(3, 64).rects
		var xs: Array[float] = []
		for index in 3:
			xs.append(_centroid_x(image, rects[index]))
		expect(xs[1] - xs[0] > 2.0, "the middle frame sits right of the first")
		expect(xs[2] - xs[1] > 2.0, "the last frame sits right of the middle")
		expect(absf((xs[2] - xs[1]) - (xs[1] - xs[0])) <= 1.0, "the frames keep one step size")
	)
	var gif_error: Error = await exporter.export_gif_settings(gif_path, {
		"first_frame": 0,
		"last_frame": 2,
		"tile_size": 64,
		"view": "current",
		"views": 1,
		"center": false,
	})
	step("Then the GIF frames use the same anchor as the sheet", func():
		expect(gif_error == OK, "the GIF exports")
		var reader = GIF_READER.new()
		expect(reader.read(FileAccess.get_file_as_bytes(gif_path)), "the GIF parses")
		var frames: Array = reader.compose()
		expect(frames.size() == 3, "the GIF holds three frames")
		var xs: Array[float] = []
		for frame in frames:
			xs.append(_centroid_x(frame, Rect2i(Vector2i.ZERO, Vector2i(64, 64))))
		var sheet := Image.new()
		sheet.load(sheet_path)
		var rects: Array = exporter.sheet_layout(3, 64).rects
		for index in 3:
			expect(absf(xs[index] - _centroid_x(sheet, rects[index])) <= 1.0, "sheet and GIF share the frame position")
	)


func _blank_run() -> void:
	sheet_path = "user://frame_blank_%s.png" % Time.get_ticks_usec()
	alone_path = "user://frame_blank_%s_single.png" % Time.get_ticks_usec()
	step("Given a block frame, a blank frame, and the block again", func():
		exporter._model_camera.size = 12.0
		for x in range(-1, 2):
			for y in range(-1, 2):
				for z in range(-1, 2):
					State.document.set_cell(0, Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		State.document.add_frame()
		State.document.add_frame()
		for x in range(-1, 2):
			for y in range(-1, 2):
				for z in range(-1, 2):
					State.document.set_cell(2, Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		State.frames_changed.emit()
	)
	var blank_error: Error = await exporter.export_sprite_sheet(sheet_path, 0, 2, 64, 0, false)
	step("Then the blank frame stays transparent and the block keeps its size", func():
		expect(blank_error == OK, "the three-frame sheet exports")
	)
	var alone_error: Error = await exporter.export_sprite_sheet(alone_path, 0, 0, 64, 0, false)
	step("Then the shared box follows the drawn frames only", func():
		expect(alone_error == OK, "the single-frame sheet exports")
		var three := Image.new()
		var alone := Image.new()
		expect(three.load(sheet_path) == OK and alone.load(alone_path) == OK, "both sheets load")
		expect(_visible_pixels(three, Rect2i(0, 0, 64, 64)) == _visible_pixels(alone, Rect2i(0, 0, 64, 64)), "the blank frame does not change the drawn size")
		var rects: Array = exporter.sheet_layout(3, 64).rects
		expect(_visible_pixels(three, rects[1]) == 0, "the blank frame tile stays transparent")
	)


func _layers_run() -> void:
	sheet_path = "user://layer_sheet_%s.png" % Time.get_ticks_usec()
	gif_path = "user://layer_gif_%s.gif" % Time.get_ticks_usec()
	step("Given two visible layers and one hidden layer", func():
		var document := State.document
		document.set_cell(0, Vector3i(-3, 0, 0), VoxelFrame.material(Color.RED))
		document.layers.append(document.make_layer("Top"))
		document.edit_layer = 1
		document.set_cell(0, Vector3i(3, 0, 0), VoxelFrame.material(Color.BLUE))
		document.layers.append(document.make_layer("Hidden"))
		document.edit_layer = 2
		document.set_cell(0, Vector3i(0, 3, 0), VoxelFrame.material(Color.GREEN))
		document.layers[2].visible = false
		document.invalidate_bounds()
		State.set_active_layer(0)
	)
	var sheet_error: Error = await exporter.export_sprite_sheet(sheet_path, 0, 0, 64, 0, false)
	step("Then the sheet shows both visible layers and hides the hidden layer", func():
		expect(sheet_error == OK, "the sheet exports")
		var image := Image.new()
		expect(image.load(sheet_path) == OK, "the sheet loads")
		var rect := Rect2i(Vector2i.ZERO, Vector2i(64, 64))
		expect(_channel_pixels(image, rect, 0) > 0, "the lower layer renders")
		expect(_channel_pixels(image, rect, 2) > 0, "the upper layer renders")
		expect(_channel_pixels(image, rect, 1) == 0, "the hidden layer stays out")
	)
	var gif_error: Error = await exporter.export_gif_settings(gif_path, {
		"first_frame": 0,
		"last_frame": 0,
		"tile_size": 64,
		"view": "current",
		"views": 1,
		"center": false,
	})
	step("Then the GIF also shows both visible layers", func():
		expect(gif_error == OK, "the GIF exports")
		var reader = GIF_READER.new()
		expect(reader.read(FileAccess.get_file_as_bytes(gif_path)), "the GIF parses")
		var frames: Array = reader.compose()
		expect(frames.size() == 1, "the GIF holds one frame")
		if frames.size() != 1:
			return
		var image: Image = frames[0]
		var rect := Rect2i(Vector2i.ZERO, Vector2i(64, 64))
		expect(_channel_pixels(image, rect, 0) > 0, "the lower layer renders in the GIF")
		expect(_channel_pixels(image, rect, 2) > 0, "the upper layer renders in the GIF")
		expect(_channel_pixels(image, rect, 1) == 0, "the hidden layer stays out of the GIF")
	)


func _channel_pixels(image: Image, rect: Rect2i, channel: int) -> int:
	var count := 0
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			var pixel := image.get_pixel(x, y)
			if pixel.a <= 0.5:
				continue
			var values := [pixel.r, pixel.g, pixel.b]
			var value: float = values[channel]
			values.remove_at(channel)
			if value > 0.3 and value > float(values[0]) * 1.4 and value > float(values[1]) * 1.4:
				count += 1
	return count


func _centroid_x(image: Image, rect: Rect2i) -> float:
	var total := 0.0
	var count := 0
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			if image.get_pixel(x, y).a > 0.5:
				total += float(x - rect.position.x)
				count += 1
	if count == 0:
		return -1.0
	return total / count


func _visible_pixels(image: Image, rect: Rect2i) -> int:
	var count := 0
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			if image.get_pixel(x, y).a > 0.5:
				count += 1
	return count
