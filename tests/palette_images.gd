extends "res://tests/test.gd"

var panel: PalettePanel
var frame: VoxelFrame
var image_path := ""
var export_path := ""
var transparent_path := ""
var large_path := ""
var image_colors := PackedColorArray([Color.RED, Color.from_rgba8(0, 0, 255, 128), Color.YELLOW, Color.BLUE])
var exported_colors := PackedColorArray()
var cancelled_result: Error = OK
var cancelled_done := false


func _ready() -> void:
	test("image palettes preserve unique colors, swatch order, undo, and document contents", _run)


func _run() -> void:
	step("Given an image with repeated colors and transparent pixels", func():
		panel = main.find_child("PalettePanel", true, false)
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, Color.MAGENTA)
		State.selection.add(Vector3i.ONE)
		State.document.palette.assign([Color.GREEN, Color.MAGENTA])
		State.palette_changed.emit()
		State.set_color(Color.MAGENTA)
		State.undo_redo.clear_history()
		var prefix := "user://voxel_palette_%s" % Time.get_ticks_usec()
		image_path = prefix + "_source.png"
		export_path = prefix + "_export.png"
		transparent_path = prefix + "_transparent.png"
		large_path = prefix + "_large.png"
		var image := Image.create(3, 2, false, Image.FORMAT_RGBA8)
		image.fill(Color.TRANSPARENT)
		image.set_pixel(0, 0, Color.RED)
		image.set_pixel(1, 0, Color.RED)
		image.set_pixel(0, 1, image_colors[1])
		image.set_pixel(1, 1, Color.YELLOW)
		image.set_pixel(2, 1, Color.BLUE)
		expect(image.save_png(image_path) == OK, "the source palette image is saved")
	)
	var error := await panel.import_palette(image_path)
	step("Then the palette contains each visible color in image order", func():
		expect(error == OK, "the image palette is imported")
		expect(State.get_palette() == image_colors, "the palette retains unique RGBA colors in row order")
		expect(panel.get_node("%SwatchGrid").get_child_count() == 4, "all four imported colors appear as swatches")
		expect(frame.count() == 1 and frame.get_color(Vector3i.ZERO) == Color.MAGENTA, "palette import preserves the document voxels")
		expect(State.selection.contains(Vector3i.ONE), "palette import preserves the selection")
		expect(State.current_color == Color.MAGENTA, "palette import preserves the working color")
		expect(not State.edit_busy(), "palette import releases editing")
	)
	step("When the user undoes the imported palette", func():
		State.undo_redo.undo()
	)
	step("Then the previous palette returns in its original order", func():
		expect(State.get_palette() == PackedColorArray([Color.GREEN, Color.MAGENTA]), "undo restores both original swatches")
	)
	step("When the user redoes the imported palette", func():
		State.undo_redo.redo()
	)
	step("Then the imported palette returns", func():
		expect(State.get_palette() == image_colors, "redo restores the image palette")
	)
	step("When the user saves a palette with seventeen swatches as an image", func():
		exported_colors = image_colors.duplicate()
		for index in 13:
			exported_colors.append(Color.from_rgba8(index + 1, 100, 50))
		State.set_palette(exported_colors)
		expect(panel.export_palette(export_path) == OK, "the palette is saved as a PNG")
		var image := Image.new()
		expect(image.load(export_path) == OK, "the palette PNG can be opened")
		expect(image.get_size() == Vector2i(256, 32), "the PNG has two rows of readable swatches")
		expect(image.get_pixel(16, 16).a == 0.0, "unused swatch positions are transparent")
		State.set_palette(PackedColorArray([Color.WHITE]))
	)
	error = await panel.import_palette(export_path)
	step("Then importing the saved PNG restores the same swatches", func():
		expect(error == OK and State.get_palette() == exported_colors, "PNG export and import preserve colors and swatch order")
	)
	step("Given an image with no visible colors", func():
		var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
		image.fill(Color.TRANSPARENT)
		expect(image.save_png(transparent_path) == OK, "the transparent image is saved")
		State.undo_redo.clear_history()
	)
	error = await panel.import_palette(transparent_path)
	step("Then importing that image preserves the current palette", func():
		expect(error == ERR_INVALID_DATA, "an image without visible colors is rejected")
		expect(State.get_palette() == exported_colors, "the palette retains all existing swatches")
		expect(not State.undo_redo.has_undo(), "the rejected import adds no undo action")
	)
	step("When the user changes documents during a large palette import", func():
		var image := Image.create(512, 512, false, Image.FORMAT_RGBA8)
		image.fill(Color.RED)
		expect(image.save_png(large_path) == OK, "the large palette image is saved")
		_start_cancelled_import()
		expect(State.edit_busy(), "the palette import reports foreground work")
		State.document = VoxelDocument.new()
		State.document.palette.assign([Color.GREEN])
		State.palette_changed.emit()
	)
	while not cancelled_done:
		await get_tree().process_frame
	step("Then the old image cannot replace the new document palette", func():
		expect(cancelled_result == ERR_BUSY, "the old palette import is cancelled")
		expect(State.get_palette() == PackedColorArray([Color.GREEN]), "the new document retains its palette")
		expect(not State.undo_redo.has_undo(), "the cancelled import adds no undo action")
		expect(not State.edit_busy(), "the cancelled import releases editing")
	)
	step("When the user saves the built-in high-contrast palette as a PNG", func():
		State.set_palette(State.get_builtin_palette())
		expect(panel.export_palette(export_path) == OK, "the complete built-in palette is saved")
		State.set_palette(PackedColorArray([Color.MAGENTA]))
	)
	error = await panel.import_palette(export_path)
	step("Then the PNG restores all 27 colors without changes", func():
		expect(error == OK, "the built-in palette PNG is imported")
		expect(State.get_palette() == State.get_builtin_palette(), "the PNG preserves all 27 built-in colors exactly")
	)
	step("When the current palette is empty", func():
		State.set_palette(PackedColorArray())
	)
	step("Then exporting requires at least one swatch", func():
		expect(panel.get_node("%ExportBtn").disabled, "the image export button is disabled for an empty palette")
		expect(panel.export_palette(export_path) == ERR_INVALID_DATA, "an empty palette cannot overwrite an image")
	)
	for path in [image_path, export_path, transparent_path, large_path]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _start_cancelled_import() -> void:
	cancelled_result = await panel.import_palette(large_path)
	cancelled_done = true
