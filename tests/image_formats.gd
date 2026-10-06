extends "res://tests/test.gd"

const FORMATS := ["jpg", "jpeg", "webp", "svg", "exr", "dds"]

var bar: Node
var panel: PalettePanel
var paths := {}
var previous_document: VoxiDocument


func _ready() -> void:
	timeout = 30.0
	test("Open and palette import use Godot image formats, including compressed textures", _run)


func _run() -> void:
	step("Given image files saved through Godot", func():
		bar = main.get_node("%MenuBar")
		panel = main.find_child("PalettePanel", true, false)
		State.floor_axis = Vector3.Axis.AXIS_Y
		var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		image.fill(Color.RED)
		var prefix := "user://voxi_image_formats_%s" % Time.get_ticks_usec()
		for extension in FORMATS:
			var path: String = prefix + "." + ("SVG" if extension == "svg" else extension)
			paths[extension] = path
			expect(_save_fixture(image, path, extension) == OK, "the %s image fixture is saved" % extension)
	)
	step("When the user opens the document file dialog", func():
		bar.get_node("OpenBtn").pressed.emit()
	)
	step("Then both image dialogs offer the same supported formats", func():
		var document_filters: PackedStringArray = bar.get_node("%FileDialog").filters
		var palette_filters: PackedStringArray = panel.get_node("%ImportDialog").filters
		expect(document_filters.size() == 2 and palette_filters.size() == 1, "Open offers voxel documents and images, and palette import offers images")
		expect(document_filters[1] == palette_filters[0], "both dialogs share the image format filter")
		for extension in ["bmp", "dds", "exr", "hdr", "jpg", "jpeg", "ktx", "ktx2", "png", "svg", "tga", "webp"]:
			expect(document_filters[1].contains("*." + extension), "both dialogs offer %s images" % extension)
		bar.get_node("%FileDialog").hide()
	)
	for extension in FORMATS:
		step("Given a document before opening the %s image" % extension, func():
			State.document = VoxiDocument.new()
			previous_document = State.document
			State.get_current_voxel_frame().set_cell(Vector3i(30, 0, 0), Color.GREEN)
			bar.current_save_path = "previous.tres"
		)
		await bar._on_file_opened(paths[extension])
		step("Then the %s image opens as a voxel document" % extension, func():
			expect(State.document != previous_document, "Open replaces the previous document")
			expect(State.get_current_voxel_frame().count() == 16, "the image supplies all sixteen voxels")
			expect(_is_red(State.get_current_voxel_frame().get_color(Vector3i.ZERO)), "the image retains its red voxel colors")
			expect(State.get_palette().size() == 1 and _is_red(State.get_palette()[0]), "the document palette contains the decoded image color")
			expect(bar.current_save_path.is_empty(), "the image starts with a new voxel save path")
		)
		var imported_document := State.document
		step("When the user imports the %s image as a palette" % extension, func():
			State.set_palette(PackedColorArray([Color.BLUE]))
		)
		var error := await panel.import_palette(paths[extension])
		step("Then palette import reads the same %s image color" % extension, func():
			expect(error == OK, "the palette image import completes")
			expect(State.get_palette().size() == 1 and _is_red(State.get_palette()[0]), "the palette contains the decoded image color")
			expect(State.document == imported_document and State.get_current_voxel_frame().count() == 16, "palette import preserves the voxel document")
			expect(not State.edit_busy(), "image loading releases editing")
		)
	for path in paths.values():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _is_red(color: Color) -> bool:
	return color.r > 0.95 and color.g < 0.02 and color.b < 0.02 and color.a == 1.0


func _save_fixture(image: Image, path: String, extension: String) -> Error:
	match extension:
		"jpg", "jpeg":
			return image.save_jpg(path, 1.0)
		"webp":
			return image.save_webp(path)
		"exr":
			return image.save_exr(path)
		"dds":
			var compressed := Image.new()
			compressed.copy_from(image)
			var error := compressed.compress(Image.COMPRESS_S3TC)
			if error != OK:
				return error
			return compressed.save_dds(path)
		"svg":
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file == null:
				return FileAccess.get_open_error()
			file.store_string('<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"><rect width="4" height="4" fill="#ff0000"/></svg>')
			file.close()
			return OK
	return ERR_INVALID_PARAMETER
