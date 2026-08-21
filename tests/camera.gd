extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _yaw_before := 0.0
var _pitch_before := 0.0
var _target_before := Vector3.ZERO


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("can orbit and pan the camera", _run)


func _run() -> void:
	step("Given an editor with a voxel viewport", func():
		_vp = _inst.get_node("Content/Root/Body/CenterPane/ViewportContainer/Viewport/Editor")
		var svp := _vp.get_viewport()
		var vsize: Vector2i = svp.size
		if vsize.x <= 0 or vsize.y <= 0:
			svp.size = Vector2i(800, 500)
			vsize = svp.size
		_center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
	)

	step("When the user right-drags the viewport", func():
		_yaw_before = _vp.camera_rig._yaw
		_pitch_before = _vp.camera_rig._pitch
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_RIGHT
		press.pressed = true
		_vp.get_viewport().push_input(press)
		var move := InputEventMouseMotion.new()
		move.relative = Vector2(30, 20)
		move.button_mask = MOUSE_BUTTON_MASK_RIGHT
		_vp.get_viewport().push_input(move)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_RIGHT
		release.pressed = false
		_vp.get_viewport().push_input(release)
	)

	step("Then the camera yaw and pitch change", func():
		expect(_vp.camera_rig._yaw != _yaw_before, "right-drag changes yaw")
		expect(_vp.camera_rig._pitch != _pitch_before, "right-drag changes pitch")
	)

	step("When the user middle-drags the viewport", func():
		_target_before = _vp.camera_rig._target
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_MIDDLE
		press.pressed = true
		_vp.get_viewport().push_input(press)
		var move := InputEventMouseMotion.new()
		move.relative = Vector2(40, -20)
		move.button_mask = MOUSE_BUTTON_MASK_MIDDLE
		_vp.get_viewport().push_input(move)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_MIDDLE
		release.pressed = false
		_vp.get_viewport().push_input(release)
	)

	step("Then the camera target moves", func():
		expect(_vp.camera_rig._target != _target_before, "middle-drag changes the camera target")
	)
