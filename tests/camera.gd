extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var yaw_before := 0.0
var pitch_before := 0.0
var target_before := Vector3.ZERO


func _ready() -> void:
	test("can orbit and pan the camera", _run)


func _run() -> void:
	step("Given an editor with a voxel viewport", func():
		viewport = editor_viewport()
		var vsize: Vector2i = viewport.size
		if vsize.x <= 0 or vsize.y <= 0:
			viewport.size = Vector2i(800, 500)
			vsize = viewport.size
		center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
	)

	step("When the user right-drags the viewport", func():
		yaw_before = camera_rig()._yaw
		pitch_before = camera_rig()._pitch
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_RIGHT
		press.pressed = true
		viewport.push_input(press)
		var move := InputEventMouseMotion.new()
		move.relative = Vector2(30, 20)
		move.button_mask = MOUSE_BUTTON_MASK_RIGHT
		viewport.push_input(move)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_RIGHT
		release.pressed = false
		viewport.push_input(release)
	)

	step("Then the camera yaw and pitch change", func():
		expect(camera_rig()._yaw != yaw_before, "right-drag changes yaw")
		expect(camera_rig()._pitch != pitch_before, "right-drag changes pitch")
	)

	step("When the user middle-drags the viewport", func():
		target_before = camera_rig()._target
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_MIDDLE
		press.pressed = true
		viewport.push_input(press)
		var move := InputEventMouseMotion.new()
		move.relative = Vector2(40, -20)
		move.button_mask = MOUSE_BUTTON_MASK_MIDDLE
		viewport.push_input(move)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_MIDDLE
		release.pressed = false
		viewport.push_input(release)
	)

	step("Then the camera target moves", func():
		expect(camera_rig()._target != target_before, "middle-drag changes the camera target")
	)
