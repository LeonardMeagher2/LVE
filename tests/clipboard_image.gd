extends "res://tests/test.gd"

var clipboard: Node
var frame: VoxelFrame


func _ready() -> void:
	timeout = 30.0
	test("clipboard image pixels build a centered plane on the floor axis", _image_plane, "clipboard_image_plane")
	test("a pasted image commits its voxels and selection with one undo", _image_paste, "clipboard_image_paste")
	test("a document change rejects an image paste result", _image_cancel, "clipboard_image_cancel")
	test("clipboard image data enables Paste", _image_available, "clipboard_image_available")


func before_test() -> void:
	clipboard = plugin("ClipboardPlugin")
	clipboard.cancel_paste()
	if clipboard._paste_tool.is_inside_tree():
		clipboard.remove_editor_node(clipboard._paste_tool)
	clipboard._pattern = {}
	clipboard._selection_pattern = {}
	clipboard._material_pattern = {}
	clipboard._clipboard_text = ""
	clipboard._has_clipboard_voxels = false
	clipboard._has_clipboard_image = false
	clipboard._rejected_clipboard_text = ""
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	State.undo_redo.clear_history()
	State.clear_selection()
	State.floor_axis = Vector3.Axis.AXIS_Y


func after_test() -> void:
	clipboard.cancel_paste()
	var deadline := Time.get_ticks_msec() + 5000
	while (clipboard._image_job != null or clipboard._import_job != null) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _image_plane() -> void:
	var image := _axis_image()
	var y_pattern: Dictionary = await _convert(image, Vector3.Axis.AXIS_Y)
	step("Then the image lies on the Y floor plane", func():
		_expect_pattern(y_pattern, {
			Vector3i(-1, 0, 0): Color.RED,
			Vector3i(0, 0, 0): Color.GREEN,
			Vector3i(-1, 0, 1): Color.BLUE,
			Vector3i(0, 0, 1): Color.YELLOW,
		}, "Y")
	)
	var x_pattern: Dictionary = await _convert(image, Vector3.Axis.AXIS_X)
	step("Then the image lies on the X floor plane", func():
		_expect_pattern(x_pattern, {
			Vector3i(0, 0, -1): Color.RED,
			Vector3i(0, 0, 0): Color.GREEN,
			Vector3i(0, -1, -1): Color.BLUE,
			Vector3i(0, -1, 0): Color.YELLOW,
		}, "X")
	)
	var z_pattern: Dictionary = await _convert(image, Vector3.Axis.AXIS_Z)
	step("Then the image lies on the Z floor plane", func():
		_expect_pattern(z_pattern, {
			Vector3i(-1, 0, 0): Color.RED,
			Vector3i(0, 0, 0): Color.GREEN,
			Vector3i(-1, -1, 0): Color.BLUE,
			Vector3i(0, -1, 0): Color.YELLOW,
		}, "Z")
	)
	var alpha_pattern: Dictionary = await _convert(_alpha_image(), Vector3.Axis.AXIS_Y)
	step("Then the alpha clip drops only the transparent pixels", func():
		_expect_pattern(alpha_pattern, {
			Vector3i(-1, 0, 0): Color.RED,
			Vector3i(0, 0, 0): Color.GREEN,
			Vector3i(1, 0, 0): Color.BLUE,
			Vector3i(-1, 0, 1): Color.YELLOW,
			Vector3i(1, 0, 1): Color(0.0, 1.0, 1.0, 1.0),
		}, "alpha")
		expect(alpha_pattern.size() == 5, "the image drops the pixel below the alpha clip")
		expect(not alpha_pattern.has(Vector3i(0, 0, 1)), "the pixel below the alpha clip leaves no cell")
	)


func _image_paste() -> void:
	var image := Image.create(3, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	image.set_pixel(0, 0, Color.RED)
	image.set_pixel(2, 0, Color.BLUE)
	step("Given an image with a transparent center", func():
		clipboard._start_image_paste(image)
	)
	while clipboard._image_job:
		await get_tree().process_frame
	step("Then the preview is ready without a model write", func():
		expect(clipboard._paste_tool._active, "the image starts a paste placement")
		expect(frame.count() == 0, "the preview writes no cell")
	)
	step("When the user commits at an offset", func():
		_place(Vector3i(10, 0, 0))
	)
	step("Then the image becomes one undoable Paste", func():
		expect(frame.count() == 2, "the image supplies only its two opaque pixels")
		expect(frame.get_color(Vector3i(9, 0, 0)) == Color.RED, "the left pixel keeps its color")
		expect(frame.get_color(Vector3i(11, 0, 0)) == Color.BLUE, "the right pixel keeps its color")
		expect(not frame.has(Vector3i(10, 0, 0)), "the transparent center leaves no voxel")
		expect(State.selection.count() == 2 and State.selection.contains(Vector3i(9, 0, 0)) and State.selection.contains(Vector3i(11, 0, 0)), "the paste selects only the image pixels")
		expect(State.document.palette.is_empty(), "the image paste leaves the palette unchanged")
		expect(not State.edit_busy(), "the commit releases the foreground status")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes the image paste")
		expect(State.selection.is_empty(), "undo restores the empty target selection")
		expect(not State.undo_redo.has_undo(), "the image paste creates one history action")
	)


func _image_cancel() -> void:
	var image := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	step("Given a large image paste", func():
		clipboard._start_image_paste(image)
		expect(State.edit_busy(), "the image conversion reports foreground work")
		State.document = VoxelDocument.new()
	)
	var deadline := Time.get_ticks_msec() + 8000
	while clipboard._image_job != null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	step("Then the old result cannot start a paste", func():
		expect(clipboard._pattern.is_empty(), "the changed document installs no image pattern")
		expect(not clipboard._paste_tool._active, "the changed document starts no paste")
		expect(not clipboard._paste_tool.is_inside_tree(), "the changed document mounts no preview")
		expect(not State.edit_busy(), "the cancelled image conversion releases editing")
		expect(not State.undo_redo.has_undo(), "the cancelled image conversion adds no history action")
	)


func _image_available() -> void:
	step("Given only image data on the clipboard", func():
		clipboard._has_clipboard_voxels = false
		clipboard._has_clipboard_image = true
		clipboard._sync_buttons()
		expect(not clipboard._options.get_node("Paste").disabled, "the Paste button accepts an image")
	)
	step("When the clipboard image is gone", func():
		clipboard._has_clipboard_image = false
		clipboard._sync_buttons()
		expect(clipboard._options.get_node("Paste").disabled, "the Paste button disables without a source")
	)


func _convert(image: Image, axis: Vector3.Axis) -> Dictionary:
	State.floor_axis = axis
	clipboard._start_image_paste(image)
	var deadline := Time.get_ticks_msec() + 8000
	while clipboard._image_job != null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var pattern: Dictionary = clipboard._pattern.duplicate()
	clipboard.cancel_paste()
	await get_tree().process_frame
	return pattern


func _axis_image() -> Image:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	image.set_pixel(0, 0, Color.RED)
	image.set_pixel(1, 0, Color.GREEN)
	image.set_pixel(0, 1, Color.BLUE)
	image.set_pixel(1, 1, Color.YELLOW)
	return image


func _alpha_image() -> Image:
	var image := Image.create(3, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	image.set_pixel(0, 0, Color.RED)
	image.set_pixel(1, 0, Color.GREEN)
	image.set_pixel(2, 0, Color.BLUE)
	image.set_pixel(0, 1, Color.YELLOW)
	image.set_pixel(1, 1, Color(1.0, 1.0, 1.0, 0.49))
	image.set_pixel(2, 1, Color(0.0, 1.0, 1.0, 0.51))
	return image


func _expect_pattern(pattern: Dictionary, expected: Dictionary, axis_name: String) -> void:
	expect(pattern.size() == expected.size(), "the %s image yields every pixel" % axis_name)
	for offset: Vector3i in expected:
		expect(pattern.has(offset), "the %s image maps a pixel to %s" % [axis_name, offset])
		if pattern.has(offset):
			var color: Color = pattern[offset]
			var expected_color: Color = expected[offset]
			expect(_is_color(color, expected_color), "the %s image keeps the pixel color" % axis_name)


func _place(center: Vector3i) -> void:
	clipboard._paste_tool._update_endpoint(center)
	var event := InputEventKey.new()
	event.keycode = KEY_ENTER
	event.pressed = true
	clipboard._paste_tool.handle_input(event, Vector2.ZERO)


func _is_color(value: Color, expected: Color) -> bool:
	return absf(value.r - expected.r) < 0.02 and absf(value.g - expected.g) < 0.02 \
		and absf(value.b - expected.b) < 0.02 and absf(value.a - expected.a) < 0.02
