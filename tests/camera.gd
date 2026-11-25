extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var yaw_before := 0.0
var pitch_before := 0.0
var target_before := Vector3.ZERO
var clip_camera: EditorCameraRig
var far_before := 0.0
var flat_helper: AABB
var near_helper: AABB
var pan_rig: EditorCameraRig
var pan_first := 0.0
var pan_box := AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))


func _ready() -> void:
	test("can orbit and pan the camera", _run)
	test("the orthographic clip range covers helper bounds", _clip_run, "orthographic_clip")
	test("the view reset does not store its pose", _reset_run, "reset_pose")
	test("panning follows the view span at any field of view", _pan_run, "pan_fov")


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


func _clip_run() -> void:
	step("Given an orthographic camera on a small document", func():
		clip_camera = camera_rig()
		clip_camera.is_orthogonal = true
		clip_camera.center_on(AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4)))
		far_before = clip_camera.far
	)
	step("When a flat helper box extends behind the document", func():
		flat_helper = AABB(Vector3(0, 0, -80), Vector3(8, 0, 32))
		clip_camera.set_helper_far_bounds(&"test", flat_helper)
	)
	step("Then the far plane contains the flat helper", func():
		var forward := -clip_camera.global_transform.basis.z
		var farthest := (flat_helper.get_support(forward) - clip_camera.global_position).dot(forward)
		expect(clip_camera.far >= farthest + 2.0 - 0.001, "the far plane clears the flat helper box")
	)
	step("When a helper box surrounds the camera and the view updates", func():
		near_helper = AABB(clip_camera.global_position - Vector3.ONE, Vector3.ONE * 2.0)
		clip_camera.set_helper_far_bounds(&"near", near_helper)
		clip_camera.zoom(1.0)
	)
	step("Then the camera backs off to keep the helper in front", func():
		var forward := -clip_camera.global_transform.basis.z
		var nearest := (near_helper.get_support(-forward) - clip_camera.global_position).dot(forward)
		expect(nearest >= 1.0 - 0.001, "the near plane stays one unit ahead of the helper")
	)
	step("When the helpers are cleared and the view updates", func():
		clip_camera.clear_helper_far_bounds(&"test")
		clip_camera.clear_helper_far_bounds(&"near")
		clip_camera.zoom(1.0)
	)
	step("Then the far plane returns to the document", func():
		expect(not clip_camera._helper_far_bounds.has(&"test"), "the flat helper leaves the camera")
		expect(not clip_camera._helper_far_bounds.has(&"near"), "the near helper leaves the camera")
		expect(is_equal_approx(clip_camera.far, far_before), "the far plane returns to the document bounds")
	)
	clip_camera.is_orthogonal = false


func _reset_run() -> void:
	step("Given a document with no saved camera", func():
		State.document.edit_camera = {}
		viewport_scene().reset_view_state()
	)
	step("Then the reset pose stays out of the document", func():
		expect(State.document.edit_camera.is_empty(), "the reset does not store a camera")
		expect(is_equal_approx(camera_rig()._pitch, deg_to_rad(45.0)), "the reset uses the default pitch")
	)


func _pan_run() -> void:
	step("Given a perspective camera framed on a box", func():
		pan_rig = camera_rig()
		pan_rig.is_orthogonal = false
		pan_rig.set_field_of_view(45.0)
		pan_rig.center_on(pan_box)
	)
	step("When the user drags a tenth of the view height", func():
		pan_first = _pan_tenth()
	)
	step("Then the content moves a tenth of the view", func():
		expect(is_equal_approx(pan_first, _view_span() * 0.1), "the pan follows the view span")
	)
	step("When the field of view narrows to twenty degrees", func():
		pan_rig.set_field_of_view(20.0)
		pan_rig.center_on(pan_box)
	)
	step("Then the same drag still moves a tenth of the view", func():
		var second := _pan_tenth()
		expect(is_equal_approx(second, _view_span() * 0.1), "the narrowed field of view keeps the pan distance")
		expect(is_equal_approx(second, pan_first), "the drag moves the same world distance")
	)
	step("When the camera turns orthographic", func():
		pan_rig.set_field_of_view(0.0)
		pan_rig.center_on(pan_box)
	)
	step("Then the drag still moves a tenth of the view", func():
		var third := _pan_tenth()
		expect(pan_rig.is_orthogonal, "the camera is orthographic")
		expect(is_equal_approx(third, pan_rig.size * 0.1), "the orthographic pan follows the view span")
	)


func _pan_tenth() -> float:
	var before := pan_rig._target
	pan_rig.pan(Vector2(0.0, _pan_height() * 0.1))
	return (pan_rig._target - before).length()


func _pan_height() -> float:
	return maxf(pan_rig.get_viewport().get_visible_rect().size.y, 1.0)


func _view_span() -> float:
	return 2.0 * pan_rig._dist * tan(deg_to_rad(pan_rig.fov) * 0.5)
