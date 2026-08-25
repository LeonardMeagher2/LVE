extends "res://tests/test.gd"

var _inst: Node = null
var _bar: ControlBar
var _vp: EditorViewport
var _center := Vector2.ZERO
var _target_before := Vector3.ZERO
var _yaw_before := 0.0
var _pitch_before := 0.0
var _cells_before := {}


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("rotate mode turns left-drag into orbiting instead of painting", _run)


func _cells() -> Dictionary:
	return State.document.frames[0].cells


func _left_drag(from: Vector2, rel: Vector2) -> void:
	var svp := _vp.get_viewport()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = from
	svp.push_input(press)
	var motion := InputEventMouseMotion.new()
	motion.position = from + rel
	motion.relative = rel
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	svp.push_input(motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = from + rel
	svp.push_input(release)


func _run() -> void:
	step("Given an editor with no view mode active", func():
		_bar = _inst.get_node("%ControlBar") as ControlBar
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		svp.get_parent().stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		expect(State.view_mode == State.ViewMode.NONE, "the editor starts with no view mode")
	)

	step("When the user presses the rotate toggle", func():
		(_bar.get_node("%RotateToggle") as Button).button_pressed = true
		expect(State.view_mode == State.ViewMode.ROTATE, "the state holds the rotate mode")
		expect(not (_bar.get_node("%PanToggle") as Button).button_pressed, "the pan toggle stays off")
		expect(_bar.get_node("%ViewportContainer").mouse_default_cursor_shape == Control.CURSOR_DRAG, "the cursor shows rotate feedback")
	)

	step("When the user left-drags the viewport", func():
		_yaw_before = _vp.camera_rig._yaw
		_pitch_before = _vp.camera_rig._pitch
		_target_before = _vp.camera_rig._target
		_cells_before = _cells().duplicate(true)
		_left_drag(_center, Vector2(60.0, 30.0))
	)

	step("Then the view orbits and no voxel is painted", func():
		expect(_vp.camera_rig._yaw != _yaw_before, "left-drag changes the camera yaw")
		expect(_vp.camera_rig._pitch != _pitch_before, "left-drag changes the camera pitch")
		expect(_vp.camera_rig._target == _target_before, "orbiting leaves the camera target alone")
		expect(_cells().size() == _cells_before.size(), "left-drag paints nothing")
	)

	step("When the user clicks pan while rotate is active", func():
		(_bar.get_node("%PanToggle") as Button).button_pressed = true
		expect(State.view_mode == State.ViewMode.PAN, "the state holds the pan mode")
		expect((_bar.get_node("%PanToggle") as Button).button_pressed, "the pan toggle stays on")
		expect(not (_bar.get_node("%RotateToggle") as Button).button_pressed, "the rotate toggle turns off")
	)

	step("When the user left-drags the viewport", func():
		_target_before = _vp.camera_rig._target
		_cells_before = _cells().duplicate(true)
		_left_drag(_center, Vector2(-50.0, 10.0))
	)

	step("Then the view pans and no voxel is painted", func():
		expect(_vp.camera_rig._target != _target_before, "left-drag pans the camera target")
		expect(_cells().size() == _cells_before.size(), "left-drag paints nothing")
	)

	step("When the user presses the rotate toggle again", func():
		(_bar.get_node("%RotateToggle") as Button).button_pressed = true
		expect(State.view_mode == State.ViewMode.ROTATE, "the state holds the rotate mode")
		expect(not (_bar.get_node("%PanToggle") as Button).button_pressed, "the pan toggle turns off")
	)

	step("When the user presses the active rotate toggle once more", func():
		(_bar.get_node("%RotateToggle") as Button).button_pressed = false
		expect(State.view_mode == State.ViewMode.NONE, "the state holds no view mode")
		expect(_bar.get_node("%ViewportContainer").mouse_default_cursor_shape != Control.CURSOR_DRAG, "the cursor returns to the tool")
		_cells_before = _cells().duplicate(true)
		_left_drag(_center + Vector2(200.0, 0.0), Vector2(0.0, 80.0))
	)

	step("Then painting works again", func():
		expect(_cells().size() > _cells_before.size(), "left-drag paints voxels again")
	)
