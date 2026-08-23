extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _top: PickResult
var _bottom: PickResult
var _before: Dictionary = {}
var _last_drag := Vector2.ZERO


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("the drawing plane follows the view direction, not the click position", _run)


func _run() -> void:
	step("Given the editor viewport at its default view", func():
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		var vsize: Vector2i = svp.size
		if vsize.x <= 0 or vsize.y <= 0:
			svp.size = Vector2i(800, 500)
			vsize = svp.size
		_center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
	)

	step("When the user aims at the top and bottom of the viewport", func():
		var svp := _vp.get_viewport()
		_top = aim(_vp, Vector2(_center.x, 60.0))
		_bottom = aim(_vp, Vector2(_center.x, float(svp.size.y) - 60.0))
	)

	step("Then both aims get the same plane axis", func():
		expect(_top.plane != null, "the top aim has a plane")
		expect(_bottom.plane != null, "the bottom aim has a plane")
		expect(_top.plane.axis == _bottom.plane.axis, "the plane axis is the same at top and bottom")
	)

	step("Given a voxel above the floor at the center aim", func():
		State.document.frames[0].cells[Vector3i(-3, 3, 0)] = State.document.ensure_color(State.current_color)
		_vp.sync_to(0)
	)

	step("When the user presses the voxel and drags down", func():
		_before = State.document.frames[0].cells.duplicate()
		_press(_center)
		_drag_to(_center + Vector2(0.0, 40.0))
		_drag_to(_center + Vector2(0.0, 80.0))
		_drag_to(_center + Vector2(0.0, 120.0))
		_release()
	)

	step("Then the stroke stays on one plane", func():
		var frame: VoxelFrame = State.document.frames[0]
		var drawn := 0
		var layer := -1
		var same := true
		for c in frame.cells:
			if _before.has(c):
				continue
			drawn += 1
			if layer == -1:
				layer = c.y
			elif c.y != layer:
				same = false
		expect(drawn > 1, "the drag painted a stroke")
		expect(same, "every painted cell is on the same layer")
	)


func _press(pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	_vp.get_viewport().push_input(press)


func _drag_to(pos: Vector2) -> void:
	_last_drag = pos
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.relative = Vector2.ZERO
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	_vp.get_viewport().push_input(motion)


func _release() -> void:
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = _last_drag
	_vp.get_viewport().push_input(release)
