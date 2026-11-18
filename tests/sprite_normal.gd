extends "res://tests/test.gd"

# Sprite normal export: the encoded bytes, view orientation, the export option,
# and the preview light. The preview light needs a visible window.

var exporter: Node
var prefix := ""


func _ready() -> void:
	timeout = 30.0
	test("a sprite sheet writes an aligned normal sheet", _bytes_run, "sprite_normal")
	test("normal sheets follow the view and turntable", _orientation_run, "sprite_normal_orientation")
	test("the light toggle stores and restores the normal option", _option_run, "sprite_normal_option")
	test("the preview light shades only over the pointer", _light_run, "sprite_normal_light")


func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	State.clear_selection()
	exporter = plugin("ExportPlugin")
	exporter._restore_export_settings()
	exporter._light_button.set_pressed_no_signal(false)
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


func _option_run() -> void:
	step("Given a new document", func():
		expect(not exporter._light_button.button_pressed, "normal maps start off")
		expect(not bool(exporter.current_export_settings().sprite.get("normal", false)), "the export settings start with normal off")
	)
	step("When the light toggle turns normal maps on", func():
		exporter._light_button.button_pressed = true
	)
	step("Then the export settings store normal maps", func():
		expect(bool(State.document.export_settings.get("normal", false)), "the document stores the normal choice")
		expect(bool(exporter.current_export_settings().sprite.get("normal", false)), "the current settings report normal maps")
	)
	step("When a document stores normal maps and the settings restore", func():
		exporter._light_button.set_pressed_no_signal(false)
		State.document.export_settings["normal"] = true
		exporter._restore_export_settings()
	)
	step("Then the toggle follows the document", func():
		expect(exporter._light_button.button_pressed, "the restored document turns normal maps on")
	)
	step("When normal maps turn off", func():
		exporter._light_button.button_pressed = false
	)
	step("Then the document follows the toggle", func():
		expect(not bool(State.document.export_settings.get("normal", true)), "the document turns normal maps off")
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
	step("When GIF mode turns on", func():
		exporter._gif_button.button_pressed = true
	)
	await get_tree().process_frame
	step("Then normal maps are disabled for the color animation", func():
		expect(exporter._light_button.disabled, "GIF mode disables the normal toggle")
		expect(not preview._light.enabled, "GIF mode turns the light off")
		expect(preview.is_animating(), "GIF mode animates the color frames")
	)
	step("When GIF mode turns off", func():
		exporter._gif_button.button_pressed = false
	)
	await get_tree().process_frame
	step("Then the normal choice survives", func():
		expect(not exporter._light_button.disabled, "the normal toggle returns")
		expect(exporter._light_button.button_pressed, "the normal choice survives GIF mode")
		expect(not preview.is_animating(), "the preview returns to the sheet")
	)


func _wait_preview() -> void:
	while exporter._preview_running or exporter._preview_due_ms >= 0 or exporter._preview_image == null:
		await get_tree().process_frame
