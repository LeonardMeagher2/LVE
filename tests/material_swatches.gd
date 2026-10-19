extends "res://tests/test.gd"

var panel: PalettePanel
var frame: VoxelFrame
var plain := VoxelFrame.material(Color.RED)
var metal := VoxelFrame.material(Color.RED, Color(0.5, 0, 0), 0.75, 0.25)
var variant := VoxelFrame.material(Color.RED, Color(0.5, 0, 0), 0.9, 0.25)
var original_default: Array[PackedFloat32Array] = []


func _ready() -> void:
	test("Material swatches keep separate identities and edit future strokes without changing voxels", _run)


func _run() -> void:
	step("Given two red swatches with different material values", func():
		panel = main.find_child("PalettePanel", true, false)
		State.document = VoxelDocument.new()
		State.set_palette([plain, metal])
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, plain)
		State.select_palette_entry(1)
		State.undo_redo.clear_history()
		expect(State.current_material == metal and State.current_palette_index == 1, "the selected swatch supplies all material values")
		expect(not panel.get_node("%SwatchGrid").get_child(0).button_pressed and panel.get_node("%SwatchGrid").get_child(1).button_pressed, "only the selected index has a selection border")
		expect(is_equal_approx(panel.get_node("%Metallic").value, 0.75), "the controls show the selected metallic")
		expect(is_equal_approx(panel.get_node("%EmissionStrength").value, 0.5), "the controls show emission strength")
		expect(panel.find_child("EmissionColor", true, false) == null and panel.find_child("DuplicateBtn", true, false) == null, "the palette omits separate emission color and Duplicate controls")
	)
	step("When the user adds another same-color material variant", func():
		State.set_material(variant)
		panel.get_node("%AddBtn").pressed.emit()
		expect(State.get_palette() == [plain, metal, variant], "different full materials retain separate swatches")
		expect(State.current_palette_index == 2, "the new variant has its own selected index")
		State.undo_redo.clear_history()
	)
	step("When the user changes the variant's material controls in one edit", func():
		State.begin_material_edit()
		panel.get_node("%Metallic").value = 0.6
		panel.get_node("%Metallic").value = 0.4
		panel.get_node("%Roughness").value = 0.8
		State.end_material_edit()
	)
	step("Then the controls change the future stroke and one undo restores the edit", func():
		expect(State.get_palette()[2] == variant, "the palette keeps every saved swatch")
		expect(is_equal_approx(State.current_material[VoxelFrame.MATERIAL_METALLIC], 0.4), "the controls supply the edited metallic")
		expect(frame.chunks[Vector3i.ZERO].matches(Vector3i.ZERO, plain), "editing a control preserves existing voxels")
		expect(State.current_palette_index == -1, "the edited material matches no saved swatch")
		State.undo_redo.undo()
		expect(State.current_material == variant and State.current_palette_index == 2, "undo restores the control values and their swatch")
		expect(not State.undo_redo.has_undo(), "the control edit creates one undo action")
		State.undo_redo.redo()
		expect(is_equal_approx(State.current_material[VoxelFrame.MATERIAL_ROUGHNESS], 0.8), "redo restores the edited roughness")
	)
	step("When the user edits the color control", func():
		panel.get_node("%ColorPicker").color_changed.emit(Color.BLUE)
		expect(VoxelFrame.material_color(State.current_material) == Color.BLUE, "the control supplies the new color")
		expect(is_equal_approx(State.current_material[VoxelFrame.MATERIAL_METALLIC], 0.4), "the color edit keeps the material values")
		expect(State.current_material[VoxelFrame.MATERIAL_EMISSION] == 0.0 and State.current_material[VoxelFrame.MATERIAL_EMISSION + 2] == 0.5, "emission follows the changed voxel color")
		expect(State.get_palette()[2] == variant, "a color edit preserves every saved swatch")
		expect(State.current_palette_index == -1, "the changed color matches no saved swatch")
		expect(frame.get_color(Vector3i.ZERO) == Color.RED, "the existing voxel keeps its original color")
	)
	step("When a numeric control changes several times during one drag", func():
		State.undo_redo.clear_history()
		panel.get_node("%Metallic").edit_started.emit()
		panel.get_node("%Metallic").value = 0.5
		panel.get_node("%Metallic").value = 0.9
		panel.get_node("%Metallic").edit_finished.emit(false)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the drag creates one undo action", func():
		expect(is_equal_approx(State.current_material[VoxelFrame.MATERIAL_METALLIC], 0.9), "the last drag value becomes current")
		State.undo_redo.undo()
		expect(is_equal_approx(State.current_material[VoxelFrame.MATERIAL_METALLIC], 0.4), "undo restores the value before the drag")
		expect(not State.undo_redo.has_undo(), "the drag creates only one undo action")
	)
	step("When emission strength changes during one control edit", func():
		State.undo_redo.clear_history()
		State.begin_material_edit()
		panel.get_node("%EmissionStrength").value = 0.25
		panel.get_node("%EmissionStrength").value = 0.75
		State.end_material_edit()
		expect(State.current_material[VoxelFrame.MATERIAL_EMISSION] == 0.0 and State.current_material[VoxelFrame.MATERIAL_EMISSION + 2] == 0.75, "emission RGB combines the voxel color and strength")
		State.undo_redo.undo()
		expect(State.current_material[VoxelFrame.MATERIAL_EMISSION + 2] == 0.5 and not State.undo_redo.has_undo(), "one undo restores the complete emission edit")
	)
	step("When the user removes a same-color variant and undoes it", func():
		State.select_palette_entry(1)
		State.remove_palette_entry()
		expect(State.get_palette().size() == 2 and State.get_palette()[0] == plain, "removal uses the selected entry rather than its color")
		State.undo_redo.undo()
		expect(State.get_palette()[1] == metal and State.current_palette_index == 1, "undo restores the correct variant and index")
	)
	step("When the user adds a material that already exists", func():
		State.undo_redo.clear_history()
		panel.get_node("%AddBtn").pressed.emit()
		expect(State.get_palette().size() == 3 and State.current_palette_index == 1, "Add selects the existing material instead of duplicating it")
		expect(not State.undo_redo.has_undo(), "an exact match adds no entry and no undo action")
	)
	step("When a control edit reaches an exact saved material", func():
		var before := State.get_palette()
		State.begin_material_edit()
		State.edit_material(plain)
		State.end_material_edit()
		expect(State.get_palette() == before, "the edit preserves every saved swatch")
		expect(State.current_material == plain and State.current_palette_index == 0, "a material that matches a swatch selects it")
		State.undo_redo.undo()
		expect(State.current_material == metal and State.current_palette_index == 1, "undo restores the previous material and its swatch")
		expect(State.get_palette() == before, "undo leaves every saved swatch in place")
	)
	step("Then current values, swatches, and voxels have separate ownership", func():
		var current := State.current_material
		current[VoxelFrame.MATERIAL_METALLIC] = 0.0
		var palette := State.get_palette()
		palette[1][VoxelFrame.MATERIAL_METALLIC] = 0.0
		expect(State.current_material == metal and State.get_palette()[1] == metal, "returned copies preserve the selected material")
		expect(frame.chunks[Vector3i.ZERO].matches(Vector3i.ZERO, plain), "palette copies preserve the voxel material")
	)
	step("When the document saves and loads its material palette", func():
		var loaded := VoxelDocument.decode_document(State.document.encode_document())
		expect(loaded != null, "the material document loads")
		if loaded:
			expect(loaded.palette == State.get_palette(), "all swatch values and repeated colors survive loading")
			expect(loaded.frames[0].chunks[Vector3i.ZERO].matches(Vector3i.ZERO, plain), "the loaded voxel stays independent of its swatches")
	)
	step("When an older color-only document loads", func():
		var fields := State.document.document_data()
		fields.palette = PackedColorArray([Color.RED, Color.BLUE, Color.RED])
		var loaded := VoxelDocument.decode_document(_legacy_bytes(fields))
		expect(loaded != null and loaded.palette == [plain, VoxelFrame.material(Color.BLUE)], "older colors receive default material values")
	)
	step("When palette data contains repeated complete materials", func():
		var fields := State.document.document_data()
		fields.palette = [plain, metal, metal]
		var loaded := VoxelDocument.decode_document(_legacy_bytes(fields, VoxelDocument.FORMAT_VERSION))
		expect(loaded != null and loaded.palette == [plain, metal], "loading combines only exact material matches")
		State.set_palette([plain, metal, metal])
		expect(State.get_palette() == [plain, metal], "palette replacement combines only exact material matches")
	)
	step("Then a change to any material parameter makes a distinct swatch", func():
		var entries: Array[PackedFloat32Array] = [plain, VoxelFrame.material(Color.RED, Color(0.5, 0, 0)), VoxelFrame.material(Color.RED, Color.BLACK, 0.5), VoxelFrame.material(Color.RED, Color.BLACK, 0.0, 0.5)]
		State.set_palette(entries)
		expect(State.get_palette() == entries, "emission, metallic, and roughness each distinguish same-color swatches")
	)
	step("When an older custom startup palette loads", func():
		original_default = State.default_palette
		var path := "user://material_swatches_legacy.cfg"
		var config := ConfigFile.new()
		config.set_value("palette", "colors", PackedColorArray([Color.BLUE, Color.RED]))
		expect(config.save(path) == OK, "the old startup palette saves")
		State.load_default_palette(path)
		expect(State.default_palette == [VoxelFrame.material(Color.BLUE), plain], "older startup colors receive default material values")
		State.default_palette = original_default
		DirAccess.remove_absolute(path)
	)
	step("Then invalid material palette data is rejected", func():
		var document := VoxelDocument.new()
		var invalid := metal.duplicate()
		invalid[VoxelFrame.MATERIAL_METALLIC] = NAN
		document.palette.append(invalid)
		expect(document.encode_document().is_empty(), "palette material values must be finite")
		invalid[VoxelFrame.MATERIAL_METALLIC] = 2.0
		expect(document.encode_document().is_empty(), "palette material values must stay within zero and one")
		invalid.resize(8)
		expect(document.encode_document().is_empty(), "palette entries must hold all nine values")
	)
	step("When a color-only PNG includes repeated and transparent swatches", func():
		State.set_palette([VoxelFrame.material(Color.TRANSPARENT), plain, metal])
		expect(panel.export_palette("user://material_swatches.png") == OK, "the palette PNG saves")
		State.set_palette([])
	)
	var error := await panel.import_palette("user://material_swatches.png")
	step("Then the PNG restores each swatch without material settings", func():
		expect(error == OK, "the palette PNG imports")
		expect(State.get_palette() == [VoxelFrame.material(Color.TRANSPARENT), plain], "PNG import retains transparent colors and combines exact default materials")
		DirAccess.remove_absolute("user://material_swatches.png")
		var image := Image.create(32, 16, false, Image.FORMAT_RGBA8)
		image.fill(Color.RED)
		expect(image.save_png("user://material_swatches_plain.png") == OK, "the ordinary tiled image saves")
	)
	error = await panel.import_palette("user://material_swatches_plain.png")
	step("Then an ordinary image still imports unique visible colors", func():
		expect(error == OK and State.get_palette() == [plain], "an ordinary image adds one entry per color")
		DirAccess.remove_absolute("user://material_swatches_plain.png")
	)


func _legacy_bytes(fields: Dictionary, version := 2) -> PackedByteArray:
	var payload := var_to_bytes(fields)
	var bytes := PackedByteArray(VoxelDocument.FILE_SIGNATURE)
	bytes.resize(16)
	bytes.encode_u32(4, version)
	bytes.encode_u32(8, payload.size())
	bytes.encode_u32(12, VoxelDocument._crc32(payload))
	bytes.append_array(payload)
	return bytes
