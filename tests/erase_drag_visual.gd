extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _c0 := State.NONE
var _c_mid := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("the eraser highlight follows the voxel being erased", _run)


func _run() -> void:
	step("Given an eraser and a row of voxels under the drag path", func():
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		State.set_tool(State.tools.eraser)
		var start := aim(_vp, _center)
		_c0 = start.target
		_c_mid = drag(_vp, _center + Vector2(0.0, 20.0), start.plane).target
		State.document.frames[0].cells[_c0] = State.document.ensure_color(State.current_color)
		State.document.frames[0].cells[_c_mid] = State.document.ensure_color(State.current_color)
		_vp.sync_to(0)
	)

	step("When the user presses the wall and drags onto the lower voxel", func():
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = _center
		_vp.get_viewport().push_input(press)
		var mid := _center + Vector2(0.0, 20.0)
		var motion := InputEventMouseMotion.new()
		motion.position = mid
		motion.relative = Vector2(0.0, 20.0)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		_vp.get_viewport().push_input(motion)
	)

	step("Then the highlight is on the voxel being erased", func():
		var v: Node3D = _vp._tool.visual
		expect(v.visible, "the highlight is visible")
		expect(v.position == Vector3(_c_mid), "the highlight is on the voxel being erased")
	)

	step("When the user drags below the wall", func():
		var low := _center + Vector2(0.0, 50.0)
		var motion := InputEventMouseMotion.new()
		motion.position = low
		motion.relative = Vector2(0.0, 30.0)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		_vp.get_viewport().push_input(motion)
	)

	step("Then the highlight stays visible", func():
		var v: Node3D = _vp._tool.visual
		expect(v.visible, "the highlight is still visible")
	)

	step("When the user releases the drag", func():
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = _center + Vector2(0.0, 50.0)
		_vp.get_viewport().push_input(release)
	)
