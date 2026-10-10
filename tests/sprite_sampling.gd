extends "res://tests/test.gd"

var exporter: Node
var path := ""


func _ready() -> void:
	timeout = 15.0
	test("sprite downscaling preserves hard transparent edges in both projections", _run)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		return
	step("Given a voxel with fractional pixel alignment and an empty animation frame", func():
		exporter = plugin("ExportPlugin")
		State.document = VoxelDocument.new()
		State.document.set_cell(0, Vector3i.ZERO, Color.RED)
		State.document.add_frame()
		State.frames_changed.emit()
		exporter._refresh_model()
		exporter._controls.get_node("LightingOptions/Enabled").button_pressed = false
		path = "user://sprite_sampling_%s.png" % Time.get_ticks_usec()
	)
	for orthographic in [true, false]:
		step("When the user exports six-pixel square frames with orthographic=%s" % orthographic, func():
			exporter._sheet_settings.get_node("ViewRow/Perspective").button_pressed = not orthographic
			exporter._model_camera.is_orthogonal = orthographic
			exporter._model_camera.size = 4.0
			exporter._model_camera.fov = 90.0
			exporter._model_camera.transform = Transform3D(Basis.IDENTITY, Vector3(-0.4, -0.4, 2.0))
		)
		var error: Error = await exporter.export_sprite_sheet(path, 0, 1, 6, 0)
		step("Then the PNG retains hard voxel edges at the selected size", func():
			expect(error == OK, "the small sprite sheet exports")
			var image := Image.new()
			expect(image.load(path) == OK, "the small sprite sheet loads")
			expect(image.get_size() == Vector2i(13, 6), "the sheet retains six-pixel tiles and a one-pixel gap")
			var pixel := image.get_pixel(3, 2)
			expect(pixel.a == 1.0, "the sampled voxel remains opaque")
			expect(pixel.r > pixel.g and pixel.r > pixel.b, "the sampled voxel retains its red color")
			var hard_edges := true
			var empty := true
			for y in image.get_height():
				for x in image.get_width():
					var alpha := image.get_pixel(x, y).a
					hard_edges = hard_edges and (alpha == 0.0 or alpha == 1.0)
					if x >= 6:
						empty = empty and alpha == 0.0
			expect(hard_edges, "downscaling retains opaque or transparent pixel edges")
			expect(empty, "the gap and empty animation frame remain transparent")
			var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path.get_basename() + ".json"))
			expect(data.meta.size.w == 13 and data.meta.size.h == 6, "the JSON describes the final sheet dimensions")
			expect(data.frames[0].frame.w == 6 and data.frames[1].frame.x == 7, "the JSON describes the selected tile size and gap")
			expect(State.get_voxel_frame(0).has(Vector3i.ZERO), "sampling preserves the document voxel")
		)
	for file in [path, path.get_basename() + ".json"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
