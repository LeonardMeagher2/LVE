extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var target_before := Vector3.ZERO
var yaw_before := 0.0
var pitch_before := 0.0
var cells_before := {}


func _ready() -> void:
	test("rotate mode turns left-drag into orbiting instead of painting", _run)


func _cells() -> Dictionary:
	return State.document.frames[0].cells


func _left_drag(from: Vector2, rel: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = from
	viewport.push_input(press)
	var motion := InputEventMouseMotion.new()
	motion.position = from + rel
	motion.relative = rel
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = from + rel
	viewport.push_input(release)


func _pan_toggle() -> Button:
	return main.get_node("%Viewport").get_node("ControlBar/PanToggle")


func _rotate_toggle() -> Button:
	return main.get_node("%Viewport").get_node("ControlBar/RotateToggle")


func _run() -> void:
	step("Given an editor with no view mode active", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		center = Vector2(400.0, 250.0)
		expect(viewport_scene().view_mode == viewport_scene().ViewMode.NONE, "the editor starts with no view mode")
	)

	step("When the user presses the rotate toggle", func():
		_rotate_toggle().button_pressed = true
		expect(viewport_scene().view_mode == viewport_scene().ViewMode.ROTATE, "the rig holds the rotate mode")
		expect(not _pan_toggle().button_pressed, "the pan toggle stays off")
	)

	step("When the user left-drags the viewport", func():
		yaw_before = camera_rig()._yaw
		pitch_before = camera_rig()._pitch
		target_before = camera_rig()._target
		cells_before = _cells().duplicate(true)
		_left_drag(center, Vector2(60.0, 30.0))
	)

	step("Then the view orbits and no voxel is painted", func():
		expect(camera_rig()._yaw != yaw_before, "left-drag changes the camera yaw")
		expect(camera_rig()._pitch != pitch_before, "left-drag changes the camera pitch")
		expect(camera_rig()._target == target_before, "orbiting leaves the camera target alone")
		expect(_cells().size() == cells_before.size(), "left-drag paints nothing")
	)

	step("When the user clicks pan while rotate is active", func():
		_pan_toggle().button_pressed = true
		expect(viewport_scene().view_mode == viewport_scene().ViewMode.PAN, "the rig holds the pan mode")
		expect(_pan_toggle().button_pressed, "the pan toggle stays on")
		expect(not _rotate_toggle().button_pressed, "the rotate toggle turns off")
	)

	step("When the user left-drags the viewport", func():
		target_before = camera_rig()._target
		cells_before = _cells().duplicate(true)
		_left_drag(center, Vector2(-50.0, 10.0))
	)

	step("Then the view pans and no voxel is painted", func():
		expect(camera_rig()._target != target_before, "left-drag pans the camera target")
		expect(_cells().size() == cells_before.size(), "left-drag paints nothing")
	)

	step("When the user presses the rotate toggle again", func():
		_rotate_toggle().button_pressed = true
		expect(viewport_scene().view_mode == viewport_scene().ViewMode.ROTATE, "the rig holds the rotate mode")
		expect(not _pan_toggle().button_pressed, "the pan toggle turns off")
	)

	step("When the user presses the active rotate toggle once more", func():
		_rotate_toggle().button_pressed = false
		expect(viewport_scene().view_mode == viewport_scene().ViewMode.NONE, "the rig holds no view mode")
		cells_before = _cells().duplicate(true)
		_left_drag(center + Vector2(200.0, 0.0), Vector2(0.0, 80.0))
	)

	step("Then painting works again", func():
		expect(_cells().size() > cells_before.size(), "left-drag paints voxels again")
	)
