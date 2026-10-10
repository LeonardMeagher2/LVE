extends "res://tests/test.gd"

var exporter: Node
var settings: Node
var lighting: Node
var prefix := ""
var baseline: Image
var shadowed: Image
var orthographic_image: Image


func _ready() -> void:
	timeout = 20.0
	test("sprite sheets preserve shadows in orthographic and perspective views", _run)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		return
	step("Given a column and a floor in two animation frames", func():
		exporter = plugin("ExportPlugin")
		settings = exporter._sheet_settings
		lighting = exporter._controls.get_node("LightingOptions")
		State.document = VoxelDocument.new()
		for x in range(-3, 4):
			for z in range(-3, 4):
				State.document.set_cell(0, Vector3i(x, 0, z), Color.from_rgba8(120, 120, 120))
		State.document.frames.append(State.get_current_voxel_frame().copy_frame())
		for y in range(1, 7):
			State.document.set_cell(0, Vector3i(-2, y, 2), Color.RED)
			State.document.set_cell(1, Vector3i(2, y, -2), Color.BLUE)
		State.frames_changed.emit()
		exporter._model_camera.center_active()
		exporter._model_camera.set_view("isometric")
		lighting.get_node("Enabled").button_pressed = true
		lighting.get_node("LockView").button_pressed = false
		prefix = "user://voxel_shadow_%s" % Time.get_ticks_usec()
	)
	for camera_case in [{"view": 1, "ortho": true}, {"view": 1, "ortho": false}, {"view": 0, "ortho": true}, {"view": 0, "ortho": false}]:
		var orthographic: bool = camera_case.ortho
		var view: int = camera_case.view
		step("When the user exports with shadows disabled", func():
			settings.get_node("ViewRow/Perspective").button_pressed = not orthographic
			lighting.get_node("Shadows").button_pressed = false
		)
		var error: Error = await exporter.export_sprite_sheet(prefix + "_off.png", 0, 1, 128, view, false, 2)
		expect(error == OK, "the export without shadows completes")
		baseline = Image.new()
		expect(baseline.load(prefix + "_off.png") == OK, "the reference PNG is readable")
		if orthographic:
			orthographic_image = baseline
		else:
			expect(baseline.get_data() != orthographic_image.get_data(), "the projection toggle changes the rendered projection")
		step("When the user exports with shadows enabled", func():
			lighting.get_node("Shadows").button_pressed = true
		)
		error = await exporter.export_sprite_sheet(prefix + "_on.png", 0, 1, 128, view, false, 2)
		expect(error == OK, "the export with shadows completes")
		shadowed = Image.new()
		expect(shadowed.load(prefix + "_on.png") == OK, "the shadow PNG is readable")
		step("Then each frame and turntable view includes shadows without clipping", func():
			expect(baseline.get_size() == shadowed.get_size(), "both exports use the same sheet dimensions")
			for index in 4:
				var rect := Rect2i(Vector2i(index % 2, index / 2) * 129, Vector2i.ONE * 128)
				var darkened := 0
				var same_alpha := true
				for y in range(rect.position.y, rect.end.y):
					for x in range(rect.position.x, rect.end.x):
						var reference := baseline.get_pixel(x, y)
						var actual := shadowed.get_pixel(x, y)
						same_alpha = same_alpha and is_equal_approx(reference.a, actual.a)
						if reference.a > 0.9 and actual.a > 0.9 and actual.get_luminance() < reference.get_luminance() - 0.03:
							darkened += 1
				expect(darkened > 10, "tile %d contains shadow pixels in %s projection" % [index, "orthographic" if orthographic else "perspective"])
				expect(same_alpha, "tile %d preserves the model silhouette" % index)
		)
	for suffix in ["_off.png", "_on.png"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(prefix + suffix))
