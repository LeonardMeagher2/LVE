extends "res://tests/test.gd"

var menu: Node
var exporter: Node
var first_path := ""
var renamed_path := ""
var light_basis := Basis(Vector3.UP, PI / 3.0)
var export_light_basis := Basis(Vector3.RIGHT, -PI / 4.0)


func _ready() -> void:
	test("document names follow the file and saved settings stay independent", _run)


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
		scene.get_node("%Shadows").button_pressed = false
		exporter._sheet_settings.get_node("SizeRow/Size").value = 24
		exporter._sheet_settings.get_node("ViewRow/View").select(2)
		exporter._sheet_settings.get_node("ViewRow/View").item_selected.emit(2)
		exporter._sheet_settings.get_node("TurntableRow/Turntable").button_pressed = false
		exporter._controls.get_node("ExportRow/Metadata").button_pressed = true
		exporter._model_camera._yaw = deg_to_rad(30.0)
		exporter._model_camera._pitch = deg_to_rad(20.0)
		exporter._model_camera._dist = 17.0
		exporter._model_camera._init_dist = 21.0
		exporter._model_camera._target = Vector3(2, 3, 4)
		exporter._model_camera.is_orthogonal = true
		exporter._model_camera._update()
		exporter._model_scene.get_node("%LightColor").color_changed.emit(Color(0, 0, 1))
		var export_lighting: Dictionary = exporter._model_scene.get_lighting_settings()
		export_lighting.basis = export_light_basis
		exporter._model_scene.set_lighting_settings(export_lighting)
		exporter._model_scene.get_node("%Shadows").button_pressed = false
		exporter._model_scene.get_node("%LockView").button_pressed = true
		expect(menu.save_doc(first_path) == OK, "the document saves with the current settings")
	)
	step("Then the saved document uses its filename", func():
		expect(FileAccess.file_exists(first_path), "the document file exists")
		expect(State.document.get_file_name() == first_path.get_file(), "the document name is the file name")
		expect(get_window().title == first_path.get_file() + " - " + VoxelDocument.APP_NAME, "the app title follows the saved file name")
		var data := VoxelDocument.load_file(first_path).document_data()
		expect(not data.has("title") and not data.has("file_path"), "the file stores no title or source path")
		expect(State.document.lighting_settings.has("shaded") and State.document.lighting_settings.has("shadows"), "the document stores the editor view options")
		expect(not State.document.lighting_settings.shadows, "the document stores the Shadows choice")
		expect(State.document.lighting_settings.color == Color.RED, "export color changes preserve the editor light color")
		expect(State.document.lighting_settings.basis.is_equal_approx(light_basis), "the document stores the editor light direction")
		expect(State.document.export_settings.lighting.basis.is_equal_approx(export_light_basis), "the document stores the independent export light direction")
		expect(State.document.export_settings.lighting.view_locked, "the document stores the export view lock")
		var camera: Dictionary = State.document.export_settings.camera
		expect(camera.orthographic, "the document stores the export projection")
		expect(is_equal_approx(camera.yaw, deg_to_rad(30.0)) and is_equal_approx(camera.pitch, deg_to_rad(20.0)), "the document stores the export camera angle")
		expect(camera.target.is_equal_approx(Vector3(2, 3, 4)), "the document stores the export camera offset")
		expect(is_equal_approx(camera.distance, 17.0) and is_equal_approx(camera.initial_distance, 21.0), "the document stores the export camera zoom")
		expect(not State.document.lighting_settings.view_locked, "the document stores the unlocked state")
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
	step("Then saved settings and view options return", func():
		expect(get_window().title == renamed_path.get_file() + " - " + VoxelDocument.APP_NAME, "opening a document changes the app title")
		expect(viewport_scene().get_lighting_settings().basis.is_equal_approx(light_basis), "the editor light direction is restored")
		expect(exporter._model_scene.get_lighting_settings().basis.is_equal_approx(export_light_basis), "the export light direction is restored")
		expect(not viewport_scene().get_lighting_settings().shadows, "the editor restores the saved Shadows view option")
		expect(exporter._sheet_settings.get_node("SizeRow/Size").value == 24, "the manual frame size is restored")
		expect(exporter._sheet_settings.get_node("ViewRow/View").selected == 2, "the selected sprite view is restored")
		expect(not exporter._sheet_settings.get_node("TurntableRow/Turntable").button_pressed, "the saved turntable choice is restored")
		expect(exporter._controls.get_node("ExportRow/Metadata").button_pressed, "the saved metadata choice is restored")
		expect(exporter._sheet_lighting().color == Color(0, 0, 1), "the export color is restored")
		expect(exporter._model_scene.get_lighting_settings().view_locked, "the export view lock is restored")
		exporter._refresh_model()
		expect(exporter._model_camera.is_orthogonal, "the export orthographic projection is restored")
		expect(is_equal_approx(exporter._model_camera._yaw, deg_to_rad(30.0)) and is_equal_approx(exporter._model_camera._pitch, deg_to_rad(20.0)), "the export camera angle is restored")
		expect(exporter._model_camera._target.is_equal_approx(Vector3(2, 3, 4)), "the export camera offset is restored")
		expect(is_equal_approx(exporter._model_camera._dist, 17.0), "the export camera zoom is restored")
		expect(exporter.current_export_settings().sprite.orthographic, "the sprite projection follows the restored camera")
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
