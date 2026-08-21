extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("can select a volume of voxels with a drag", _run)


func _run() -> void:
	step("Given the select tool on an empty grid", func():
		_vp = _inst.get_node("Content/Root/Body/CenterPane/ViewportContainer/Viewport/Editor")
		State.set_tool(State.tools.select)
		var svp := _vp.get_viewport()
		var vsize: Vector2i = svp.size
		if vsize.x <= 0 or vsize.y <= 0:
			svp.size = Vector2i(800, 500)
			vsize = svp.size
		_center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
	)

	step("When the user drags a box across the grid", func():
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = _center
		_vp.get_viewport().push_input(press)
		var drag_pos := _center + Vector2(60, 40)
		var motion := InputEventMouseMotion.new()
		motion.position = drag_pos
		motion.relative = Vector2(60, 40)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		_vp.get_viewport().push_input(motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = drag_pos
		_vp.get_viewport().push_input(release)
	)

	step("Then the dragged volume is selected", func():
		expect(not State.selection.is_empty(), "selection is not empty")
		var req := _vp.pick_request(_center)
		var pressed := VoxelPicking.start_pick(req.origin, req.dir, req.cells).target
		expect(State.selection.contains(pressed), "the pressed cell is selected")
	)

	step("When the user undoes the selection", func():
		State.undo_redo.undo()
	)

	step("Then the selection is cleared", func():
		expect(State.selection.is_empty(), "selection is empty after undo")
	)
