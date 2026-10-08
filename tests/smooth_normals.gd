extends "res://tests/test.gd"

const DOCUMENT_PATH := "user://smooth_normals_test.lve"
const MODEL_PATH := "user://smooth_normals_test.glb"
const SHEET_PATH := "user://smooth_normals_test.png"
const SEAM_CORNER := Vector3(15.5, 15.5, -0.5)

var bar: Node
var settings: PopupMenu
var renderer: VoxelRenderer
var preview: MeshInstance3D
var source_colors := {}
var flat_mesh: Mesh
var smooth_mesh: Mesh
var loaded: VoxelDocument
var exporter: Node
var export_error := OK
var sheet_pixels := PackedByteArray()


func _ready() -> void:
	timeout = 30.0
	test("model settings save smooth shading and keep editor, previews, and exports consistent", _run)


func _run() -> void:
	step("Given a two-color model across four chunks", func():
		State.document = VoxelDocument.new()
		for y in range(14, 18):
			for x in range(14, 18):
				source_colors[Vector3i(x, y, 0)] = Color.RED if x < 16 else Color.BLUE
		State.get_current_voxel_frame().set_cells(source_colors)
		State.frames_changed.emit()
		bar = main.get_node("%MenuBar")
		settings = bar.get_node("ModelSettingsBtn").get_popup()
		renderer = editor_viewport().get_node("ViewportScene/VoxelRenderer")
		exporter = plugin("ExportPlugin")
		preview = load("res://plugins/selection/SelectionPreview.tscn").instantiate()
		main.add_child(preview)
		preview.show_voxels(source_colors, Color.WHITE)
	)
	await _settle()
	step("When the user opens model settings with the gear button", func():
		flat_mesh = renderer._chunk_instances[Vector3i.ZERO].mesh
		bar.get_node("ModelSettingsBtn").show_popup()
	)
	await get_tree().process_frame
	step("Then the dropdown shows the document's flat shading default", func():
		expect(settings.visible and settings.item_count == 1, "the gear opens a compact model settings dropdown")
		expect(settings.get_item_text(0) == "Smooth normals" and settings.is_item_checkable(0), "the dropdown contains a smooth normals checkbox item")
		expect(bar.get_node("ModelSettingsBtn").icon is DPITexture, "the gear supports display-scale rasterization")
		var gear: Button = bar.get_node("ModelSettingsBtn")
		expect(gear.get_index() == bar.get_node("SaveAsBtn").get_index() + 1, "model settings sits beside the document file controls")
		expect(gear.get_index() < bar.get_node("Sep1").get_index(), "model settings belongs to the document controls before undo and redo")
		expect(not settings.is_item_checked(0) and not State.document.smooth_normals, "new documents start with smooth normals off")
		expect(not _has_smooth_normals(flat_mesh), "the default model has flat face normals")
		if DisplayServer.get_name() != "headless":
			RenderingServer.force_draw()
			settings.get_texture().get_image().save_png(_dir() + "/model_settings.png")
			get_tree().root.get_texture().get_image().save_png(_dir() + "/document_toolbar.png")
	)
	step("When the user enables smooth normals", func():
		settings.id_pressed.emit(0)
		settings.hide()
	)
	await _settle()
	step("Then the model and its solid preview have smooth shading", func():
		smooth_mesh = renderer._chunk_instances[Vector3i.ZERO].mesh
		expect(State.document.smooth_normals, "the option belongs to the document")
		expect(_has_smooth_normals(smooth_mesh), "the editor has smooth corner normals")
		expect(_has_smooth_normals(preview.mesh), "the solid preview has smooth corner normals")
		expect(_unit_normals(smooth_mesh), "every smooth normal has unit length")
		expect(smooth_mesh.get_aabb() == flat_mesh.get_aabb(), "smooth shading preserves the voxel shape")
		_expect_source_colors()
		_expect_seam_normal(Vector3.FORWARD)
	)
	step("When the user undoes smooth shading", func():
		State.undo_redo.undo()
	)
	await _settle()
	step("Then flat shading returns in the document and dropdown", func():
		expect(not State.document.smooth_normals and not settings.is_item_checked(0), "undo clears the saved option and menu checkmark")
		expect(renderer._chunk_instances[Vector3i.ZERO].mesh == flat_mesh, "undo reuses the original flat mesh")
		expect(not _has_smooth_normals(preview.mesh), "undo restores flat shading in the solid preview")
	)
	step("When the user redoes smooth shading and quickly toggles it off and on", func():
		State.undo_redo.redo()
		settings.id_pressed.emit(0)
		settings.id_pressed.emit(0)
	)
	await _settle()
	step("Then only the selected shading is displayed", func():
		expect(State.document.smooth_normals and settings.is_item_checked(0), "the latest smooth shading choice stays selected")
		expect(renderer._chunk_instances[Vector3i.ZERO].mesh == smooth_mesh, "the selected smooth mesh is reused")
	)
	step("When the user erases a voxel in a diagonally adjacent chunk", func():
		State.begin_stroke()
		State.paint(Vector3i(16, 16, 0), Color.TRANSPARENT)
		State.end_stroke()
		var affected: Array[Vector3i] = [Vector3i(16, 16, 0)]
		State.cells_changed.emit(0, affected)
	)
	await _settle()
	step("Then the neighboring surfaces update their shared corner normals", func():
		_expect_seam_normal(Vector3(1, 1, -3).normalized(), 3)
		expect(renderer._chunk_instances[Vector3i.ZERO].mesh != smooth_mesh, "a diagonal edit rebuilds the neighboring chunk's normals")
	)
	step("When the user undoes the voxel edit", func():
		State.undo_redo.undo()
	)
	await _settle()
	step("Then the original smooth shading and voxel colors return", func():
		_expect_seam_normal(Vector3.FORWARD)
		_expect_source_colors()
	)
	step("When the user saves the document and opens a new document", func():
		bar.save_doc(DOCUMENT_PATH)
		loaded = VoxelDocument.load_file(DOCUMENT_PATH)
		bar.get_node("NewBtn").pressed.emit()
		expect(not settings.is_item_checked(0), "a new document resets the menu item to flat shading")
	)
	step("When the user loads the saved document", func():
		expect(loaded != null, "the document loads from disk")
		if loaded:
			State.document = loaded
	)
	await _settle()
	step("Then the saved shading choice is restored", func():
		expect(State.document.smooth_normals and settings.is_item_checked(0), "save and load preserve smooth shading and its menu checkmark")
		expect(_has_smooth_normals(renderer._chunk_instances[Vector3i.ZERO].mesh), "the loaded document renders with smooth normals")
		_expect_source_colors()
	)
	export_error = await exporter.export_gltf(MODEL_PATH)
	step("Then glTF preserves smooth normals and valid geometry", func():
		expect(export_error == OK, "the smooth model exports successfully")
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		expect(document.append_from_file(MODEL_PATH, state) == OK, "the smooth glTF file imports")
		var meshes := state.get_meshes()
		expect(meshes.size() == 1, "the export contains the model's frame")
		if not meshes.is_empty():
			var mesh: Mesh = meshes[0].mesh.get_mesh()
			expect(_has_smooth_normals(mesh) and _unit_normals(mesh), "the glTF file retains smooth unit normals")
			var bounds := State.document.bounds()
			expect(mesh.get_aabb().is_equal_approx(AABB(-bounds.size * 0.5, bounds.size)), "the glTF file preserves the complete centered shape")
			var valid_indices := true
			var index_count := 0
			for surface in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(surface)
				for index in arrays[Mesh.ARRAY_INDEX]:
					valid_indices = valid_indices and index >= 0 and index < arrays[Mesh.ARRAY_VERTEX].size()
				index_count += arrays[Mesh.ARRAY_INDEX].size()
			expect(valid_indices and index_count == 288, "every exposed voxel face survives export with valid indices")
	)
	if DisplayServer.get_name() != "headless":
		await _check_sheet_shading()
	step("When the user opens a document that predates the shading option", func():
		State.document = load("res://tests/fixtures/legacy_document.tres")
	)
	step("Then the existing document uses flat shading", func():
		expect(not State.document.smooth_normals and not settings.is_item_checked(0), "existing documents default to flat shading")
	)
	for path in [DOCUMENT_PATH, MODEL_PATH, SHEET_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	preview.free()


func _settle() -> void:
	while not renderer.is_settled() or not preview.is_settled():
		await get_tree().process_frame


func _has_smooth_normals(mesh: Mesh) -> bool:
	for surface in mesh.get_surface_count():
		for normal: Vector3 in mesh.surface_get_arrays(surface)[Mesh.ARRAY_NORMAL]:
			var largest_component := maxf(absf(normal.x), maxf(absf(normal.y), absf(normal.z)))
			if largest_component < 0.99 and normal.length() > 0.99:
				return true
	return false


func _unit_normals(mesh: Mesh) -> bool:
	for surface in mesh.get_surface_count():
		for normal: Vector3 in mesh.surface_get_arrays(surface)[Mesh.ARRAY_NORMAL]:
			if absf(normal.length() - 1.0) > 0.002:
				return false
	return true


func _expect_source_colors() -> void:
	var frame := State.get_current_voxel_frame()
	var preserved := frame.count() == source_colors.size()
	for cell in source_colors:
		preserved = preserved and frame.get_color(cell) == source_colors[cell]
	expect(preserved, "smooth shading preserves every source voxel and color")


func _expect_seam_normal(expected: Vector3, expected_chunks: int = 4) -> void:
	var matches := true
	var chunks := 0
	for chunk: MeshInstance3D in renderer._chunk_instances.values():
		var arrays := chunk.mesh.surface_get_arrays(0)
		var found := false
		for index in arrays[Mesh.ARRAY_VERTEX].size():
			if (arrays[Mesh.ARRAY_VERTEX][index] + chunk.position).is_equal_approx(SEAM_CORNER):
				found = true
				matches = matches and arrays[Mesh.ARRAY_NORMAL][index].distance_to(expected) < 0.002
		if found:
			chunks += 1
	expect(chunks == expected_chunks and matches, "all surface corners share the correct normal across the color boundary")


func _check_sheet_shading() -> void:
	export_error = await exporter.export_sprite_sheet(SHEET_PATH, 0, 0, 64, 1, false)
	step("Given a sprite sheet with smooth shading", func():
		expect(export_error == OK, "the smooth sprite sheet exports")
		var image := Image.new()
		image.load(SHEET_PATH)
		sheet_pixels = image.get_data()
	)
	step("When the user switches to flat shading", func():
		settings.id_pressed.emit(0)
	)
	export_error = await exporter.export_sprite_sheet(SHEET_PATH, 0, 0, 64, 1, false)
	step("Then sprite export follows the document's shading choice", func():
		expect(export_error == OK, "the flat sprite sheet exports")
		var image := Image.new()
		image.load(SHEET_PATH)
		expect(image.get_data() != sheet_pixels, "smooth and flat shading produce different sprite lighting")
	)
