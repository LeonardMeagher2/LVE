extends "res://tests/test.gd"

var exporter: Node
var settings: Node
var captured := false
var render_pose: Dictionary
var bounds: AABB
var prefix := ""
var change_center_on_start := false
var planes_stable := true


func _ready() -> void:
	timeout = 30.0
	test("sprite centering preserves framing and document coordinates", _run)


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


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		return
	step("Given two animation frames away from the document origin", func():
		exporter = plugin("ExportPlugin")
		settings = exporter._sheet_settings
		State.document = VoxelDocument.new()
		State.document.set_cell(0, Vector3i(30, 20, -10), Color.RED)
		State.document.add_frame()
		State.document.set_cell(1, Vector3i(32, 20, -10), Color.BLUE)
		State.frames_changed.emit()
		exporter._refresh_model()
		bounds = State.document.bounds()
		prefix = "user://sprite_center_%s" % Time.get_ticks_usec()
		expect(settings.get_node("ViewRow/Center").button_pressed, "sprite centering is enabled by default")
	)
	get_tree().process_frame.connect(_capture_pose)
	for view in [1, 0]:
		for orthographic in [true, false]:
			step("When the user exports centered sprites", func():
				settings.get_node("ViewRow/Ortho").button_pressed = orthographic
				settings.get_node("ViewRow/Center").button_pressed = true
				captured = false
				planes_stable = true
			)
			var error: Error = await exporter.export_sprite_sheet(prefix + "_center.png", 0, 1, 32, view, false, 2)
			var centered_pose := render_pose.duplicate()
			var centered := Image.new()
			centered.load(prefix + "_center.png")
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
			error = await exporter.export_sprite_sheet(prefix + "_origin.png", 0, 1, 32, view, false, 2)
			var original := Image.new()
			original.load(prefix + "_origin.png")
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
	var snapshot_error: Error = await exporter.export_sprite_sheet(prefix + "_center.png", 0, 1, 32, 1, false, 2)
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
		DirAccess.remove_absolute(ProjectSettings.globalize_path(prefix + suffix))
