extends "res://tests/test.gd"

# Sprite normal export: the encoded bytes, view orientation, the export option,
# and the preview light. The preview light needs a visible window.

var exporter: Node
var prefix := ""


func _ready() -> void:
	timeout = 30.0
	test("a sprite sheet writes an aligned normal sheet", _bytes_run, "sprite_normal")
	test("normal sheets follow the view and turntable", _orientation_run, "sprite_normal_orientation")
	test("a sprite sheet writes an aligned specular sheet", _specular_run, "sprite_specular")
	test("the light toggle stores and restores the normal option", _option_run, "sprite_normal_option")
	test("the preview light shades only over the pointer", _light_run, "sprite_normal_light")
	test("the preview lights specular maps", _specular_light_run, "sprite_specular_light")


func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	State.clear_selection()
	exporter = plugin("ExportPlugin")
	exporter._restore_export_settings()
	exporter._light_button.set_pressed_no_signal(false)
	exporter._maps_button.set_pressed_no_signal(false)
	exporter._specular_intensity.set_value_no_signal(1.0)
	prefix = "user://sprite_normal_%s" % Time.get_ticks_usec()


func after_test() -> void:
	if is_instance_valid(exporter):
		exporter.show_editor_tab()


func _bytes_run() -> void:
	step("Given one voxel, an empty frame, and a front orthographic view", func():
		State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.WHITE))
		State.document.add_frame()
		State.frames_changed.emit()
		exporter._model_camera.is_orthogonal = true
	)
	var path := prefix + "_bytes.png"
	var error: Error = await exporter.export_sprite_sheet_settings(path, {
		"first_frame": 0,
		"last_frame": 1,
		"tile_size": 16,
		"view": "front",
		"views": 1,
		"orthographic": true,
		"center": true,
		"metadata": true,
		"normal": true,
	})
	step("Then the normal sheet holds the view-space normal", func():
		expect(error == OK, "the normal sheet exports")
		var color := Image.new()
		var normal := Image.new()
		expect(color.load(path) == OK and normal.load(exporter.normal_path(path)) == OK, "both sheets load")
		expect(normal.get_size() == Vector2i(33, 16), "the normal sheet matches the color layout")
		var pixel := normal.get_pixel(8, 8)
		expect(abs(pixel.r8 - 128) <= 2 and abs(pixel.g8 - 128) <= 2, "the front face encodes a flat normal")
		expect(pixel.b8 >= 250, "the front face points to the viewer")
		expect(normal.get_pixel(20, 8).a8 == 0, "the empty frame is transparent")
		expect(pixel.a8 == 255, "the drawn face is opaque")
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path.get_basename() + ".json"))
		expect(data.meta.lve.normal.image == path.get_file().get_basename() + "_normal.png", "the sidecar names the normal sheet")
		expect(data.meta.lve.normal.space == "view", "the sidecar names the normal space")
		expect(data.meta.lve.normal.convention == "+x, +y, +z", "the sidecar names the normal convention")
	)
	var invalid_error: Error = await exporter.export_sprite_sheet_settings(path, {"normal": "yes"})
	step("Then a non-boolean normal option is refused", func():
		expect(invalid_error == ERR_INVALID_PARAMETER, "the export rejects a non-boolean normal option")
	)
	for file in [path, exporter.normal_path(path), path.get_basename() + ".json"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file))


func _orientation_run() -> void:
	step("Given one voxel and an isometric view", func():
		State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.WHITE))
		State.frames_changed.emit()
		exporter._model_camera.is_orthogonal = true
	)
	var path := prefix + "_iso.png"
	var error: Error = await exporter.export_sprite_sheet_settings(path, {
		"first_frame": 0,
		"last_frame": 0,
		"tile_size": 32,
		"view": "isometric",
		"views": 1,
		"orthographic": true,
		"center": true,
		"normal": true,
	})
	step("Then the top face tilts the encoded normal upward", func():
		expect(error == OK, "the isometric normal sheet exports")
		var normal := Image.new()
		expect(normal.load(exporter.normal_path(path)) == OK, "the isometric normal sheet loads")
		var max_green := 0
		for y in normal.get_height():
			for x in normal.get_width():
				var pixel := normal.get_pixel(x, y)
				if pixel.a8 > 0:
					max_green = maxi(max_green, pixel.g8)
		expect(max_green > 180, "the top face leans toward the upper half")
	)
	var turntable_path := prefix + "_turntable.png"
	step("Given two separated voxels for a turntable", func():
		State.document.set_cell(0, Vector3i(2, 0, 0), VoxelFrame.material(Color.WHITE))
		State.frames_changed.emit()
	)
	error = await exporter.export_sprite_sheet_settings(turntable_path, {
		"first_frame": 0,
		"last_frame": 0,
		"tile_size": 32,
		"view": "isometric",
		"views": 3,
		"orthographic": true,
		"center": true,
		"normal": true,
	})
	step("Then each turntable view rotates the normal sheet", func():
		expect(error == OK, "the turntable normal sheet exports")
		var normal := Image.new()
		expect(normal.load(exporter.normal_path(turntable_path)) == OK, "the turntable normal sheet loads")
		var first := normal.get_region(Rect2i(0, 0, 32, 32))
		var second := normal.get_region(Rect2i(33, 0, 32, 32))
		expect(first.get_data() != second.get_data(), "the first two views encode different normals")
	)
	for file in [path, exporter.normal_path(path), turntable_path, exporter.normal_path(turntable_path)]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file))


func _specular_run() -> void:
	step("Given a metallic voxel, an empty frame, and a front orthographic view", func():
		State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color(0.2, 0.2, 0.2), Color.BLACK, 1.0, 0.2))
		State.document.add_frame()
		State.frames_changed.emit()
		exporter._model_camera.is_orthogonal = true
	)
	var path := prefix + "_specular.png"
	var error: Error = await exporter.export_sprite_sheet_settings(path, {
		"first_frame": 0,
		"last_frame": 1,
		"tile_size": 16,
		"view": "front",
		"views": 1,
		"orthographic": true,
		"center": true,
		"metadata": true,
		"specular": true,
	})
	step("Then the specular sheet holds metallic and shininess", func():
		expect(error == OK, "the specular sheet exports")
		var color := Image.new()
		var specular := Image.new()
		expect(color.load(path) == OK and specular.load(exporter.specular_path(path)) == OK, "the color and specular sheets load")
		expect(specular.get_size() == Vector2i(33, 16), "the specular sheet matches the color layout")
		var pixel := specular.get_pixel(8, 8)
		expect(pixel.r8 >= 250 and pixel.g8 >= 250 and pixel.b8 >= 250, "the metallic mask is white")
		expect(abs(pixel.a8 - 204) <= 2, "the alpha holds one minus roughness")
		expect(specular.get_pixel(20, 8).a8 == 0, "the empty frame is transparent")
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path.get_basename() + ".json"))
		expect(data.meta.lve.specular.image == path.get_file().get_basename() + "_specular.png", "the sidecar names the specular sheet")
		expect(data.meta.lve.specular.color == "metallic", "the sidecar names the metallic channel")
		expect(data.meta.lve.specular.alpha == "shininess", "the sidecar names the alpha channel")
	)
	var invalid_error: Error = await exporter.export_sprite_sheet_settings(path, {"specular": "yes"})
	step("Then a non-boolean specular option is refused", func():
		expect(invalid_error == ERR_INVALID_PARAMETER, "the export rejects a non-boolean specular option")
	)
	var half_path := prefix + "_specular_half.png"
	var half_error: Error = await exporter.export_sprite_sheet_settings(half_path, {
		"first_frame": 0,
		"last_frame": 1,
		"tile_size": 16,
		"view": "front",
		"views": 1,
		"orthographic": true,
		"center": true,
		"metadata": true,
		"specular": true,
		"specular_intensity": 0.5,
	})
	step("Then the specular intensity scales the metallic mask", func():
		var half := Image.new()
		expect(half_error == OK and half.load(exporter.specular_path(half_path)) == OK, "the half-intensity sheet loads")
		var pixel := half.get_pixel(8, 8)
		expect(abs(pixel.r8 - 128) <= 2 and abs(pixel.g8 - 128) <= 2 and abs(pixel.b8 - 128) <= 2, "the metallic mask is halved")
		expect(abs(pixel.a8 - 204) <= 2, "the shininess stays unchanged")
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(half_path.get_basename() + ".json"))
		expect(is_equal_approx(float(data.meta.lve.specular.intensity), 0.5), "the sidecar records the intensity")
	)
	var off_path := prefix + "_specular_off.png"
	var off_error: Error = await exporter.export_sprite_sheet_settings(off_path, {
		"first_frame": 0,
		"last_frame": 1,
		"tile_size": 16,
		"view": "front",
		"views": 1,
		"orthographic": true,
		"center": true,
		"specular": false,
	})
	step("Then the specular-enabled color sheet drops baked specular", func():
		var on_color := Image.new()
		var off_color := Image.new()
		expect(off_error == OK and on_color.load(path) == OK and off_color.load(off_path) == OK, "both color sheets load")
		expect(on_color.get_data() != off_color.get_data(), "enabling specular changes the color pass")
	)
	for file in [path, exporter.specular_path(path), path.get_basename() + ".json", off_path, half_path, exporter.specular_path(half_path), half_path.get_basename() + ".json"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file))


func _option_run() -> void:
	step("Given a new document", func():
		expect(not exporter._light_button.button_pressed, "maps start off")
		var sprite: Dictionary = exporter.current_export_settings().sprite
		expect(not bool(sprite.get("normal", false)), "the export settings start with normal off")
		expect(not bool(sprite.get("specular", false)), "the export settings start with specular off")
	)
	step("When the light toggle turns maps on", func():
		exporter._light_button.button_pressed = true
	)
	step("Then the export settings store both maps", func():
		expect(bool(State.document.export_settings.get("normal", false)), "the document stores the normal choice")
		expect(bool(State.document.export_settings.get("specular", false)), "the document stores the specular choice")
		var sprite: Dictionary = exporter.current_export_settings().sprite
		expect(bool(sprite.get("normal", false)), "the current settings report normal maps")
		expect(bool(sprite.get("specular", false)), "the current settings report specular maps")
	)
	step("When the specular intensity changes", func():
		exporter._specular_intensity.value = 0.5
	)
	step("Then the document stores the intensity", func():
		expect(is_equal_approx(float(State.document.export_settings.get("specular_intensity", 0.0)), 0.5), "the document stores the specular intensity")
		expect(is_equal_approx(float(exporter.current_export_settings().sprite.get("specular_intensity", 0.0)), 0.5), "the current settings report the specular intensity")
	)
	step("When a document stores only specular maps and the settings restore", func():
		exporter._light_button.set_pressed_no_signal(false)
		State.document.export_settings["normal"] = false
		State.document.export_settings["specular"] = true
		State.document.export_settings["specular_intensity"] = 0.25
		exporter._restore_export_settings()
	)
	step("Then the light toggle and intensity follow the document", func():
		expect(exporter._light_button.button_pressed, "the restored document turns maps on")
		expect(is_equal_approx(float(exporter._specular_intensity.value), 0.25), "the restored intensity applies")
	)
	step("When the light toggle turns maps off", func():
		exporter._light_button.button_pressed = false
	)
	step("Then the document turns both maps off", func():
		expect(not bool(State.document.export_settings.get("normal", true)), "the document turns normal maps off")
		expect(not bool(State.document.export_settings.get("specular", true)), "the document turns specular maps off")
	)


func _light_run() -> void:
	if DisplayServer.get_name() == "headless":
		return
	step("Given a visible sheet preview", func():
		State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color(0.2, 0.2, 0.2)))
		State.frames_changed.emit()
		exporter._sheet_settings.get_node("SizeRow/Size").set_value_no_signal(32)
		exporter._menu_item.get_node("ExportBtn").button_pressed = true
		exporter._light_button.button_pressed = true
	)
	await get_tree().process_frame
	await get_tree().process_frame
	await _wait_preview()
	var preview: Control = exporter._controls.get_node("Preview")
	step("Then the preview holds a normal sheet and starts unshaded", func():
		expect(exporter._preview_normal_image != null, "the preview renders the normal sheet")
		expect(preview._normal_texture != null, "the preview receives the normal texture")
		expect(preview.material == null, "the pointer outside the preview leaves it unshaded")
		expect(not preview._light.enabled, "the pointer outside the preview turns the light off")
	)
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var plain := get_tree().root.get_texture().get_image()
	step("When the pointer enters the preview", func():
		preview._pointer_inside = true
		var event := InputEventMouseMotion.new()
		event.position = Vector2(24, 24)
		preview._gui_input(event)
	)
	step("Then the preview applies the light shader at the pointer", func():
		expect(preview.material != null, "the pointer applies the light shader")
		expect(preview._light.enabled, "the light turns on over the sheet")
		expect(preview._light.position == Vector2(24, 24), "the light follows the pointer")
	)
	step("When the pointer rests on the sheet center", func():
		preview._pointer = preview.size * 0.5
		preview._update_light()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var lit := get_tree().root.get_texture().get_image()
	step("Then the pointer light brightens the sheet center", func():
		expect(lit.get_size() == get_tree().root.size, "the editor image matches the window")
		var center := preview.get_global_rect().get_center()
		var lit_luminance := lit.get_pixelv(Vector2i(center)).get_luminance()
		var plain_luminance := plain.get_pixelv(Vector2i(center)).get_luminance()
		expect(lit_luminance > plain_luminance + 0.02, "the light adds brightness at the sheet center")
	)
	step("When the pointer leaves the preview", func():
		preview._on_mouse_exited()
	)
	step("Then the preview returns to the unshaded sheet", func():
		expect(preview.material == null, "the pointer outside removes the light shader")
		expect(not preview._light.enabled, "the pointer outside turns the light off")
		expect(preview.texture != null, "the sheet texture stays")
	)
	step("When the user shows the maps", func():
		exporter._maps_button.button_pressed = true
	)
	step("Then the preview shows both map sheets", func():
		expect(not exporter._maps_button.disabled, "the maps view is available")
		expect(preview.texture == exporter._preview_maps_texture, "the preview shows both maps")
		expect(preview.texture.get_width() == exporter._preview_normal_texture.get_width() * 2 + 1, "the maps sit side by side")
		expect(preview.material == null and not preview._light.enabled, "the maps view stays unshaded")
		expect(preview.texture.get_image().get_pixel(16, 16).b8 > 200, "the maps view holds the normal sheet")
	)
	step("When the user returns to the color sheet", func():
		exporter._maps_button.button_pressed = false
	)
	step("Then the preview shows the color sheet", func():
		expect(preview.texture == exporter._preview_canvas_texture, "the preview returns to the color sheet")
	)
	step("When GIF mode turns on", func():
		exporter._gif_button.button_pressed = true
	)
	await get_tree().process_frame
	step("Then the map views are disabled for the color animation", func():
		expect(exporter._light_button.disabled, "GIF mode disables the map toggle")
		expect(exporter._maps_button.disabled, "GIF mode disables the maps view")
		expect(not exporter._maps_button.button_pressed, "GIF mode leaves the maps view")
		expect(not preview._light.enabled, "GIF mode turns the light off")
		expect(preview.is_animating(), "GIF mode animates the color frames")
	)
	step("When GIF mode turns off", func():
		exporter._gif_button.button_pressed = false
	)
	await get_tree().process_frame
	step("Then the map choice survives", func():
		expect(not exporter._light_button.disabled, "the map toggle returns")
		expect(exporter._light_button.button_pressed, "the map choice survives GIF mode")
		expect(not exporter._maps_button.disabled, "the maps view returns")
		expect(not preview.is_animating(), "the preview returns to the sheet")
	)
	step("When the light toggle turns off", func():
		exporter._light_button.button_pressed = false
	)
	step("Then the maps view disables", func():
		expect(exporter._maps_button.disabled, "maps off disables the maps view")
		expect(not exporter._maps_button.button_pressed, "maps off leaves the maps view")
	)


func _specular_light_run() -> void:
	if DisplayServer.get_name() == "headless":
		return
	step("Given a metallic voxel and a visible sheet preview", func():
		State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color(0.2, 0.2, 0.2), Color.BLACK, 1.0, 0.8))
		State.frames_changed.emit()
		exporter._model_scene.get_node("%Shaded").button_pressed = false
		exporter._sheet_settings.get_node("SizeRow/Size").set_value_no_signal(32)
		exporter._menu_item.get_node("ExportBtn").button_pressed = true
		exporter._light_button.button_pressed = true
	)
	await get_tree().process_frame
	await get_tree().process_frame
	await _wait_preview()
	var preview: Control = exporter._controls.get_node("Preview")
	step("Then the preview holds normal and specular sheets", func():
		expect(exporter._preview_normal_image != null, "the preview renders the normal sheet")
		expect(exporter._preview_specular_image != null, "the preview renders the specular sheet")
		expect(exporter._preview_canvas_texture != null, "the lit preview uses a canvas texture")
		expect(exporter._preview_canvas_texture.specular_texture == exporter._preview_specular_texture, "the canvas texture holds the specular sheet")
		expect(is_equal_approx(exporter._preview_canvas_texture.specular_shininess, 0.99), "the canvas texture enables specular")
		expect(is_equal_approx(float(exporter._specular_intensity.value), 1.0), "the intensity starts at full")
	)
	step("When the pointer rests on the sheet center", func():
		preview._pointer_inside = true
		preview._pointer = preview.size * 0.5
		preview._update_light()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var specular_lit := get_tree().root.get_texture().get_image()
	step("When the light drops the specular map", func():
		preview.set_specular_map(null)
		expect(preview._specular_texture == null, "the light drops the specular map")
	)
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var normal_lit := get_tree().root.get_texture().get_image()
	step("Then the specular map brightens the lit center", func():
		var center := preview.get_global_rect().get_center()
		var specular_luminance := specular_lit.get_pixelv(Vector2i(center)).get_luminance()
		var normal_luminance := normal_lit.get_pixelv(Vector2i(center)).get_luminance()
		expect(specular_luminance > normal_luminance + 0.02, "specular adds brightness at the sheet center")
	)
	step("When the light restores the specular map", func():
		preview.set_specular_map(exporter._preview_specular_texture)
	)
	step("When the specular intensity drops", func():
		exporter._specular_intensity.value = 0.5
	)
	await get_tree().process_frame
	await get_tree().process_frame
	await _wait_preview()
	step("Then the specular sheet scales", func():
		var pixel: Color = exporter._preview_specular_texture.get_image().get_pixel(16, 16)
		expect(abs(pixel.r8 - 128) <= 2, "the metallic mask is halved in the preview")
		expect(is_equal_approx(float(State.document.export_settings.get("specular_intensity", 0.0)), 0.5), "the document stores the intensity")
	)
	step("When the user shows the maps", func():
		exporter._maps_button.button_pressed = true
	)
	step("Then the map view shows both scaled sheets", func():
		var normal_width: int = exporter._preview_normal_texture.get_width()
		var image: Image = preview.texture.get_image()
		expect(preview.texture == exporter._preview_maps_texture, "the preview shows both maps")
		expect(preview.material == null and not preview._light.enabled, "the maps view stays unshaded")
		expect(image.get_pixel(16, 16).b8 > 200, "the maps view holds the normal sheet")
		expect(abs(image.get_pixel(normal_width + 1 + 16, 16).r8 - 128) <= 2, "the maps view holds the scaled specular sheet")
	)
	step("When the user returns to the color sheet", func():
		exporter._maps_button.button_pressed = false
	)
	step("When GIF mode turns on", func():
		exporter._gif_button.button_pressed = true
	)
	await get_tree().process_frame
	step("Then the map controls are disabled for the color animation", func():
		expect(exporter._light_button.disabled, "GIF mode disables the map toggle")
		expect(exporter._maps_button.disabled, "GIF mode disables the maps view")
		expect(not exporter._specular_intensity.editable, "GIF mode disables the specular intensity")
		expect(preview.is_animating(), "GIF mode animates the color frames")
	)
	step("When GIF mode turns off", func():
		exporter._gif_button.button_pressed = false
	)
	await get_tree().process_frame
	step("Then the map choice survives", func():
		expect(not exporter._light_button.disabled, "the map toggle returns")
		expect(exporter._light_button.button_pressed, "the map choice survives GIF mode")
		expect(not exporter._maps_button.disabled, "the maps view returns")
		expect(exporter._specular_intensity.editable, "the specular intensity returns")
		expect(not preview.is_animating(), "the preview returns to the sheet")
	)


func _wait_preview() -> void:
	while exporter._preview_running or exporter._preview_due_ms >= 0 or exporter._preview_image == null:
		await get_tree().process_frame
