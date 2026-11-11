extends "res://tests/test.gd"

# Palette marking, reorder, and image import and export share the PalettePanel
# fixture. One process runs all three, so the scene carries their names.

var panel: PalettePanel = null
var grid: Node = null
var frame: VoxelFrame
var palette_drag: Variant
var image_path := ""
var export_path := ""
var transparent_path := ""
var large_path := ""
var image_colors := PackedColorArray([Color.RED, Color.from_rgba8(0, 0, 255, 128), Color.YELLOW, Color.BLUE])
var exported_colors := PackedColorArray()
var exported_materials: Array[PackedFloat32Array] = []
var cancelled_result: Error = OK
var cancelled_done := false


func _ready() -> void:
	test("the palette marks the selected material and restores indexed edits with undo", _palette_run, "marking")
	test("dragging palette swatches reorders colors with undo and preserves the working color", _reorder_run, "palette_reorder")
	test("image palettes preserve unique colors, swatch order, undo, and document contents", _images_run, "palette_images")


# Each case starts from a clean document and history. The cases share one
# process, so no case may inherit another case's palette or undo stack.
func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	State.clear_selection()
	State.symmetry_axes = 0
	cancelled_done = false


func _marked(i: int) -> bool:
	var b := grid.get_child(i) as Button
	return b.button_pressed


func _palette_run() -> void:
	step("Given a palette with one red swatch", func():
		panel = main.find_child("PalettePanel", true, false)
		grid = panel.get_node("%SwatchGrid")
		State.document.palette.assign([VoxelFrame.material(Color.RED)])
		panel._rebuild_swatches()
	)

	step("When the working color becomes red", func():
		State.set_color(Color.RED)
	)

	step("Then the red swatch is marked", func():
		expect(grid.get_child_count() == 1, "one swatch exists")
		expect(_marked(0), "matching swatch is marked")
		expect(State.current_palette_index == 0, "the matching material selects its palette index")
	)

	step("When the working color becomes blue", func():
		State.set_color(Color.BLUE)
	)

	step("Then no swatch is marked", func():
		expect(not _marked(0), "no swatch is marked")
		expect(State.current_palette_index == -1, "the unsaved material has no palette index")
		expect(State.get_palette() == [VoxelFrame.material(Color.RED)], "setting the working color preserves the palette")
	)

	step("When the user clicks the red swatch", func():
		var b := grid.get_child(0) as Button
		b.button_pressed = true
	)

	step("Then the red swatch is marked again", func():
		expect(_marked(0), "clicked swatch is marked")
		expect(State.current_color == Color.RED, "the working color is the swatch color")
		expect(State.current_palette_index == 0, "clicking the swatch selects its index")
		State.undo_redo.clear_history()
	)

	step("When the user picks blue", func():
		State.set_color(Color.BLUE)
	)

	step("Then blue is the working color", func():
		expect(State.current_color == Color.BLUE, "the working color is blue")
		expect(not _marked(0), "no swatch matches blue")
	)

	step("When the user undoes the color change", func():
		State.undo_redo.undo()
	)

	step("Then the selected red material returns", func():
		expect(State.current_material == VoxelFrame.material(Color.RED), "undo restores the selected red material")
		expect(State.current_palette_index == 0, "undo restores the selected palette index")
	)

	step("When the user redoes the color change", func():
		State.undo_redo.redo()
	)

	step("Then blue is the working color again", func():
		expect(State.current_color == Color.BLUE, "the working color is blue again")
	)

	step("When the user picks green and adds it to the palette", func():
		State.set_color(Color.GREEN)
		State.add_material()
	)

	step("Then the palette gains a green swatch", func():
		expect(grid.get_child_count() == 2, "two swatches exist")
		expect((grid.get_child(1) as Button).color == Color.GREEN, "the new swatch is green")
		expect(State.current_palette_index == 1, "the new material selects its appended index")
	)

	step("When the user undoes the added swatch", func():
		State.undo_redo.undo()
	)

	step("Then the palette loses the green swatch", func():
		expect(grid.get_child_count() == 1, "one swatch remains")
	)

	step("When the user redoes the added swatch", func():
		State.undo_redo.redo()
	)

	step("Then the green swatch returns", func():
		expect(grid.get_child_count() == 2, "two swatches exist")
		expect((grid.get_child(1) as Button).color == Color.GREEN, "the green swatch is back")
	)

	step("When the user removes the selected material", func():
		State.remove_palette_entry()
	)

	step("Then the green swatch leaves the palette", func():
		expect(grid.get_child_count() == 1, "one swatch remains")
		expect(State.current_palette_index == 0 and State.current_color == Color.RED, "removal selects the remaining red swatch")
	)

	step("When the user undoes the removal", func():
		State.undo_redo.undo()
	)

	step("Then the green swatch returns at its index", func():
		expect(grid.get_child_count() == 2, "two swatches exist")
		expect((grid.get_child(1) as Button).color == Color.GREEN, "the green swatch is back")
		expect(State.current_palette_index == 1, "undo restores the removed material selection")
	)

	step("When the user redoes the removal", func():
		State.undo_redo.redo()
	)

	step("Then the green swatch leaves again", func():
		expect(grid.get_child_count() == 1, "one swatch remains")
	)


func _reorder_run() -> void:
	step("Given three swatches with blue as the working color", func():
		grid = main.find_child("PalettePanel", true, false).get_node("%SwatchGrid")
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.MAGENTA))
		State.document.palette.assign([VoxelFrame.material(Color.RED), VoxelFrame.material(Color.GREEN), VoxelFrame.material(Color.BLUE)])
		State.palette_changed.emit()
		State.select_palette_entry(2)
		State.undo_redo.clear_history()
	)
	step("When the user drags the blue swatch onto the red swatch", func():
		palette_drag = grid.get_child(2)._get_drag_data(Vector2.ZERO)
		expect(palette_drag != null, "the blue swatch starts a drag")
		expect(grid.get_child(0)._can_drop_data(Vector2.ZERO, palette_drag), "the red swatch accepts the palette drag")
		grid.get_child(0)._drop_data(Vector2.ZERO, palette_drag)
	)
	step("Then blue becomes the first swatch", func():
		expect(State.get_palette() == [VoxelFrame.material(Color.BLUE), VoxelFrame.material(Color.RED), VoxelFrame.material(Color.GREEN)], "the palette moves blue to the first position")
		expect(State.current_palette_index == 0, "the selection follows blue to the first index")
		expect(grid.get_child(0).color == Color.BLUE and grid.get_child(0).button_pressed, "the moved blue swatch remains selected")
		expect(State.current_color == Color.BLUE, "reordering preserves the working color")
		expect(frame.get_color(Vector3i.ZERO) == Color.MAGENTA, "reordering preserves voxel colors")
	)
	step("When the user undoes the palette drag", func():
		State.undo_redo.undo()
	)
	step("Then the original swatch order returns", func():
		expect(State.get_palette() == [VoxelFrame.material(Color.RED), VoxelFrame.material(Color.GREEN), VoxelFrame.material(Color.BLUE)], "undo restores the original palette order")
		expect(State.current_palette_index == 2, "undo restores the selected index")
		expect(grid.get_child(2).button_pressed, "undo keeps the blue swatch selected")
	)
	step("When the user redoes the palette drag", func():
		State.undo_redo.redo()
	)
	step("Then blue returns to the first position", func():
		expect(State.get_palette() == [VoxelFrame.material(Color.BLUE), VoxelFrame.material(Color.RED), VoxelFrame.material(Color.GREEN)], "redo restores the reordered palette")
		expect(State.current_palette_index == 0, "redo restores the moved selection")
	)
	step("When the user drags the first swatch onto the last swatch", func():
		palette_drag = grid.get_child(0)._get_drag_data(Vector2.ZERO)
		grid.get_child(2)._drop_data(Vector2.ZERO, palette_drag)
	)
	step("Then blue becomes the last swatch", func():
		expect(State.get_palette() == [VoxelFrame.material(Color.RED), VoxelFrame.material(Color.GREEN), VoxelFrame.material(Color.BLUE)], "the palette moves blue to the last position")
		expect(State.current_palette_index == 2, "the selection follows blue to the last index")
	)
	step("When the user drops a swatch onto itself", func():
		State.undo_redo.clear_history()
		palette_drag = grid.get_child(1)._get_drag_data(Vector2.ZERO)
		grid.get_child(1)._drop_data(Vector2.ZERO, palette_drag)
	)
	step("Then the palette keeps its order and history", func():
		expect(State.get_palette() == [VoxelFrame.material(Color.RED), VoxelFrame.material(Color.GREEN), VoxelFrame.material(Color.BLUE)], "dropping onto the same swatch preserves the order")
		expect(not State.undo_redo.has_undo(), "dropping onto the same swatch adds no undo action")
		expect(not grid.get_child(0)._can_drop_data(Vector2.ZERO, {"type": "voxel_frame", "from": 1}), "palette swatches reject animation frame drags")
	)
	step("When the user opens another document during a palette drag", func():
		palette_drag = grid.get_child(2)._get_drag_data(Vector2.ZERO)
		State.document = VoxelDocument.new()
		State.document.palette.assign([VoxelFrame.material(Color.RED), VoxelFrame.material(Color.GREEN), VoxelFrame.material(Color.BLUE)])
		State.palette_changed.emit()
		grid.get_child(0)._drop_data(Vector2.ZERO, palette_drag)
	)
	step("Then the old drag preserves the new document palette", func():
		expect(not grid.get_child(0)._can_drop_data(Vector2.ZERO, palette_drag), "the new document rejects the old palette drag")
		expect(State.get_palette() == [VoxelFrame.material(Color.RED), VoxelFrame.material(Color.GREEN), VoxelFrame.material(Color.BLUE)], "the new document keeps its palette order")
		expect(not State.undo_redo.has_undo(), "the rejected drag adds no undo action")
	)
	step("When a foreground edit is running", func():
		palette_drag = grid.get_child(2)._get_drag_data(Vector2.ZERO)
		var operation_id := State.begin_operation("Editing", -1, true, self)
		expect(grid.get_child(0)._get_drag_data(Vector2.ZERO) == null, "palette drags wait for the foreground edit")
		expect(not grid.get_child(0)._can_drop_data(Vector2.ZERO, palette_drag), "palette drops wait for the foreground edit")
		State.finish_operation(operation_id)
	)


func _images_run() -> void:
	step("Given an image with repeated colors and transparent pixels", func():
		panel = main.find_child("PalettePanel", true, false)
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.MAGENTA))
		State.selection.add(Vector3i.ONE)
		State.document.palette.assign([VoxelFrame.material(Color.GREEN), VoxelFrame.material(Color.MAGENTA)])
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
		expect(State.get_palette() == _materials(image_colors), "the palette retains unique RGBA colors in row order")
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
		expect(State.get_palette() == [VoxelFrame.material(Color.GREEN), VoxelFrame.material(Color.MAGENTA)], "undo restores both original swatches")
	)
	step("When the user redoes the imported palette", func():
		State.undo_redo.redo()
	)
	step("Then the imported palette returns", func():
		expect(State.get_palette() == _materials(image_colors), "redo restores the image palette")
	)
	step("When the user saves a palette with seventeen swatches as an image", func():
		exported_colors = image_colors.duplicate()
		for index in 12:
			exported_colors.append(Color.from_rgba8(index + 1, 100, 50))
		exported_colors.append(Color.RED)
		exported_materials = []
		for color in exported_colors:
			exported_materials.append(VoxelFrame.material(color))
		exported_materials[0] = VoxelFrame.material(Color.RED, Color(0.5, 0.25, 0.125), 0.75, 0.25)
		State.set_palette(exported_materials)
		expect(panel.export_palette(export_path) == OK, "the palette is saved as a PNG")
		var image := Image.new()
		expect(image.load(export_path) == OK, "the palette PNG can be opened")
		expect(image.get_size() == Vector2i(256, 32), "the PNG has two rows of readable swatches")
		expect(image.get_pixel(16, 16).a == 0.0, "unused swatch positions are transparent")
		State.set_palette([VoxelFrame.material(Color.WHITE)])
	)
	error = await panel.import_palette(export_path)
	step("Then importing the saved PNG restores the same swatches", func():
		expect(error == OK and State.get_palette() == _materials(exported_colors), "PNG import retains color order and combines exact default materials")
		expect(State.get_palette() != exported_materials, "PNG palettes deliberately discard emission, metallic, and roughness values")
		expect(State.get_palette().size() == 16, "same-color variants become one color-only swatch")
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
		expect(State.get_palette() == _materials(exported_colors), "the palette retains all existing swatches")
		expect(not State.undo_redo.has_undo(), "the rejected import adds no undo action")
	)
	step("When the user changes documents during a large palette import", func():
		var image := Image.create(512, 512, false, Image.FORMAT_RGBA8)
		image.fill(Color.RED)
		expect(image.save_png(large_path) == OK, "the large palette image is saved")
		_start_cancelled_import()
		expect(State.edit_busy(), "the palette import reports foreground work")
		State.document = VoxelDocument.new()
		State.document.palette.assign([VoxelFrame.material(Color.GREEN)])
		State.palette_changed.emit()
	)
	while not cancelled_done:
		await get_tree().process_frame
	step("Then the old image cannot replace the new document palette", func():
		expect(cancelled_result == ERR_BUSY, "the old palette import is cancelled")
		expect(State.get_palette() == [VoxelFrame.material(Color.GREEN)], "the new document retains its palette")
		expect(not State.undo_redo.has_undo(), "the cancelled import adds no undo action")
		expect(not State.edit_busy(), "the cancelled import releases editing")
	)
	step("When the user saves the built-in high-contrast palette as a PNG", func():
		State.set_palette(State.get_builtin_palette())
		expect(panel.export_palette(export_path) == OK, "the complete built-in palette is saved")
		State.set_palette([VoxelFrame.material(Color.MAGENTA)])
	)
	error = await panel.import_palette(export_path)
	step("Then the PNG restores all 27 colors without changes", func():
		expect(error == OK, "the built-in palette PNG is imported")
		expect(State.get_palette() == State.get_builtin_palette(), "the PNG preserves all 27 built-in colors exactly")
	)
	step("When the current palette is empty", func():
		State.set_palette([])
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


func _materials(colors: PackedColorArray) -> Array[PackedFloat32Array]:
	var materials: Array[PackedFloat32Array] = []
	for color in colors:
		materials.append(VoxelFrame.material(color))
	return VoxelDocument.unique_palette(materials)
