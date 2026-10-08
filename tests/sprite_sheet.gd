extends "res://tests/test.gd"

var exporter: Node
var controls: Node
var settings: Node
var sheet_path := ""
var tag_path := ""
var cancel_path := ""
var turntable_path := ""
var voxel_size_path := ""
var camera_size_path := ""
var original_document: VoxelDocument
var renderer_count := 0
var cancelled_result: Error = OK
var cancelled_done := false


func _ready() -> void:
	timeout = 30.0
	test("sprite sheet export preserves transparent frames, shared framing, ranges, and cancellation", _run)


func _run() -> void:
	step("Given a red frame, a blue frame, and an empty frame", func():
		exporter = plugin("ExportPlugin")
		controls = exporter._controls
		settings = exporter._sheet_settings
		State.document = VoxelDocument.new()
		settings.get_node("TurntableRow/Turntable").button_pressed = false
		State.get_current_voxel_frame().set_cell(Vector3i(-1, 0, 0), Color.RED)
		State.document.add_frame()
		State.get_voxel_frame(1).set_cell(Vector3i(1, 0, 0), Color.BLUE)
		State.get_voxel_frame(1).delay_ms = 250
		State.document.add_frame()
		State.frames_changed.emit()
		State.active_tag = State.document.add_tag("Blue", 1, 1, AnimationTag.LoopMode.REVERSE, 2)
		original_document = State.document
		var prefix := "user://voxel_sprite_sheet_%s" % Time.get_ticks_usec()
		sheet_path = prefix + ".png"
		tag_path = prefix + "_tag.png"
		cancel_path = prefix + "_cancel.png"
		turntable_path = prefix + "_turntable.png"
		voxel_size_path = prefix + "_voxel_size.png"
		camera_size_path = prefix + "_camera_size.png"
		renderer_count = VoxelRenderer._active_renderer_count
	)
	step("Then the controls use simple defaults and describe the output size", func():
		expect(settings.get_node("SizeRow/Size").value == 3, "the default sprite size fits the projected voxel bounds")
		var frames: OptionButton = settings.get_node("FrameRow/Frames")
		frames.select(2)
		frames.item_selected.emit(2)
		expect(exporter._selected_frames() == Vector2i(1, 1), "the selected Blue tag contains only its frame")
		frames.select(0)
		frames.item_selected.emit(0)
		expect(exporter._selected_frames() == Vector2i(0, 2), "the all-frames range includes the empty frame")
	)
	step("When the user disables Ortho for a preset view", func():
		settings.get_node("ViewRow/Ortho").button_pressed = false
	)
	step("Then the preset uses perspective projection and perspective framing", func():
		var camera_settings: Dictionary = exporter._sheet_camera(1)
		expect(camera_settings.projection == Camera3D.PROJECTION_PERSPECTIVE, "the preset uses perspective projection")
		var sample := VoxelFrame.new()
		sample.set_cell(Vector3i.ZERO, Color.RED)
		var frames: Array[VoxelFrame] = [sample]
		var bounds := sample.get_bounds()
		camera_settings.angles = Vector2.ZERO
		camera_settings.fov = 90.0
		var layout: Dictionary = exporter._projected_sprite_layout(frames, bounds, 128, camera_settings, 1)
		camera_settings.projection = Camera3D.PROJECTION_ORTHOGONAL
		var ortho_layout: Dictionary = exporter._projected_sprite_layout(frames, bounds, 128, camera_settings, 1)
		expect(layout.rect != ortho_layout.rect, "perspective and orthographic views use distinct projected bounds")
		settings.get_node("ViewRow/Ortho").button_pressed = true
	)
	step("Then Ortho overrides the 3D preview projection without changing its camera", func():
		var original_projection: int = exporter._model_camera.projection
		var ortho_settings: Dictionary = exporter._sheet_camera(0)
		expect(ortho_settings.projection == Camera3D.PROJECTION_ORTHOGONAL, "the 3D preview sprite uses orthographic projection")
		settings.get_node("ViewRow/Ortho").button_pressed = false
		var perspective_settings: Dictionary = exporter._sheet_camera(0)
		expect(perspective_settings.projection == Camera3D.PROJECTION_PERSPECTIVE, "the 3D preview sprite uses perspective projection")
		expect(ortho_settings.transform == perspective_settings.transform, "both projections retain the same camera pose")
		expect(exporter._model_camera.projection == original_projection, "the model camera retains its projection")
		settings.get_node("ViewRow/Ortho").button_pressed = true
	)
	if DisplayServer.get_name() == "headless":
		return
	step("When the user opens sprite sheet settings", func():
		exporter._menu_item.get_node("ExportBtn").button_pressed = true
	)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	step("Then the export controls are visible before choosing a file", func():
		expect(exporter._workspace.visible, "the export button opens the sprite sheet workspace")
		expect(controls.get_node("Export").text == "PNG", "the settings provide the PNG export action")
		expect(main.get_node("%StatusBar").get_node("StatusLeft").text.contains("7 × 7"), "the bottom status bar describes the sheet dimensions")
		exporter.show_editor_tab()
	)
	step("When the user chooses a nine-unit orthographic camera view", func():
		exporter._model_camera.set_view("front")
		exporter._model_camera.is_orthogonal = true
		exporter._model_camera.size = 9.0
		settings.get_node("ViewRow/View").select(0)
		settings.get_node("ViewRow/View").item_selected.emit(0)
	)
	step("Then the default sprite size includes the camera framing", func():
		expect(settings.get_node("SizeRow/Size").value == 9, "the camera's nine-unit span sets a nine-pixel sprite")
	)
	var camera_error: Error = await exporter.export_sprite_sheet(camera_size_path, 0, 2, -1, 0, false)
	step("Then the camera-framed PNG retains one pixel per voxel", func():
		var image := Image.new()
		image.load(camera_size_path)
		expect(camera_error == OK and image.get_size() == Vector2i(7, 3), "the layout separates the projected cells with one pixel")
		expect(_visible_pixels(image, Rect2i(0, 0, 3, 1)) == 1, "camera framing preserves one visible pixel for one voxel")
	)
	step("When the user chooses a perspective camera ten units from the bounds center", func():
		settings.get_node("ViewRow/Ortho").button_pressed = false
		exporter._model_camera.is_orthogonal = false
		exporter._model_camera.fov = 90.0
		exporter._model_camera.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, 10))
		exporter._model_camera.view_changed.emit()
	)
	step("Then the default sprite size includes the field of view and camera distance", func():
		expect(settings.get_node("SizeRow/Size").value == 20, "the ninety-degree view spans twenty units at the bounds center")
		settings.get_node("ViewRow/View").select(1)
		settings.get_node("ViewRow/View").item_selected.emit(1)
		settings.get_node("ViewRow/Ortho").button_pressed = true
	)
	var error: Error = await exporter.export_sprite_sheet(sheet_path, 0, 2, 32, 2)
	step("Then the PNG contains all frames in row order with transparent unused space", func():
		expect(error == OK, "the sprite sheet export completes")
		var image := Image.new()
		expect(image.load(sheet_path) == OK, "the sprite sheet is a readable PNG")
		expect(image.get_size() == Vector2i(65, 65), "the sheet contains four tiles with one-pixel gaps")
		expect(_visible_pixels(image, Rect2i(0, 0, 32, 32)) > 0, "the first tile contains the red frame")
		expect(_visible_pixels(image, Rect2i(33, 0, 32, 32)) > 0, "the second tile contains the blue frame")
		expect(_visible_pixels(image, Rect2i(0, 33, 65, 32)) == 0, "the empty frame and unused tile remain transparent")
		expect(_visible_pixels(image, Rect2i(32, 0, 1, 65)) == 0 and _visible_pixels(image, Rect2i(0, 32, 65, 1)) == 0, "the row and column gaps stay transparent")
		var red := _color_pixel(image, Rect2i(0, 0, 32, 32))
		var blue := _color_pixel(image, Rect2i(33, 0, 32, 32))
		expect(red.r > red.b and blue.b > blue.r, "the frame tiles retain their distinct voxel colors")
		expect(_center_x(image, Rect2i(0, 0, 32, 32)) < _center_x(image, Rect2i(33, 0, 32, 32)), "shared framing preserves the left and right frame positions")
		expect(State.document == original_document and State.current_frame == 0, "export preserves the active document and frame")
		expect(VoxelRenderer._active_renderer_count == renderer_count, "export releases its temporary renderer")
		expect(not State.edit_busy(), "export releases editing")
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(sheet_path.get_basename() + ".json"))
		expect(data.frames.size() == 3, "the JSON includes the empty frame without the unused tile")
		expect(data.frames[1].duration == 250, "the JSON preserves the blue frame delay")
		expect(data.frames[1].frame.x == 33 and data.frames[2].frame.y == 33, "the JSON rectangles include the sprite gaps")
		expect(data.meta.image == sheet_path.get_file() and data.meta.size.w == 65, "the JSON identifies the PNG and its dimensions")
		expect(not data.frames[0].trimmed and not data.frames[0].rotated, "the JSON describes untrimmed and unrotated frames")
		expect(data.frames[0].filename == "%s_0" % sheet_path.get_file().get_basename(), "the JSON joins the sheet label and frame index with an underscore")
	)
	error = await exporter.export_sprite_sheet(tag_path, 1, 1, 32, 6, true, 1, false, "Blue")
	step("Then a single-frame range exports from another view", func():
		expect(error == OK, "the top-view frame export completes")
		var image := Image.new()
		image.load(tag_path)
		expect(image.get_size() == Vector2i(32, 32), "the frame range exports one tile")
		expect(_visible_pixels(image, Rect2i(0, 0, 32, 32)) > 0, "the top-view tile contains the selected frame")
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(tag_path.get_basename() + ".json"))
		var blue_tag: Dictionary
		for tag in data.meta.frameTags:
			if tag.name == "Blue":
				blue_tag = tag
		expect(blue_tag.from == 0 and blue_tag.to == 0, "tag indices are relative to the exported frame range")
		expect(blue_tag.direction == "reverse" and blue_tag.repeat == "2", "the JSON uses Aseprite tag directions and string repeat counts")
		expect(data.frames[0].filename == "Blue_1", "a tagged export names the frame after the exported tag and frame index")
	)
	step("When the user cancels another export", func():
		exporter._menu_item.get_node("ExportBtn").button_pressed = true
		_start_cancelled_export()
		expect(State.edit_busy(), "sprite sheet rendering reports foreground work")
		main.get_node("%StatusBar").get_node("Activity/Cancel").pressed.emit()
	)
	while not cancelled_done:
		await get_tree().process_frame
	step("Then cancellation publishes no partial file and releases resources", func():
		expect(cancelled_result == ERR_BUSY, "the cancelled export reports cancellation")
		expect(not FileAccess.file_exists(cancel_path), "the cancelled export writes no partial PNG")
		expect(not FileAccess.file_exists(cancel_path.get_basename() + ".json"), "the cancelled export writes no JSON sidecar")
		expect(not State.edit_busy(), "cancellation releases editing")
		expect(VoxelRenderer._active_renderer_count == renderer_count, "cancellation releases its temporary renderer")
		exporter.show_editor_tab()
	)
	error = await exporter.export_sprite_sheet(voxel_size_path, 0, 2, -1, 2, false)
	step("Then the default front view uses one pixel per voxel", func():
		var image := Image.new()
		image.load(voxel_size_path)
		expect(error == OK and image.get_size() == Vector2i(7, 3), "the front-view layout separates the shared projected bounds")
		expect(_visible_pixels(image, Rect2i(0, 0, 3, 1)) == 1, "one voxel occupies one visible pixel in the default front view")
	)
	error = await exporter.export_sprite_sheet(turntable_path, 0, 0, 16, 2, true, 8)
	step("Then a turntable exports eight distinct view positions", func():
		var image := Image.new()
		image.load(turntable_path)
		expect(error == OK and image.get_size() == Vector2i(50, 50), "the turntable arranges its eight sprites with one-pixel gaps")
		var all_views_visible := true
		for index in 8:
			all_views_visible = all_views_visible and _visible_pixels(image, Rect2i(Vector2i(index % 3, index / 3) * 17, Vector2i.ONE * 16)) > 0
		expect(all_views_visible, "each turntable view contains the model")
		expect(image.get_region(Rect2i(0, 0, 16, 16)).get_data() != image.get_region(Rect2i(17, 0, 16, 16)).get_data(), "the first two turntable sprites use different camera angles")
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(turntable_path.get_basename() + ".json"))
		expect(data.frames.size() == 8 and data.frames[4].frame.y == 17, "turntable metadata identifies all view tiles and gaps")
		expect(data.frames[0].filename != data.frames[1].filename, "each turntable view has a distinct frame name")
	)
	var import_error: Error = await plugin("ImageImportPlugin").import_image(sheet_path)
	step("Then the PNG and JSON import as the same animation", func():
		expect(import_error == OK, "the exported sheet imports with its sidecar")
		expect(State.get_frame_count() == 3, "import restores the empty frame and both colored frames")
		expect(State.get_voxel_frame(1).delay_ms == 250, "import restores the exported frame delay")
		var blue_tag: AnimationTag
		for tag in State.document.tags:
			if tag.name == "Blue":
				blue_tag = tag
		expect(blue_tag != null and blue_tag.from == 1 and blue_tag.to == 1, "import restores the exported tag range")
		expect(blue_tag != null and blue_tag.repeats == 2 and blue_tag.loop_mode == AnimationTag.LoopMode.REVERSE, "import restores the exported tag direction and repeats")
	)
	for path in [sheet_path, tag_path, turntable_path, voxel_size_path, camera_size_path, sheet_path.get_basename() + ".json", tag_path.get_basename() + ".json", turntable_path.get_basename() + ".json"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _start_cancelled_export() -> void:
	cancelled_result = await exporter.export_sprite_sheet(cancel_path, 0, 2, 64, 1)
	cancelled_done = true


func _visible_pixels(image: Image, rect: Rect2i) -> int:
	var count := 0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if image.get_pixel(x, y).a > 0.1:
				count += 1
	return count


func _color_pixel(image: Image, rect: Rect2i) -> Color:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var color := image.get_pixel(x, y)
			if color.a > 0.9:
				return color
	return Color.TRANSPARENT


func _center_x(image: Image, rect: Rect2i) -> float:
	var total := 0.0
	var count := 0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if image.get_pixel(x, y).a > 0.9:
				total += x - rect.position.x
				count += 1
	return total / maxf(1, count)
