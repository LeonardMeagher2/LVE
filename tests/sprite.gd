extends "res://tests/test.gd"

# Sprite export: centering, projection sizing, downscale sampling, sheet
# contents and cancellation, and shadows. The five cases share the export
# plugin, so one process covers them.

var exporter: Node
var settings: Node
var captured := false
var render_pose: Dictionary
var bounds: AABB
var center_prefix := ""
var change_center_on_start := false
var planes_stable := true
var projection_path := ""
var sampling_path := ""
var controls: Node
var sheet_path := ""
var tag_path := ""
var cancel_path := ""
var escape_path := ""
var turntable_path := ""
var voxel_size_path := ""
var camera_size_path := ""
var original_document: VoxelDocument
var renderer_count := 0
var cancelled_result: Error = OK
var cancelled_done := false
var escaped_result: Error = OK
var escaped_done := false
var shadow_lighting: Node
var shadow_prefix := ""
var baseline: Image
var shadowed: Image
var orthographic_image: Image


func _ready() -> void:
	timeout = 30.0
	test("sprite centering preserves framing and document coordinates", _center_run, "sprite_center")
	timeout = 20.0
	test("changing sprite projection preserves the voxel pixel scale", _projection_run, "sprite_projection")
	timeout = 15.0
	test("sprite downscaling preserves hard transparent edges in both projections", _sampling_run, "sprite_sampling")
	timeout = 30.0
	test("sprite sheet export preserves transparent frames, shared framing, ranges, and cancellation", _sheet_run, "sprite_sheet")
	timeout = 20.0
	test("sprite sheets preserve shadows in orthographic and perspective views", _shadows_run, "sprite_sheet_shadows")


# Each case starts from a clean document. The cases share one process, so no
# case may inherit another case's document, export settings, or signals.
func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	State.clear_selection()
	State.symmetry_axes = 0
	exporter = plugin("ExportPlugin")
	settings = exporter._sheet_settings
	cancelled_done = false
	escaped_done = false


func after_test() -> void:
	# A case that fails before its own disconnects must not leave a handler
	# bound to the shared process frame or activity signal.
	if get_tree().process_frame.is_connected(_capture_pose):
		get_tree().process_frame.disconnect(_capture_pose)
	if State.activity_changed.is_connected(_change_center_after_start):
		State.activity_changed.disconnect(_change_center_after_start)
	if is_instance_valid(exporter):
		exporter._restore_export_settings()
		exporter.show_editor_tab()


func _capture_pose() -> void:
	if not is_instance_valid(exporter._export_viewport):
		return
	var viewport: SubViewport = exporter._export_viewport
	var renderer: VoxelRenderer = viewport.get_node("%VoxelRenderer")
	var camera: Camera3D = viewport.get_node("Node3D/Camera3D")
	if captured:
		planes_stable = planes_stable and is_equal_approx(camera.near, render_pose.near) and is_equal_approx(camera.far, render_pose.far)
		return
	render_pose = {"model": renderer.transform, "camera": camera.transform, "projection": camera.projection, "near": camera.near, "far": camera.far}
	captured = true


func _change_center_after_start() -> void:
	if change_center_on_start and State.edit_busy():
		change_center_on_start = false
		settings.get_node("ViewRow/Center").button_pressed = false


func _center_run() -> void:
	step("Given two animation frames away from the document origin", func():
		State.document.set_cell(0, Vector3i(30, 20, -10), VoxelFrame.material(Color.RED))
		State.document.add_frame()
		State.document.set_cell(1, Vector3i(32, 20, -10), VoxelFrame.material(Color.BLUE))
		State.frames_changed.emit()
		exporter._refresh_model()
		bounds = State.document.bounds()
		center_prefix = "user://sprite_center_%s" % Time.get_ticks_usec()
		expect(settings.get_node("ViewRow/Center").button_pressed, "sprite centering is enabled by default")
	)
	get_tree().process_frame.connect(_capture_pose)
	for view in [1, 0]:
		for orthographic in [true, false]:
			step("When the user exports centered sprites", func():
				settings.get_node("ViewRow/Perspective").button_pressed = not orthographic
				settings.get_node("ViewRow/Center").button_pressed = true
				captured = false
				planes_stable = true
			)
			var error: Error = await exporter.export_sprite_sheet(center_prefix + "_center.png", 0, 1, 32, view, false, 2)
			var centered_pose := render_pose.duplicate()
			var centered := Image.new()
			centered.load(center_prefix + "_center.png")
			step("Then all frames use one centered model origin", func():
				expect(error == OK and captured, "the centered sheet renders")
				expect(centered_pose.model.origin.is_equal_approx(-bounds.get_center()), "the renderer translates the document center to the origin")
				var projection := Camera3D.PROJECTION_ORTHOGONAL if orthographic else Camera3D.PROJECTION_PERSPECTIVE
				expect(centered_pose.projection == projection, "the camera retains the selected projection")
				expect(planes_stable, "all animation frames and turntable views share the same clipping planes")
			)
			step("When the user disables sprite centering", func():
				settings.get_node("ViewRow/Center").button_pressed = false
				captured = false
				planes_stable = true
			)
			error = await exporter.export_sprite_sheet(center_prefix + "_origin.png", 0, 1, 32, view, false, 2)
			var original := Image.new()
			original.load(center_prefix + "_origin.png")
			step("Then the model origin changes without changing sprite framing", func():
				expect(error == OK and captured, "the sheet renders with the document origin")
				expect(render_pose.model == Transform3D.IDENTITY, "the renderer preserves the document origin")
				expect(planes_stable, "the uncentered animation also shares the same clipping planes")
				var centered_camera: Transform3D = centered_pose.camera
				var original_camera: Transform3D = render_pose.camera
				expect((original_camera.origin - centered_camera.origin).is_equal_approx(bounds.get_center()), "the camera follows the same model translation")
				expect(is_equal_approx(render_pose.near, centered_pose.near) and is_equal_approx(render_pose.far, centered_pose.far), "both model origins use the same clipping distances")
				var same_alpha := centered.get_size() == original.get_size()
				for y in centered.get_height():
					for x in centered.get_width():
						same_alpha = same_alpha and is_equal_approx(centered.get_pixel(x, y).a, original.get_pixel(x, y).a)
				expect(same_alpha, "centering preserves every frame and turntable silhouette")
				expect(State.document.bounds() == bounds, "the document retains its original bounds")
				expect(State.get_voxel_frame(0).has(Vector3i(30, 20, -10)) and State.get_voxel_frame(1).has(Vector3i(32, 20, -10)), "the document retains both original voxel positions")
			)
	step("When the Center control changes after export starts", func():
		settings.get_node("ViewRow/Center").button_pressed = true
		captured = false
		change_center_on_start = true
		State.activity_changed.connect(_change_center_after_start)
	)
	var snapshot_error: Error = await exporter.export_sprite_sheet(center_prefix + "_center.png", 0, 1, 32, 1, false, 2)
	step("Then the running export retains its captured settings", func():
		expect(snapshot_error == OK and captured, "the captured export settings produce a complete sheet")
		expect(not settings.get_node("ViewRow/Center").button_pressed, "the control contains the changed centering choice")
		expect(render_pose.model.origin.is_equal_approx(-bounds.get_center()), "the running export retains its original centered model")
		State.activity_changed.disconnect(_change_center_after_start)
	)
	step("When the export settings are restored", func():
		exporter._restore_export_settings()
	)
	step("Then the sprite Center toggle retains the saved choice", func():
		expect(not settings.get_node("ViewRow/Center").button_pressed, "the restored sprites preserve the document origin")
		expect(State.document.export_settings.sprite_center == false, "the document stores the sprite centering choice")
	)
	get_tree().process_frame.disconnect(_capture_pose)
	for suffix in ["_center.png", "_origin.png"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(center_prefix + suffix))


func _projection_run() -> void:
	step("Given a center voxel and an animation with wide document bounds", func():
		State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.document.add_frame()
		State.document.set_cell(1, Vector3i(-8, -8, -8), VoxelFrame.material(Color.BLUE))
		State.document.add_frame()
		State.document.set_cell(2, Vector3i(8, 8, 8), VoxelFrame.material(Color.BLUE))
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
		projection_path = "user://sprite_projection_%s.png" % Time.get_ticks_usec()
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
		var error: Error = await exporter.export_sprite_sheet(projection_path, 0, 0, -1, view, false)
		var orthographic := Image.new()
		orthographic.load(projection_path)
		expect(error == OK, "the orthographic sprite exports")
		step("When the user switches the sprite to perspective", func():
			exporter._sheet_settings.get_node("ViewRow/Perspective").button_pressed = true
		)
		var perspective_size := 74 if view == 2 else 20
		expect(exporter._sheet_settings.get_node("SizeRow/Size").value == perspective_size, "switching to perspective resets the frame size for the field of view")
		error = await exporter.export_sprite_sheet(projection_path, 0, 0, -1, view, false)
		var perspective := Image.new()
		perspective.load(projection_path)
		step("Then both projections retain the center voxel scale", func():
			expect(error == OK, "the perspective sprite exports")
			expect(orthographic.get_size() == Vector2i.ONE * ortho_size and perspective.get_size() == Vector2i.ONE * perspective_size, "each projection exports the recalculated tile dimensions")
			var ortho_rect := orthographic.get_used_rect()
			var perspective_rect := perspective.get_used_rect()
			expect(ortho_rect.size.x > 0 and ortho_rect.size.y > 0 and perspective_rect.size.x > 0 and perspective_rect.size.y > 0, "both projections contain the center voxel")
			expect(absi(ortho_rect.size.x - perspective_rect.size.x) <= 1, "the center voxel widths match within one output pixel")
			expect(absi(ortho_rect.size.y - perspective_rect.size.y) <= 1, "the center voxel heights match within one output pixel")
		)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(projection_path))


func _sampling_run() -> void:
	step("Given a voxel with fractional pixel alignment and an empty animation frame", func():
		State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.document.add_frame()
		State.frames_changed.emit()
		exporter._refresh_model()
		exporter._controls.get_node("LightingOptions/Enabled").button_pressed = false
		sampling_path = "user://sprite_sampling_%s.png" % Time.get_ticks_usec()
	)
	for orthographic in [true, false]:
		step("When the user exports six-pixel square frames with orthographic=%s" % orthographic, func():
			exporter._sheet_settings.get_node("ViewRow/Perspective").button_pressed = not orthographic
			exporter._model_camera.is_orthogonal = orthographic
			exporter._model_camera.size = 4.0
			exporter._model_camera.fov = 90.0
			exporter._model_camera.transform = Transform3D(Basis.IDENTITY, Vector3(-0.4, -0.4, 2.0))
		)
		var error: Error = await exporter.export_sprite_sheet(sampling_path, 0, 1, 6, 0)
		step("Then the PNG retains hard voxel edges at the selected size", func():
			expect(error == OK, "the small sprite sheet exports")
			var image := Image.new()
			expect(image.load(sampling_path) == OK, "the small sprite sheet loads")
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
			var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(sampling_path.get_basename() + ".json"))
			expect(data.meta.size.w == 13 and data.meta.size.h == 6, "the JSON describes the final sheet dimensions")
			expect(data.frames[0].frame.w == 6 and data.frames[1].frame.x == 7, "the JSON describes the selected tile size and gap")
			expect(State.get_voxel_frame(0).has(Vector3i.ZERO), "sampling preserves the document voxel")
		)
	for file in [sampling_path, sampling_path.get_basename() + ".json"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file))


func _sheet_run() -> void:
	step("Given a red frame, a blue frame, and an empty frame", func():
		controls = exporter._controls
		settings.get_node("TurntableRow/Turntable").button_pressed = false
		State.document.set_cell(0, Vector3i(-1, 0, 0), VoxelFrame.material(Color.RED))
		State.document.add_frame()
		State.document.set_cell(1, Vector3i(1, 0, 0), VoxelFrame.material(Color.BLUE))
		State.get_voxel_frame(1).delay_ms = 250
		State.document.add_frame()
		State.frames_changed.emit()
		State.active_tag = State.document.add_tag("Blue", 1, 1, AnimationTag.LoopMode.REVERSE, 2)
		original_document = State.document
		var prefix := "user://voxel_sprite_sheet_%s" % Time.get_ticks_usec()
		sheet_path = prefix + ".png"
		tag_path = prefix + "_tag.png"
		cancel_path = prefix + "_cancel.png"
		escape_path = prefix + "_escape.png"
		turntable_path = prefix + "_turntable.png"
		voxel_size_path = prefix + "_voxel_size.png"
		camera_size_path = prefix + "_camera_size.png"
		renderer_count = VoxelRenderer._active_renderer_count
	)
	step("Then the controls use simple defaults and describe the output size", func():
		expect(settings.get_node("SizeRow/Size").value == 64, "new documents start with a fixed sixty-four-pixel frame size")
		var document_size: float = settings.get_node("SizeRow/Size").value
		var frames: OptionButton = settings.get_node("FrameRow/Frames")
		frames.select(2)
		frames.item_selected.emit(2)
		expect(exporter._selected_frames() == Vector2i(1, 1), "the selected Blue tag contains only its frame")
		expect(settings.get_node("SizeRow/Size").value == document_size, "the selected tag retains the document framing")
		frames.select(0)
		frames.item_selected.emit(0)
		expect(exporter._selected_frames() == Vector2i(0, 2), "the all-frames range includes the empty frame")
	)
	step("When the user resets the sprite size", func():
		settings.get_node("SizeRow/Reset").pressed.emit()
	)
	step("Then Reset calculates the frame size from the document framing", func():
		expect(settings.get_node("SizeRow/Size").value == 3, "Reset fits the document with a three-pixel square frame")
	)
	step("When the user enables perspective for a preset view", func():
		settings.get_node("ViewRow/Perspective").button_pressed = true
	)
	step("Then the preset resets the size for perspective framing", func():
		var camera_settings: Dictionary = exporter._sheet_camera(1)
		expect(camera_settings.projection == Camera3D.PROJECTION_PERSPECTIVE, "the preset uses perspective projection")
		var bounds := State.document.bounds()
		var perspective_span: int = exporter._sprite_span(bounds, camera_settings)
		expect(settings.get_node("SizeRow/Size").value == perspective_span, "switching to perspective resets the frame size")
		settings.get_node("ViewRow/Perspective").button_pressed = false
		var orthographic_span: int = exporter._sprite_span(bounds, exporter._sheet_camera(1))
		expect(settings.get_node("SizeRow/Size").value == orthographic_span, "switching to orthographic resets the frame size")
		expect(perspective_span != orthographic_span, "the frame size follows the selected camera framing")
		settings.get_node("ViewRow/Perspective").button_pressed = false
	)
	step("Then the projection toggle overrides the 3D preview projection without changing its camera", func():
		var original_projection: int = exporter._model_camera.projection
		var ortho_settings: Dictionary = exporter._sheet_camera(0)
		expect(ortho_settings.projection == Camera3D.PROJECTION_ORTHOGONAL, "the 3D preview sprite uses orthographic projection")
		settings.get_node("ViewRow/Perspective").button_pressed = true
		var perspective_settings: Dictionary = exporter._sheet_camera(0)
		expect(perspective_settings.projection == Camera3D.PROJECTION_PERSPECTIVE, "the 3D preview sprite uses perspective projection")
		expect(ortho_settings.transforms == perspective_settings.transforms, "both projections retain the same camera pose")
		expect(exporter._model_camera.projection == original_projection, "the model camera retains its projection")
		settings.get_node("ViewRow/Perspective").button_pressed = false
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
	step("Then the camera change retains the explicit sprite size", func():
		expect(settings.get_node("SizeRow/Size").value == 3, "changing the view retains the three-pixel frame size")
	)
	step("When the user resets the size for the camera view", func():
		settings.get_node("SizeRow/Reset").pressed.emit()
	)
	step("Then Reset uses the camera framing", func():
		expect(settings.get_node("SizeRow/Size").value == 9, "the camera's nine-unit span sets a nine-pixel sprite")
	)
	var camera_error: Error = await exporter.export_sprite_sheet(camera_size_path, 0, 2, -1, 0, false)
	step("Then the camera-framed PNG retains one pixel per voxel", func():
		var image := Image.new()
		image.load(camera_size_path)
		expect(camera_error == OK and image.get_size() == Vector2i(19, 19), "the layout retains full nine-pixel square tiles with one-pixel gaps")
		expect(_visible_pixels(image, Rect2i(0, 0, 9, 9)) == 1, "camera framing preserves one visible pixel for one voxel")
	)
	step("When the user chooses a perspective camera ten units from the bounds center", func():
		exporter._model_camera.is_orthogonal = false
		exporter._model_camera.fov = 90.0
		exporter._model_camera.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, 10))
		exporter._model_camera.view_changed.emit()
		settings.get_node("ViewRow/Perspective").button_pressed = true
	)
	step("Then the projection switch resets the size for the new camera", func():
		expect(settings.get_node("SizeRow/Size").value == 20, "the ninety-degree view spans twenty units at the bounds center")
		settings.get_node("ViewRow/View").select(1)
		settings.get_node("ViewRow/View").item_selected.emit(1)
		settings.get_node("ViewRow/Perspective").button_pressed = false
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
	error = await exporter.export_sprite_sheet(tag_path, 1, 1, 32, 6, true, 1, "Blue")
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
		expect(exporter._export_viewport == null, "cancellation releases the render viewport reference")
		exporter.show_editor_tab()
	)
	step("When the user cancels another export with Escape", func():
		exporter._menu_item.get_node("ExportBtn").button_pressed = true
		_start_escaped_export()
		expect(State.edit_busy(), "the escaped sprite sheet rendering reports foreground work")
		_key(KEY_ESCAPE)
	)
	while not escaped_done:
		await get_tree().process_frame
	step("Then Escape cancellation publishes no partial file and releases resources", func():
		expect(escaped_result == ERR_BUSY, "the escaped export reports cancellation")
		expect(not FileAccess.file_exists(escape_path), "the escaped export writes no partial PNG")
		expect(not FileAccess.file_exists(escape_path.get_basename() + ".json"), "the escaped export writes no JSON sidecar")
		expect(not State.edit_busy(), "the escape cancellation releases editing")
		expect(VoxelRenderer._active_renderer_count == renderer_count, "the escape cancellation releases its temporary renderer")
		expect(exporter._export_viewport == null, "the escape cancellation releases the render viewport reference")
		exporter.show_editor_tab()
	)
	step("When the user resets the size for the front view", func():
		settings.get_node("ViewRow/View").select(2)
		settings.get_node("ViewRow/View").item_selected.emit(2)
		settings.get_node("SizeRow/Reset").pressed.emit()
	)
	error = await exporter.export_sprite_sheet(voxel_size_path, 0, 2, -1, 2, false)
	step("Then the reset front view uses one pixel per voxel", func():
		var image := Image.new()
		image.load(voxel_size_path)
		expect(error == OK and image.get_size() == Vector2i(7, 7), "the front-view layout retains full three-pixel square tiles")
		expect(_visible_pixels(image, Rect2i(0, 0, 3, 3)) == 1, "one voxel occupies one visible pixel in the reset front view")
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
	error = await exporter.export_sprite_sheet(turntable_path, 0, 2, 16, 2, true, 4)
	step("Then each turntable view retains the animation frame order", func():
		var image := Image.new()
		image.load(turntable_path)
		expect(error == OK and image.get_size() == Vector2i(67, 50), "the turntable contains four complete three-frame animations")
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(turntable_path.get_basename() + ".json"))
		for view_index in 4:
			var colors: Array[Color] = []
			for frame_index in 3:
				var index := view_index * 3 + frame_index
				var tile: Dictionary = data.frames[index].frame
				var rect := Rect2i(tile.x, tile.y, tile.w, tile.h)
				colors.append(_color_pixel(image, rect))
				expect(data.frames[index].filename == "%s_%d_%d" % [turntable_path.get_file().get_basename(), frame_index, view_index], "the tile name identifies its animation frame and view")
			expect(colors[0].a > 0.9 and colors[0].r > colors[0].b, "the view starts with the red frame")
			expect(colors[1].a > 0.9 and colors[1].b > colors[1].r, "the view continues with the blue frame")
			expect(colors[2].a == 0.0, "the view ends with the empty frame")
	)
	step("When older export settings are restored", func():
		State.document.export_settings.automatic_size = true
		exporter._restore_export_settings()
	)
	step("Then the saved frame size stays fixed", func():
		expect(settings.get_node("SizeRow/Size").value == 3, "legacy automatic sizing retains the saved three-pixel frame size")
		settings.get_node("SizeRow/Size").value = 37
		exporter._restore_export_settings()
		expect(settings.get_node("SizeRow/Size").value == 37, "restoring settings retains the explicit frame size")
		expect(not State.document.export_settings.has("automatic_size"), "new export settings store the explicit frame size")
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


func _shadows_run() -> void:
	step("Given a column and a floor in two animation frames", func():
		shadow_lighting = exporter._controls.get_node("LightingOptions")
		for x in range(-3, 4):
			for z in range(-3, 4):
				State.document.set_cell(0, Vector3i(x, 0, z), VoxelFrame.material(Color.from_rgba8(120, 120, 120)))
		State.document.frames.append(State.get_current_voxel_frame().copy_frame())
		for y in range(1, 7):
			State.document.set_cell(0, Vector3i(-2, y, 2), VoxelFrame.material(Color.RED))
			State.document.set_cell(1, Vector3i(2, y, -2), VoxelFrame.material(Color.BLUE))
		State.frames_changed.emit()
		exporter._model_camera.center_active()
		exporter._model_camera.set_view("isometric")
		shadow_lighting.get_node("Enabled").button_pressed = true
		shadow_lighting.get_node("LockView").button_pressed = false
		shadow_prefix = "user://voxel_shadow_%s" % Time.get_ticks_usec()
	)
	for camera_case in [{"view": 1, "ortho": true}, {"view": 1, "ortho": false}, {"view": 0, "ortho": true}, {"view": 0, "ortho": false}]:
		var orthographic: bool = camera_case.ortho
		var view: int = camera_case.view
		step("When the user exports with shadows disabled", func():
			settings.get_node("ViewRow/Perspective").button_pressed = not orthographic
			shadow_lighting.get_node("Shadows").button_pressed = false
		)
		var error: Error = await exporter.export_sprite_sheet(shadow_prefix + "_off.png", 0, 1, 128, view, false, 2)
		expect(error == OK, "the export without shadows completes")
		baseline = Image.new()
		expect(baseline.load(shadow_prefix + "_off.png") == OK, "the reference PNG is readable")
		if orthographic:
			orthographic_image = baseline
		else:
			expect(baseline.get_data() != orthographic_image.get_data(), "the projection toggle changes the rendered projection")
		step("When the user exports with shadows enabled", func():
			shadow_lighting.get_node("Shadows").button_pressed = true
		)
		error = await exporter.export_sprite_sheet(shadow_prefix + "_on.png", 0, 1, 128, view, false, 2)
		expect(error == OK, "the export with shadows completes")
		shadowed = Image.new()
		expect(shadowed.load(shadow_prefix + "_on.png") == OK, "the shadow PNG is readable")
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
		DirAccess.remove_absolute(ProjectSettings.globalize_path(shadow_prefix + suffix))


func _start_cancelled_export() -> void:
	cancelled_result = await exporter.export_sprite_sheet(cancel_path, 0, 2, 64, 1)
	cancelled_done = true


func _start_escaped_export() -> void:
	escaped_result = await exporter.export_sprite_sheet(escape_path, 0, 2, 64, 1)
	escaped_done = true


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	get_tree().root.push_input(event)
	event = InputEventKey.new()
	event.keycode = code
	event.pressed = false
	get_tree().root.push_input(event)


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
