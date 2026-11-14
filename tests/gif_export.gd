extends "res://tests/test.gd"

# GIF export: the encoder stream, the palette, the tag loop modes, the export
# workspace path, and cancellation. The encoder cases run headless. The render
# cases need a visible window, like the sprite sheet cases.

const GIF_ENCODER := preload("res://plugins/Export/GifEncoder.gd")
const GIF_READER := preload("res://tests/gif_reader.gd")

var exporter: Node
var gif_path := ""
var cancel_path := ""
var original_lighting: Dictionary = {}
var renderer_count := 0
var cancelled_result: Error = OK
var cancelled_done := false


func _ready() -> void:
	timeout = 20.0
	test("the GIF encoder writes a decodable animation", _encoder_run, "gif_encoder")
	test("the GIF palette keeps document colors and resets LZW", _palette_run, "gif_palette")
	test("GIF frame sequences follow tag loop modes", _sequence_run, "gif_sequence")
	if DisplayServer.get_name() != "headless":
		timeout = 30.0
		test("the export workspace writes the tagged animation as a GIF", _export_run, "gif_export")
		test("a cancelled GIF export writes no file", _cancel_run, "gif_cancel")


func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	State.clear_selection()
	State.current_frame = 0
	exporter = plugin("ExportPlugin")
	exporter.show_editor_tab()
	exporter._model_playback.is_playing = false
	original_lighting = {}
	if is_instance_valid(exporter):
		original_lighting = exporter._model_scene.get_lighting_settings()
	gif_path = ""
	cancel_path = ""
	cancelled_result = OK
	cancelled_done = false


func after_test() -> void:
	if is_instance_valid(exporter):
		exporter._restore_export_settings()
		exporter.show_editor_tab()
		if not original_lighting.is_empty():
			exporter._model_scene.set_lighting_settings(original_lighting)
	for path in [gif_path, cancel_path]:
		if not path.is_empty() and FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _encoder_run() -> void:
	var custom := Color8(200, 100, 50)
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	image.set_pixel(0, 0, custom)
	image.set_pixel(1, 0, Color8(255, 0, 0))
	image.set_pixel(0, 1, Color8(0, 0, 255))
	var base_colors := PackedColorArray([custom, Color8(255, 0, 0), Color8(0, 0, 255)])
	step("Given one image with a custom color, red, blue, and transparency", func():
		expect(GIF_ENCODER.lzw_encode(PackedByteArray([0]), 8) == PackedByteArray([0, 1, 4, 4]), "the LZW writer emits the known code stream")
	)
	var encoder = GIF_ENCODER.new(2, 2, 0, base_colors)
	expect(encoder.add_frame(image, 100) == OK, "the encoder accepts the frame")
	var bytes: PackedByteArray = encoder.finish()
	step("When the GIF is decoded", func():
		var reader = GIF_READER.new()
		expect(reader.read(bytes), "the GIF parses")
		expect(reader.width == 2 and reader.height == 2, "the GIF keeps the canvas size")
		expect(reader.frames.size() == 1, "the GIF contains one frame")
		expect(reader.loop_count == 0, "zero repeats means an endless loop")
		var frame: Dictionary = reader.frames[0]
		var decoded: Image = frame.image
		expect(frame.delay == 10, "the frame delay is written in hundredths of a second")
		expect(frame.disposal == 2, "the frame clears its area for the next frame")
		expect(frame.transparent == 0, "color index zero is transparent")
		expect(decoded.get_data() == image.get_data(), "the decoded pixels keep the source colors")
	)
	step("When the encoder writes a finite loop and a play-once file", func():
		var finite = GIF_ENCODER.new(2, 2, 3, base_colors)
		finite.add_frame(image, 250)
		var finite_reader = GIF_READER.new()
		expect(finite_reader.read(finite.finish()) and finite_reader.loop_count == 3, "a positive loop count is preserved")
		var once = GIF_ENCODER.new(2, 2, -1, base_colors)
		once.add_frame(image, 100)
		var once_reader = GIF_READER.new()
		expect(once_reader.read(once.finish()) and once_reader.loop_count == -1, "a play-once GIF omits the loop extension")
	)


func _palette_run() -> void:
	step("Given one document color", func():
		var color := Color8(200, 100, 50)
		var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		image.fill(color)
		var encoder = GIF_ENCODER.new(1, 1, -1, PackedColorArray([color]))
		encoder.add_frame(image, 100)
		var reader = GIF_READER.new()
		expect(reader.read(encoder.finish()), "the custom-color GIF parses")
		var decoded: Image = reader.frames[0].image
		expect(decoded.get_pixel(0, 0) == color, "the document palette color stays exact")
	)
	step("Given opaque black and a transparent placeholder", func():
		var black := Color8(0, 0, 0)
		var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		image.fill(black)
		var encoder = GIF_ENCODER.new(1, 1, -1, PackedColorArray([black]))
		encoder.add_frame(image, 100)
		var reader = GIF_READER.new()
		expect(reader.read(encoder.finish()), "the black GIF parses")
		var decoded: Image = reader.frames[0].image
		expect(decoded.get_pixel(0, 0) == black, "opaque black stays black")
	)
	step("When an image holds more colors than the LZW dictionary", func():
		var size := 128
		var colors := PackedColorArray()
		for index in range(1, 256):
			colors.append(Color8(index, 0, 0))
		var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
		image.fill(Color.BLACK)
		for y in size:
			for x in size:
				var shade := 1 + ((x * 7 + y * 13 + x * y) % 255)
				image.set_pixel(x, y, Color8(shade, 0, 0))
		var encoder = GIF_ENCODER.new(size, size, 0, colors)
		expect(encoder.add_frame(image, 100) == OK, "the large frame is accepted")
		var bytes: PackedByteArray = encoder.finish()
		var reader = GIF_READER.new()
		expect(reader.read(bytes), "the large GIF parses")
		expect(reader.frames.size() == 1, "the large GIF contains one frame")
		var decoded: Image = reader.frames[0].image
		expect(decoded.get_data() == image.get_data(), "the LZW table reset preserves every pixel")
		expect(bytes.slice(0, 6).get_string_from_ascii() == "GIF89a", "the large file starts with the GIF header")
		expect(bytes[bytes.size() - 1] == 0x3B, "the large file ends with the trailer")
	)


func _sequence_run() -> void:
	var tag := AnimationTag.new()
	tag.from = 0
	tag.to = 2
	tag.repeats = 0
	step("Given one three-frame tag", func():
		expect(exporter.gif_frame_indices(0, 2, tag) == PackedInt32Array([0, 1, 2]), "forward order keeps the frames")
		tag.loop_mode = AnimationTag.LoopMode.REVERSE
		expect(exporter.gif_frame_indices(0, 2, tag) == PackedInt32Array([2, 1, 0]), "reverse order flips the frames")
		tag.loop_mode = AnimationTag.LoopMode.PING_PONG
		expect(exporter.gif_frame_indices(0, 2, tag) == PackedInt32Array([0, 1, 2, 1]), "ping-pong repeats the inner frames")
		tag.loop_mode = AnimationTag.LoopMode.PING_PONG_REVERSE
		expect(exporter.gif_frame_indices(0, 2, tag) == PackedInt32Array([2, 1, 0, 1]), "reverse ping-pong starts at the last frame")
		expect(exporter.gif_frame_indices(1, 1, tag) == PackedInt32Array([1]), "a one-frame tag stays one frame")
	)
	step("Then the repeat count sets the GIF loop", func():
		expect(exporter.gif_loop_count(null) == 0, "no tag loops forever")
		tag.repeats = 0
		expect(exporter.gif_loop_count(tag) == 0, "zero repeats loops forever")
		tag.repeats = 1
		expect(exporter.gif_loop_count(tag) == -1, "one repeat omits the loop extension")
		tag.repeats = 2
		expect(exporter.gif_loop_count(tag) == 1, "two repeats adds one extra loop")
		tag.repeats = 5
		expect(exporter.gif_loop_count(tag) == 4, "five repeats adds four extra loops")
	)


func _export_run() -> void:
	gif_path = "user://voxel_gif_%s.gif" % Time.get_ticks_usec()
	step("Given three colored frames and a ping-pong tag", func():
		State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.document.add_frame()
		State.document.set_cell(1, Vector3i.ZERO, VoxelFrame.material(Color.BLUE))
		State.document.frames[0].delay_ms = 100
		State.document.frames[1].delay_ms = 250
		State.document.add_frame()
		State.document.set_cell(2, Vector3i.ZERO, VoxelFrame.material(Color.GREEN))
		State.document.frames[2].delay_ms = 50
		var tag_index := State.document.add_tag("Ping", 0, 2, AnimationTag.LoopMode.PING_PONG, 2)
		State.frames_changed.emit()
		State.tag_changed.emit()
		var lighting: Dictionary = exporter._model_scene.get_lighting_settings()
		lighting.shaded = false
		exporter._model_scene.set_lighting_settings(lighting)
		var selector: OptionButton = exporter._sheet_settings.get_node("FrameRow/Frames")
		selector.select(tag_index + 1)
		selector.item_selected.emit(tag_index + 1)
		exporter._sheet_settings.get_node("ViewRow/View").select(2)
		exporter._sheet_settings.get_node("ViewRow/View").item_selected.emit(2)
		exporter._sheet_settings.get_node("ViewRow/Perspective").set_pressed_no_signal(false)
		exporter._sheet_settings.get_node("ViewRow/Center").set_pressed_no_signal(true)
		exporter._sheet_settings.get_node("SizeRow/Size").set_value_no_signal(32)
		State.current_frame = 1
		renderer_count = VoxelRenderer._active_renderer_count
		expect(exporter._selected_frames() == Vector2i(0, 2), "the selected tag covers every frame")
		expect(exporter._controls.get_node("Gif").text == "GIF", "the sheet panel provides a GIF action")
		expect(exporter._gif_dialog.filters.size() > 0 and exporter._gif_dialog.filters[0].begins_with("*.gif"), "the GIF dialog filters GIF files")
	)
	var error: Error = await exporter.export_gif(gif_path)
	step("Then the GIF follows the tag order and frame delays", func():
		expect(error == OK, "the GIF export completes")
		var bytes := FileAccess.get_file_as_bytes(gif_path)
		var reader = GIF_READER.new()
		expect(reader.read(bytes), "the exported GIF parses")
		expect(reader.width == 32 and reader.height == 32, "the GIF uses the selected tile size")
		expect(reader.frames.size() == 4, "ping-pong exports four frames for three source frames")
		expect(reader.loop_count == 1, "two tag repeats write one extra GIF loop")
		var expected_delays: Array[int] = [10, 25, 5, 25]
		var expected_hues: Array[String] = ["r", "b", "g", "b"]
		var actual_delays: Array[int] = []
		var actual_hues: Array[String] = []
		for frame: Dictionary in reader.frames:
			actual_delays.append(int(frame.delay))
			var image: Image = frame.image
			actual_hues.append(_dominant_hue(image))
		expect(actual_delays == expected_delays, "each GIF frame keeps its document delay")
		expect(actual_hues == expected_hues, "the GIF follows the ping-pong frame order")
		expect(State.document.frames.size() == 3 and State.current_frame == 1, "the export leaves the document and frame in place")
		expect(not State.edit_busy(), "the export releases editing")
		expect(State.get_activity() == null, "the export releases its activity")
		expect(exporter._export_viewport == null, "the export releases its render viewport")
		expect(VoxelRenderer._active_renderer_count == renderer_count, "the export releases its temporary renderer")
	)


func _cancel_run() -> void:
	cancel_path = "user://voxel_gif_cancel_%s.gif" % Time.get_ticks_usec()
	renderer_count = VoxelRenderer._active_renderer_count
	step("Given a multi-frame export", func():
		State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.document.add_frame()
		State.document.set_cell(1, Vector3i.ZERO, VoxelFrame.material(Color.BLUE))
		State.document.add_frame()
		State.document.set_cell(2, Vector3i.ZERO, VoxelFrame.material(Color.GREEN))
		State.frames_changed.emit()
		exporter._sheet_settings.get_node("ViewRow/View").select(2)
		exporter._sheet_settings.get_node("ViewRow/View").item_selected.emit(2)
		exporter._sheet_settings.get_node("SizeRow/Size").set_value_no_signal(64)
	)
	step("When the user cancels the render", func():
		_start_cancelled_export()
		expect(State.edit_busy(), "the GIF render reports foreground work")
		main.get_node("%StatusBar").get_node("Activity/Cancel").pressed.emit()
	)
	while not cancelled_done:
		await get_tree().process_frame
	step("Then the cancel writes no file and releases resources", func():
		expect(cancelled_result == ERR_BUSY, "the cancelled GIF export reports cancellation")
		expect(not FileAccess.file_exists(cancel_path), "the cancelled export writes no partial GIF")
		expect(not State.edit_busy(), "cancellation releases editing")
		expect(exporter._export_viewport == null, "cancellation releases its render viewport")
		expect(VoxelRenderer._active_renderer_count == renderer_count, "cancellation releases its temporary renderer")
	)


func _start_cancelled_export() -> void:
	cancelled_result = await exporter.export_gif(cancel_path)
	cancelled_done = true


func _dominant_hue(image: Image) -> String:
	var red := 0
	var green := 0
	var blue := 0
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if color.a < 0.5:
				continue
			if color.r > color.g and color.r > color.b:
				red += 1
			elif color.g > color.r and color.g > color.b:
				green += 1
			elif color.b > color.r and color.b > color.g:
				blue += 1
	if red == 0 and green == 0 and blue == 0:
		return ""
	if red >= green and red >= blue:
		return "r"
	if green >= blue:
		return "g"
	return "b"
