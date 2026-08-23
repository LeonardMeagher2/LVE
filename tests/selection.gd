extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _seed := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("a drag selects every cell inside the dragged box", _run)


func _run() -> void:
	step("Given the select tool and two voxels near the center", func():
		_vp = editor_viewport(_inst)
		State.set_tool(State.tools.select)
		var svp := _vp.get_viewport()
		var vsize: Vector2i = svp.size
		if vsize.x <= 0 or vsize.y <= 0:
			svp.size = Vector2i(800, 500)
			vsize = svp.size
		_center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
		_seed = aim(_vp, _center).target
		var gray := State.document.ensure_color(Color8(150, 150, 150))
		var f: VoxelFrame = State.document.frames[State.current_frame]
		f.cells[_seed] = gray
		f.cells[_seed + Vector3i(12, 0, 0)] = gray
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

	step("Then every cell inside the box is selected", func():
		expect(not State.selection.is_empty(), "selection is not empty")
		expect(State.selection.contains(_seed), "the pressed cell is selected")
		expect(not State.selection.contains(_seed + Vector3i(12, 0, 0)), "the far voxel is not selected")
		var has_air := false
		for c in State.selection.to_array():
			if not State.document.frames[State.current_frame].cells.has(c):
				has_air = true
				break
		expect(has_air, "the selection includes empty cells")
	)

	step("When the user undoes the selection", func():
		State.undo_redo.undo()
	)

	step("Then the selection is cleared", func():
		expect(State.selection.is_empty(), "selection is empty after undo")
	)
