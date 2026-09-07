extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var target_before := Vector3.ZERO
var cells_before := {}


func _ready() -> void:
	test("pan mode turns left-drag into panning instead of painting", _run)


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
		expect(camera_rig().view_mode == camera_rig().ViewMode.NONE, "the editor starts with no view mode")
	)

	step("When the user left-drags the viewport", func():
		_left_drag(center, Vector2(0.0, 120.0))
	)
	step("Then voxels are painted", func():
		expect(_cells().size() > 0, "the drag painted voxels")
	)

	step("When the user presses the pan toggle", func():
		_pan_toggle().button_pressed = true
		expect(camera_rig().view_mode == camera_rig().ViewMode.PAN, "the rig holds the pan mode")
		expect(not _rotate_toggle().button_pressed, "the rotate toggle stays off")
		target_before = camera_rig()._target
		cells_before = _cells().duplicate(true)
		_left_drag(center, Vector2(40.0, -20.0))
	)

	step("Then the view pans and no voxel is painted", func():
		expect(camera_rig()._target != target_before, "left-drag pans the camera target")
		expect(_cells().size() == cells_before.size(), "left-drag paints nothing")
	)

	step("When the user presses the pan toggle again", func():
		_pan_toggle().button_pressed = false
		expect(camera_rig().view_mode == camera_rig().ViewMode.NONE, "the rig holds no view mode")
		target_before = camera_rig()._target
		cells_before = _cells().duplicate(true)
		_left_drag(center + Vector2(200.0, 0.0), Vector2(0.0, 100.0))
	)

	step("Then painting works again and the camera target stays", func():
		expect(is_equal_approx(camera_rig()._target.x, target_before.x), "left-drag leaves the camera target alone")
		expect(_cells().size() > cells_before.size(), "left-drag paints voxels again")
	)
