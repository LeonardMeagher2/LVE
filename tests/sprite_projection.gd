extends "res://tests/test.gd"

var exporter: Node
var path := ""


func _ready() -> void:
	timeout = 20.0
	test("changing sprite projection preserves the voxel pixel scale", _run)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		return
	step("Given a center voxel and an animation with wide document bounds", func():
		exporter = plugin("ExportPlugin")
		State.document = VoxelDocument.new()
		State.document.set_cell(0, Vector3i.ZERO, Color.RED)
		State.document.add_frame()
		State.document.set_cell(1, Vector3i(-8, -8, -8), Color.BLUE)
		State.document.add_frame()
		State.document.set_cell(2, Vector3i(8, 8, 8), Color.BLUE)
		State.frames_changed.emit()
		exporter._refresh_model()
		exporter._controls.get_node("LightingOptions/Enabled").button_pressed = false
		exporter._sheet_settings.get_node("TurntableRow/Turntable").button_pressed = false
		exporter._model_camera.set_view("front")
		exporter._model_camera.is_orthogonal = true
		exporter._model_camera.size = 9.0
		exporter._model_camera.fov = 90.0
		exporter._model_camera.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, 10))
		exporter._sheet_settings.get_node("ViewRow/Perspective").button_pressed = true
		path = "user://sprite_projection_%s.png" % Time.get_ticks_usec()
	)
	for view in [2, 0]:
		step("Given a manually enlarged sprite size", func():
			var selector: OptionButton = exporter._sheet_settings.get_node("ViewRow/View")
			selector.select(view)
			selector.item_selected.emit(view)
			exporter._sheet_settings.get_node("SizeRow/Size").value = 99
		)
		step("When the user exports an orthographic sprite from view %s" % view, func():
			exporter._sheet_settings.get_node("ViewRow/Perspective").button_pressed = false
		)
		var ortho_size := 17 if view == 2 else 9
		expect(exporter._sheet_settings.get_node("SizeRow/Size").value == ortho_size, "switching to orthographic resets the manual frame size")
		var error: Error = await exporter.export_sprite_sheet(path, 0, 0, -1, view, false)
		var orthographic := Image.new()
		orthographic.load(path)
		expect(error == OK, "the orthographic sprite exports")
		step("When the user switches the sprite to perspective", func():
			exporter._sheet_settings.get_node("ViewRow/Perspective").button_pressed = true
		)
		var perspective_size := 74 if view == 2 else 20
		expect(exporter._sheet_settings.get_node("SizeRow/Size").value == perspective_size, "switching to perspective resets the frame size for the field of view")
		error = await exporter.export_sprite_sheet(path, 0, 0, -1, view, false)
		var perspective := Image.new()
		perspective.load(path)
		step("Then both projections retain the center voxel scale", func():
			expect(error == OK, "the perspective sprite exports")
			expect(orthographic.get_size() == Vector2i.ONE * ortho_size and perspective.get_size() == Vector2i.ONE * perspective_size, "each projection exports the recalculated tile dimensions")
			var ortho_rect := orthographic.get_used_rect()
			var perspective_rect := perspective.get_used_rect()
			expect(ortho_rect.size.x > 0 and ortho_rect.size.y > 0 and perspective_rect.size.x > 0 and perspective_rect.size.y > 0, "both projections contain the center voxel")
			expect(absi(ortho_rect.size.x - perspective_rect.size.x) <= 1, "the center voxel widths match within one output pixel")
			expect(absi(ortho_rect.size.y - perspective_rect.size.y) <= 1, "the center voxel heights match within one output pixel")
		)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
