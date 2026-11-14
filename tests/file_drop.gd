extends "res://tests/test.gd"

## Checks that files dropped on the window open as document tabs.

var menu: Node
var prefix := ""
var document_path := ""
var red_path := ""
var green_path := ""


func _ready() -> void:
	timeout = 30.0
	test("a dropped document opens in the empty tab", _drop_document, "drop_document")
	test("a dropped image imports as a voxel document", _drop_image, "drop_image")
	test("a mixed drop opens every file in order", _drop_multiple, "drop_multiple")


func before_test() -> void:
	menu = main.get_node("%MenuBar")
	prefix = "user://file_drop_%s" % Time.get_ticks_usec()
	document_path = prefix + ".lve"
	red_path = prefix + "_red.png"
	green_path = prefix + "_green.png"
	var document := VoxelDocument.new()
	document.frames[0].set_cell(Vector3i(1, 2, 3), VoxelFrame.material(Color.GREEN))
	expect(document.save_file(document_path) == OK, "the document fixture saves")
	expect(_save_image(red_path, Color.RED) == OK, "the red image fixture saves")
	expect(_save_image(green_path, Color.GREEN) == OK, "the green image fixture saves")


func after_test() -> void:
	for path in [document_path, red_path, green_path]:
		if not path.is_empty():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	prefix = ""
	document_path = ""
	red_path = ""
	green_path = ""
	if is_instance_valid(menu):
		var error_dialog := menu.get_node_or_null("FileError")
		if error_dialog != null:
			error_dialog.hide()


func _drop_document() -> void:
	step("When a document is dropped on the window", func():
		main.get_window().files_dropped.emit(PackedStringArray([_absolute(document_path)]))
	)
	var finished := await _wait_for_drop(1)
	step("Then the document opens in the empty tab", func():
		expect(finished, "the drop finishes")
		expect(State.tabs.size() == 1, "the empty tab holds the dropped document")
		expect(State.document.edit_save_path == _absolute(document_path), "the dropped path becomes the save path")
		expect(State.document.frames[0].count() == 1, "the dropped document keeps its voxel")
		expect(State.document.frames[0].get_color(Vector3i(1, 2, 3)) == Color.GREEN, "the dropped document keeps its color")
		expect(not menu.get_node("FileError").visible, "no file error appears")
	)


func _drop_image() -> void:
	step("When an image is dropped on the window", func():
		main.get_window().files_dropped.emit(PackedStringArray([_absolute(red_path)]))
	)
	var finished := await _wait_for_drop(1)
	step("Then the image imports as a new voxel document", func():
		expect(finished, "the image import finishes")
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 16, "the image supplies sixteen voxels")
		if frame.count() == 16:
			expect(_is_color(frame.get_color(frame.positions()[0]), Color.RED), "the voxels keep the image color")
		expect(State.get_palette().size() == 1, "the palette holds the image color")
		expect(State.document.edit_save_path.is_empty(), "the image starts with a new voxel save path")
	)


func _drop_multiple() -> void:
	step("When a document and two images are dropped together", func():
		main.get_window().files_dropped.emit(PackedStringArray([
			_absolute(document_path),
			_absolute(red_path),
			_absolute(green_path),
		]))
	)
	var finished := await _wait_for_drop(3)
	step("Then every file opens in order", func():
		expect(finished, "the three files finish opening")
		expect(State.tabs.size() == 3, "each file gets a tab")
		expect(State.active_tab == 2, "the last image is active")
		if State.tabs.size() != 3:
			return
		expect(State.tabs[0].edit_save_path == _absolute(document_path), "the first tab holds the document")
		expect(State.tabs[0].frames[0].get_color(Vector3i(1, 2, 3)) == Color.GREEN, "the document keeps its voxel")
		expect(State.tabs[1].edit_save_path.is_empty(), "the first image has no save path")
		expect(_is_color(State.tabs[1].frames[0].get_color(State.tabs[1].frames[0].positions()[0]), Color.RED), "the first image is red")
		expect(State.tabs[2].edit_save_path.is_empty(), "the second image has no save path")
		expect(_is_color(State.tabs[2].frames[0].get_color(State.tabs[2].frames[0].positions()[0]), Color.GREEN), "the second image is green")
	)


func _wait_for_drop(expected_tabs: int) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while (State.edit_busy() or State.tabs.size() < expected_tabs) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	await get_tree().process_frame
	return not State.edit_busy() and State.tabs.size() == expected_tabs


func _absolute(path: String) -> String:
	return ProjectSettings.globalize_path(path)


func _save_image(path: String, color: Color) -> Error:
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return image.save_png(path)


func _is_color(value: Color, expected: Color) -> bool:
	return absf(value.r - expected.r) < 0.02 and absf(value.g - expected.g) < 0.02 \
		and absf(value.b - expected.b) < 0.02 and value.a == 1.0
