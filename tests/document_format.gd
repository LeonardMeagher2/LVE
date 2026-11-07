extends "res://tests/test.gd"

var source: VoxelDocument
var menu: Node
var prefix := ""
var paths: Array[String] = []
var preview: Image
var encoded := PackedByteArray()
var saved := PackedByteArray()


func _ready() -> void:
	timeout = 30.0
	test("LVE documents preserve animation data and PNG files fall back to image import", _run)


func _run() -> void:
	step("Given an animation with an empty frame, tags, colors, and saved settings", func():
		menu = main.get_node("%MenuBar")
		prefix = "user://lve_format_%s" % Time.get_ticks_usec()
		source = VoxelDocument.new()
		State.document = source
		source.frames[0].set_cell(Vector3i(-17, 3, -1), VoxelFrame.material(Color(0.25, 0.5, 0.75, 0.5)))
		var solid := {}
		for z in 16:
			for y in 16:
				for x in 16:
					solid[Vector3i(x, y, z)] = VoxelFrame.material(Color.RED)
		source.frames[0].set_cells(solid)
		source.frames[0].delay_ms = 123
		source.add_frame().delay_ms = 250
		source.add_frame(0).delay_ms = 400
		source.palette.assign([VoxelFrame.material(Color.BLACK), VoxelFrame.material(Color.RED, Color(0.5, 0.25, 0.125), 0.75, 0.25), VoxelFrame.material(Color(0.25, 0.5, 0.75, 0.5))])
		source.tags.clear()
		for mode in 4:
			source.add_tag("Tag %s 🦩" % mode, 0, 2, mode, mode)
		source.smooth_normals = true
		source.size = Vector3i(5, 6, 7)
		source.lighting_settings = {"basis": Basis(Vector3.UP, 0.5), "color": Color(1, 0.5, 0.25, 0.75), "ambient_color": Color(0.2, 0.3, 0.4, 0.5)}
		source.export_settings = {"view": 7, "sprite_ortho": false, "sprite_center": false, "automatic_size": true, "frame_size": 64.0, "turntable": false, "views": 12.0, "metadata": true, "center": false, "model_tag": 1, "sheet_tag": 2,
			"lighting": {"basis": Basis.IDENTITY, "color": Color.WHITE, "ambient_color": Color.BLUE, "energy": 0.5, "ambient_energy": 0.25, "shadows": false, "shaded": true, "view_locked": true, "view_basis": Basis.IDENTITY},
			"camera": {"yaw": 0.5, "pitch": 0.25, "distance": 10.0, "initial_distance": 12.0, "target": Vector3(1, 2, 3), "orthographic": true, "fov": 45.0}}
		preview = Image.create(2, 2, false, Image.FORMAT_RGBA8)
		preview.fill(Color.TRANSPARENT)
		preview.set_pixel(0, 0, Color.RED)
		encoded = source.encode_document()
		expect(not encoded.is_empty(), "the animation has a data-only encoding")
		expect(encoded.decode_u32(4) == 3, "material palettes use document version 3")
		expect(encoded.size() < 8192, "uniform voxel regions keep the document compact")
	)
	step("When the user saves both document formats", func():
		expect(source.save_file(_path(".lve")) == OK, "the binary document saves")
		expect(source.save_file(_path(".lve.png"), preview) == OK, "the PNG document saves")
	)
	step("Then the application uses the flamingo SVG", func():
		var vector := Image.new()
		expect(vector.load_svg_from_string(FileAccess.get_file_as_string("res://icon.svg")) == OK, "the flamingo SVG loads")
		expect(vector.get_size() == Vector2i(128, 128) and not vector.is_invisible(), "the vector icon renders on its original canvas")
		expect(ProjectSettings.get_setting("application/config/icon") == "res://icon.svg", "the application uses the flamingo SVG as its icon")
		expect(ProjectSettings.get_setting("application/config/name") == VoxelDocument.APP_NAME, "the project uses Leonard's Voxel Editor branding")
	)
	step("Then both formats restore the complete animation", func():
		for suffix in [".lve", ".lve.png"]:
			var loaded := VoxelDocument.load_file(prefix + suffix)
			expect(loaded != null, "the %s document loads" % suffix)
			if loaded:
				expect(loaded.document_data() == source.document_data(), "the %s file preserves every document field" % suffix)
				expect(loaded.size == source.size, "the file preserves the centered document size")
				expect(not loaded.export_settings.sprite_center, "the file preserves the sprite Center choice")
				expect(loaded.export_settings.automatic_size, "the file retains compatible legacy export settings")
				expect(loaded.frames[1].count() == 0, "the empty frame retains its position")
				expect(loaded.frames[0].count() == 4097, "the document restores every occupied voxel")
				loaded.frames[2].set_cell(Vector3i.ZERO, VoxelFrame.material(Color.BLUE))
				expect(loaded.frames[0].get_color(Vector3i.ZERO) == Color.RED, "loaded frames can be edited independently")
		var visible := Image.new()
		expect(visible.load_png_from_buffer(FileAccess.get_file_as_bytes(prefix + ".lve.png")) == OK, "standard PNG decoding reads the preview")
		expect(visible.get_data() == preview.get_data(), "the PNG chunk preserves every preview pixel")
		expect(menu.document_basename("Leonard.lve.png") == "Leonard", "Save As removes the complete document suffix")
	)
	step("When the user opens a document PNG renamed to a plain PNG", func():
		_write(_path("_renamed.png"), FileAccess.get_file_as_bytes(prefix + ".lve.png"))
		menu._on_new_btn_pressed()
		menu._on_file_opened(prefix + "_renamed.png")
	)
	step("Then the embedded document takes priority over image import", func():
		expect(State.document.frames.size() == 3 and State.document.frames[0].count() == 4097, "the PNG opens as the complete animation")
		expect(menu.current_save_path == prefix + "_renamed.png", "Save retains the opened PNG format")
	)
	step("When the user switches the Save As format", func():
		menu._on_save_as_btn_pressed()
		var dialog: FileDialog = menu.get_node("FileDialog")
		expect(dialog.current_file.ends_with(".lve.png"), "Save As starts with the opened document format")
		menu._save_format.select(0)
		menu._save_format.item_selected.emit(0)
		menu._save_format.select(1)
		menu._save_format.item_selected.emit(1)
		expect(dialog.current_file == (prefix + "_renamed").get_file() + ".lve.png", "switching formats keeps one document suffix")
		menu._save_format.select(0)
		menu._save_format.item_selected.emit(0)
		expect(dialog.current_file == (prefix + "_renamed").get_file() + ".lve", "switching to binary removes the complete PNG document suffix")
		dialog.hide()
	)
	step("When the user saves changes over an existing binary document", func():
		State.document.frames[0].set_cell(Vector3i.ZERO, VoxelFrame.material(Color.BLUE))
		expect(menu.save_doc(prefix + ".lve") == OK, "the edited document saves")
		saved = FileAccess.get_file_as_bytes(prefix + ".lve")
	)
	step("Then the replacement contains the latest edit", func():
		var loaded := VoxelDocument.load_file(prefix + ".lve")
		expect(loaded != null and loaded.frames[0].get_color(Vector3i.ZERO) == Color.BLUE, "saving replaces the existing document")
	)
	step("When a save has invalid data or an inaccessible destination", func():
		State.document.frames[0].delay_ms = 0
		expect(State.document.save_file(prefix + ".lve") == ERR_INVALID_DATA, "invalid data reports a save error")
		State.document.frames[0].delay_ms = 123
		expect(menu.save_doc(prefix + "/missing.lve") != OK, "an inaccessible destination reports a save error")
		menu.get_node("FileError").hide()
	)
	step("Then the previous save and current document path remain available", func():
		expect(FileAccess.get_file_as_bytes(prefix + ".lve") == saved, "a failed save preserves the existing file")
		expect(menu.current_save_path == prefix + ".lve" and State.document.file_path == prefix + ".lve", "a failed save preserves the current path")
	)
	step("When shared files contain invalid document data", _check_invalid_documents)
	step("Then failed document opening preserves the current document and undo history", func():
		var previous := State.document
		# This case proves history preservation, not the document size limit.
		State.document.size = Vector3i.ZERO
		var tx := State.begin_edit()
		State.paint(Vector3i(100, 0, 0), VoxelFrame.material(Color.GREEN))
		State.finish_edit(tx)
		menu._on_file_opened(prefix + "_invalid.lve")
		menu.get_node("FileError").hide()
		expect(State.document == previous and State.undo_redo.has_undo(), "failed opening preserves the document and history")
		expect(menu.current_save_path == prefix + ".lve", "failed opening preserves the save path")
	)
	for suffix in ["_ordinary.lve.png", "_invalid_chunk.png", "_unsupported.png", "_bad_crc.png", "_duplicate.png"]:
		step("Given a PNG with absent or invalid document data", func():
			var bytes := preview.save_png_to_buffer()
			if suffix != "_ordinary.lve.png":
				var document_bytes := encoded.duplicate()
				if suffix == "_unsupported.png":
					document_bytes.encode_u32(4, 99)
				else:
					document_bytes[12] ^= 1
				bytes = VoxelDocument.document_png(preview, document_bytes)
				if suffix == "_bad_crc.png":
					bytes[bytes.size() - 13] ^= 1
				if suffix == "_duplicate.png":
					var second := VoxelDocument.document_png(preview, encoded)
					var chunk_start := preview.save_png_to_buffer().size() - 12
					var duplicate := bytes.slice(0, bytes.size() - 12)
					duplicate.append_array(second.slice(chunk_start))
					bytes = duplicate
			_write(_path(suffix), bytes)
		)
		step("When the user opens that PNG", func(): pass)
		await menu._on_file_opened(prefix + suffix)
		step("Then the visible image becomes a voxel document", func():
			expect(State.document.frames.size() == 1 and State.document.frames[0].count() == 1, "the preview imports as one image voxel")
			expect(State.document.frames[0].get_color(State.document.frames[0].positions()[0]) == Color.RED, "image fallback preserves the visible color")
			expect(menu.current_save_path.is_empty(), "image fallback starts without a document save path")
		)
	if DisplayServer.get_name() != "headless":
		await _check_rendered_save()
	for path in paths:
		DirAccess.remove_absolute(path)


func _check_invalid_documents() -> void:
	var invalid := encoded.duplicate()
	invalid[0] = 0
	_reject(invalid, "an invalid signature is rejected")
	invalid = encoded.duplicate()
	invalid.encode_u32(4, 99)
	_reject(invalid, "an unsupported version is rejected")
	_reject(encoded.slice(0, encoded.size() - 1), "a truncated file is rejected")
	invalid = encoded.duplicate()
	invalid.append(0)
	_reject(invalid, "trailing document bytes are rejected")
	invalid = encoded.duplicate()
	invalid[invalid.size() - 1] ^= 1
	_reject(invalid, "payload corruption is rejected")
	for nodes in [PackedInt32Array([-2]), PackedInt32Array([-1]), PackedInt32Array([100]), PackedInt32Array([1, 0])]:
		var fields := source.document_data().duplicate(true)
		var record: Array = fields.frames[0].voxels[1][0]
		record[record.size() - 1] = nodes
		_reject(_wrap(var_to_bytes(fields)), "invalid octree nodes are rejected")
	var fields := source.document_data().duplicate(true)
	fields.frames[0].voxels[1].append(fields.frames[0].voxels[1][0])
	_reject(_wrap(var_to_bytes(fields)), "duplicate chunks are rejected")
	fields = source.document_data().duplicate(true)
	fields.tags[0].to = 99
	_reject(_wrap(var_to_bytes(fields)), "invalid tag ranges are rejected")
	fields = source.document_data().duplicate(true)
	fields.lighting.basis = Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	_reject(_wrap(var_to_bytes(fields)), "singular lighting data is rejected")
	fields = source.document_data().duplicate(true)
	fields.export.camera.distance = NAN
	_reject(_wrap(var_to_bytes(fields)), "non-finite settings are rejected")
	_reject(_wrap(var_to_bytes_with_objects(Resource.new())), "serialized objects are rejected")
	var typed: Array[Resource] = []
	_reject(_wrap(var_to_bytes(typed)), "typed object containers are rejected")
	var short_array := PackedByteArray()
	short_array.resize(8)
	short_array.encode_u32(0, TYPE_ARRAY)
	short_array.encode_u32(4, 1000000000)
	_reject(_wrap(short_array), "excessive container counts are rejected before decoding")
	var deep: Variant = 1
	for level in 20:
		deep = [deep]
	_reject(_wrap(var_to_bytes(deep)), "excessive nesting is rejected before decoding")
	var full_chunks := []
	for index in 1025:
		full_chunks.append([Vector3i(index, 0, 0), PackedColorArray([Color.TRANSPARENT, Color.RED]), PackedColorArray(), PackedColorArray(), PackedInt32Array([1])])
	fields = source.document_data().duplicate(true)
	fields.frames[0].voxels = [1, full_chunks]
	_reject(_wrap(var_to_bytes(fields)), "excessive voxel expansion is rejected before allocation")
	_write(prefix + "_invalid.lve", invalid)


func _check_rendered_save() -> void:
	State.document = source
	State.current_frame = 1
	step("When the user saves a rendered PNG document", func(): pass)
	await menu.save_doc(_path("_rendered.lve.png"))
	step("Then the first frame appears in a readable document preview", func():
		var image := Image.new()
		expect(image.load_png_from_buffer(FileAccess.get_file_as_bytes(prefix + "_rendered.lve.png")) == OK, "the rendered PNG opens in an image decoder")
		expect(image.get_size() == Vector2i(256, 256) and not image.is_invisible(), "the document preview contains the rendered first frame")
		expect(VoxelDocument.load_file(prefix + "_rendered.lve.png").document_data() == source.document_data(), "the rendered document preserves every document field")
		expect(menu.current_save_path == prefix + "_rendered.lve.png", "Save retains the preview format")
		expect(State.current_frame == 1, "rendering the first frame preserves the editor's selected frame")
	)
	source.frames[0].set_cell(Vector3i.ZERO, VoxelFrame.material(Color.GREEN))
	step("When the user presses Save for the same PNG", func():
		menu.get_node("SaveBtn").pressed.emit()
	)
	while State.edit_busy():
		await get_tree().process_frame
	step("Then the existing PNG contains the latest edit", func():
		expect(VoxelDocument.load_file(prefix + "_rendered.lve.png").frames[0].get_color(Vector3i.ZERO) == Color.GREEN, "PNG overwrite retains the full edited document")
	)
	step("Given an animation with an empty first frame", func():
		source.frames[0].clear()
		State.frames_changed.emit()
	)
	await menu.save_doc(menu.current_save_path)
	step("Then the preview is transparent and the complete animation remains available", func():
		var image := Image.new()
		image.load_png_from_buffer(FileAccess.get_file_as_bytes(menu.current_save_path))
		expect(image.is_invisible(), "an empty first frame produces a transparent preview")
		var loaded := VoxelDocument.load_file(menu.current_save_path)
		expect(loaded != null and loaded.frames.size() == 3 and loaded.frames[2].count() == 4097, "transparent previews retain the animation's occupied frames")
	)


func _wrap(payload: PackedByteArray) -> PackedByteArray:
	var result := PackedByteArray(VoxelDocument.FILE_SIGNATURE)
	result.resize(16)
	result.encode_u32(4, VoxelDocument.FORMAT_VERSION)
	result.encode_u32(8, payload.size())
	result.encode_u32(12, VoxelDocument._crc32(payload))
	result.append_array(payload)
	return result


func _reject(bytes: PackedByteArray, description: String) -> void:
	var path := _path("_invalid.lve")
	_write(path, bytes)
	expect(VoxelDocument.load_file(path) == null, description)


func _path(suffix: String) -> String:
	var path := prefix + suffix
	if not paths.has(path):
		paths.append(path)
	return path


func _write(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
