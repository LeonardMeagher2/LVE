extends "res://tests/test.gd"

var importer: Node
var clipboard: Node
var image_path := ""
var transparent_path := ""
var previous_document: VoxiDocument
var marker := Vector3i(24, 0, 0)


func _ready() -> void:
	timeout = 30.0
	test("Open loads a PNG as a new voxel document with clipped pixels and a unique image palette", _run)


func _run() -> void:
	step("Given a PNG with opaque, clipped, and duplicate colors", func():
		importer = plugin("PNGImportPlugin")
		clipboard = plugin("ClipboardPlugin")
		var image := Image.create(4, 2, false, Image.FORMAT_RGBA8)
		image.fill(Color.TRANSPARENT)
		image.set_pixel(0, 0, Color.RED)
		image.set_pixel(1, 0, Color(0, 1, 0, 127.0 / 255.0))
		image.set_pixel(2, 0, Color(0, 0, 1, 128.0 / 255.0))
		image.set_pixel(0, 1, Color.YELLOW)
		image.set_pixel(2, 1, Color(1, 0, 0, 192.0 / 255.0))
		image.set_pixel(3, 1, Color.BLACK)
		image_path = "user://voxi_png_test_%s.png" % Time.get_ticks_usec()
		expect(image.save_png(image_path) == OK, "the PNG fixture is saved")
		State.document = VoxiDocument.new()
		previous_document = State.document
		State.get_current_voxel_frame().set_cell(marker, Color.GREEN)
		State.document.palette.assign([Color.GREEN])
		State.palette_changed.emit()
		State.selection.add(marker)
		State.selection_changed.emit()
		State.floor_axis = Vector3.Axis.AXIS_Y
		main.find_child("MenuBar", true, false).current_save_path = "previous.tres"
	)
	await main.find_child("MenuBar", true, false)._on_file_opened(image_path)
	step("Then Open replaces the document directly", func():
		expect(State.document != previous_document, "the PNG is a new document")
		expect(State.document.frames.size() == 1, "the PNG opens as one frame")
		expect(State.document.title == image_path.get_file().get_basename(), "the document uses the image filename")
		expect(not clipboard._paste_tool._active, "opening the PNG creates no paste preview")
		expect(not State.edit_busy(), "opening the PNG completes without a placement step")
		expect(State.selection.is_empty(), "the new document has no old selection")
		expect(not State.undo_redo.has_undo(), "opening the PNG starts a new edit history")
		expect(main.find_child("MenuBar", true, false).current_save_path.is_empty(), "the PNG uses a new voxel save path")
	)
	step("Then the PNG retains its clipped shape, orientation, and opaque colors", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 5, "the PNG contains five visible pixels")
		expect(frame.get_color(Vector3i(-2, 0, -1)) == Color.RED, "the top-left pixel is red")
		expect(frame.get_color(Vector3i(0, 0, -1)) == Color.BLUE, "the pixel above the alpha cutoff is opaque blue")
		expect(frame.get_color(Vector3i(-2, 0, 0)) == Color.YELLOW, "the bottom-left pixel is yellow")
		expect(frame.get_color(Vector3i(0, 0, 0)) == Color.RED, "the partially transparent red pixel becomes opaque")
		expect(frame.get_color(Vector3i(1, 0, 0)) == Color.BLACK, "the black PNG pixel stays black")
		expect(not frame.has(Vector3i(-1, 0, -1)), "the pixel below the alpha cutoff is absent")
		var center := frame.get_bounds().get_center().abs()
		expect(center.x <= 0.5 and center.y <= 0.5 and center.z <= 0.5, "the image bounds use the nearest voxel-grid center to the origin")
		expect(not frame.has(marker), "the PNG has no marker from the old document")
		expect(previous_document.frames[0].get_color(marker) == Color.GREEN, "the previous document resource remains unchanged")
	)
	step("Then the palette contains each retained image color once", func():
		expect(State.document.palette == [Color.RED, Color.BLUE, Color.YELLOW, Color.BLACK], "the palette contains only distinct retained PNG colors")
		var grid := main.find_child("PalettePanel", true, false).get_node("%SwatchGrid")
		expect(grid.get_child_count() == 4, "the palette displays all four image colors")
		var black_swatch := grid.get_child(3) as Button
		expect(black_swatch.get_theme_stylebox("normal").bg_color == Color.BLACK, "the black swatch has a black background")
		expect(black_swatch.get_theme_stylebox("pressed").bg_color == Color.BLACK, "the selected black swatch has a black background")
		expect(black_swatch.tooltip_text == "000000ff", "the black swatch tooltip shows its color")
	)
	step("Given a fully transparent PNG", func():
		var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
		image.fill(Color.TRANSPARENT)
		transparent_path = "user://voxi_png_empty_%s.png" % Time.get_ticks_usec()
		expect(image.save_png(transparent_path) == OK, "the transparent fixture is saved")
	)
	var error: Error = await importer.import_png(transparent_path)
	step("Then a transparent PNG opens an empty document", func():
		expect(error == OK, "the transparent PNG is a valid image")
		expect(State.get_current_voxel_frame().count() == 0, "the transparent PNG opens with no voxels")
		expect(State.document.palette.is_empty(), "the transparent PNG has no visible palette colors")
		expect(not clipboard._paste_tool._active, "the transparent PNG creates no paste preview")
	)
	step("Given a padded image with one visible corner pixel", func():
		var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		image.fill(Color.TRANSPARENT)
		image.set_pixel(7, 0, Color.BLUE)
		expect(image.save_png(transparent_path) == OK, "the padded PNG fixture is saved")
	)
	error = await importer.import_png(transparent_path)
	step("Then occupied content is centered independently of transparent margins", func():
		expect(error == OK, "the padded PNG opens")
		expect(State.get_current_voxel_frame().get_color(Vector3i.ZERO) == Color.BLUE, "the only visible voxel is at the origin")
		expect(State.document.bounds().get_center() == Vector3.ZERO, "the visible content bounds are centered on the origin")
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(image_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(transparent_path))
