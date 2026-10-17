extends "res://tests/test.gd"

var menu: Node
var exporter: Node
var first_path := ""
var renamed_path := ""
var light_basis := Basis(Vector3.UP, PI / 3.0)
var export_light_basis := Basis(Vector3.RIGHT, -PI / 4.0)


func _ready() -> void:
	test("document names follow the file and saved settings stay separate from view options", _run)


func _run() -> void:
	step("Given a new document", func():
		menu = main.get_node("%MenuBar")
		exporter = plugin("ExportPlugin")
		var prefix := "user://voxel_document_name_%s" % Time.get_ticks_usec()
		first_path = prefix + ".lve"
		renamed_path = prefix + "_renamed.lve"
		menu._on_new_btn_pressed()
		expect(get_window().title == "Untitled - " + VoxelDocument.APP_NAME, "the new document has an untitled app window")
	)
	step("When the user changes lighting and export settings", func():
		var scene := viewport_scene()
		var lighting: Dictionary = scene.get_lighting_settings()
		lighting.basis = light_basis
		lighting.color = Color.RED
		scene.set_lighting_settings(lighting)
		var popup := camera_menu().get_popup()
		for index in popup.item_count:
			if popup.get_item_text(index) == "Shadows":
				scene._on_camera_index_pressed(index)
		exporter._sheet_settings.get_node("SizeRow/Size").value = 24
		exporter._sheet_settings.get_node("ViewRow/View").select(2)
		exporter._sheet_settings.get_node("ViewRow/View").item_selected.emit(2)
		exporter._sheet_settings.get_node("TurntableRow/Turntable").button_pressed = false
		exporter._sheet_settings.get_node("TurntableRow/Metadata").button_pressed = false
		exporter._controls.get_node("LightingOptions/LightColor").color = Color(0, 0, 1, 0.5)
		exporter._on_sheet_lighting_changed()
		var export_lighting: Dictionary = exporter._model_scene.get_lighting_settings()
		export_lighting.basis = export_light_basis
		exporter._model_scene.set_lighting_settings(export_lighting)
		exporter._controls.get_node("LightingOptions/Shadows").button_pressed = false
		expect(menu.save_doc(first_path) == OK, "the document saves with the current settings")
	)
	step("Then the saved document uses its filename", func():
		expect(FileAccess.file_exists(first_path), "the document file exists")
		expect(State.document.get_file_name() == first_path.get_file(), "the document name is the file name")
		expect(get_window().title == first_path.get_file() + " - " + VoxelDocument.APP_NAME, "the app title follows the saved file name")
		var data := VoxelDocument.load_file(first_path).document_data()
		expect(not data.has("title") and not data.has("file_path"), "the file stores no title or source path")
		expect(not State.document.lighting_settings.has("shaded") and not State.document.lighting_settings.has("shadows"), "editor view options stay outside saved lighting")
		expect(State.document.lighting_settings.color == Color.RED, "export color changes preserve the editor light color")
		expect(State.document.lighting_settings.basis.is_equal_approx(light_basis), "the document stores the editor light direction")
		expect(State.document.export_settings.lighting.basis.is_equal_approx(export_light_basis), "the document stores the independent export light direction")
	)
	step("When the user saves under another file name", func():
		menu.save_doc(renamed_path)
	)
	step("Then the app title follows the new filename", func():
		expect(get_window().title == renamed_path.get_file() + " - " + VoxelDocument.APP_NAME, "Save As changes the app title")
	)
	step("When the user starts a new document and opens the saved file", func():
		menu._on_new_btn_pressed()
		expect(menu.current_save_path.is_empty(), "the new document has no previous save path")
		menu._on_file_opened(renamed_path)
	)
	step("Then saved settings return without changing editor view options", func():
		expect(get_window().title == renamed_path.get_file() + " - " + VoxelDocument.APP_NAME, "opening a document changes the app title")
		expect(viewport_scene().get_lighting_settings().basis.is_equal_approx(light_basis), "the editor light direction is restored")
		expect(exporter._model_scene.get_lighting_settings().basis.is_equal_approx(export_light_basis), "the export light direction is restored")
		expect(not viewport_scene().get_lighting_settings().shadows, "the editor keeps its current Shadows view option")
		expect(exporter._sheet_settings.get_node("SizeRow/Size").value == 24, "the manual frame size is restored")
		expect(exporter._sheet_settings.get_node("ViewRow/View").selected == 2, "the selected sprite view is restored")
		expect(not exporter._sheet_settings.get_node("TurntableRow/Turntable").button_pressed, "the saved turntable choice is restored")
		expect(not exporter._sheet_settings.get_node("TurntableRow/Metadata").button_pressed, "the saved metadata choice is restored")
		expect(exporter._controls.get_node("LightingOptions/LightColor").color == Color(0, 0, 1, 0.5), "the export color and alpha strength are restored")
	)
	step("When the user edits the document and opens the same file again", func():
		State.paint(Vector3i(100, 100, 100), VoxelFrame.material(Color.RED))
		menu._on_file_opened(renamed_path)
	)
	step("Then the file contents replace the unsaved edit", func():
		expect(not State.document.has_cell(0, Vector3i(100, 100, 100)), "opening the same path restores the saved contents")
		expect(get_window().title == renamed_path.get_file() + " - " + VoxelDocument.APP_NAME, "the filename controls the app title")
	)
	for path in [first_path, renamed_path]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
