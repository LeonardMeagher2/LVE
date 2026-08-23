extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _plane: StrokePlane
var _seed := State.NONE
var _near := State.NONE
var _far := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("the lasso selects the cells inside a freeform loop", _run)


func _run() -> void:
	step("Given the lasso tool and three voxels on one layer", func():
		_vp = editor_viewport(_inst)
		State.set_tool(State.tools.lasso)
		var svp := _vp.get_viewport()
		var vsize: Vector2i = svp.size
		if vsize.x <= 0 or vsize.y <= 0:
			svp.size = Vector2i(800, 500)
			vsize = svp.size
		_center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
		var start := aim(_vp, _center)
		_seed = start.target
		_plane = start.plane
		var along := Vector3i(1, 0, 0)
		if _plane.axis == 0:
			along = Vector3i(0, 1, 0)
		_near = _seed + along
		_far = _seed + along * 12
		var gray := State.document.ensure_color(Color8(150, 150, 150))
		var f: VoxelFrame = State.document.frames[State.current_frame]
		f.cells[_seed] = gray
		f.cells[_near] = gray
		f.cells[_far] = gray
	)

	step("When the user drags a square loop around the seeded voxel", func():
		_loop([
			_center + Vector2(-60.0, -60.0),
			_center + Vector2(60.0, -60.0),
			_center + Vector2(60.0, 60.0),
			_center + Vector2(-60.0, 60.0),
		])
	)

	step("Then the looped area is selected and the far voxel is not", func():
		expect(not State.selection.is_empty(), "selection is not empty after a loop")
		expect(State.selection.contains(_seed), "the seeded voxel is selected")
		var has_air := false
		for c in State.selection.to_array():
			if not State.document.frames[State.current_frame].cells.has(c):
				has_air = true
				break
		expect(has_air, "the looped area includes empty cells")
		expect(_on_layer(), "every selected cell lies on the pressed layer")
		expect(not State.selection.contains(_far), "the far voxel is not selected")
	)

	step("Given a shift drag around the far voxel", func():
		var pos := _screen_pos_of(_far)
		expect(pos != Vector2.INF, "the far voxel is visible on screen")
		_loop([
			pos + Vector2(-40.0, -40.0),
			pos + Vector2(40.0, -40.0),
			pos + Vector2(40.0, 40.0),
			pos + Vector2(-40.0, 40.0),
		], true)
	)

	step("Then the far voxel joins the selection", func():
		expect(State.selection.contains(_far), "the far voxel is selected after the shift loop")
	)

	step("When the user undoes", func():
		State.undo_redo.undo()
	)

	step("Then the selection holds only the first loop again", func():
		expect(not State.selection.contains(_far), "the far voxel left the selection after undo")
		expect(State.selection.contains(_seed), "the first loop survives undo")
	)

	step("When the user clicks without dragging", func():
		_click(_center)
	)

	step("Then the click cancels the selection", func():
		expect(State.selection.is_empty(), "selection is empty after a plain click")
	)


func _loop(corners: Array, with_shift := false) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = corners[0]
	press.shift_pressed = with_shift
	_vp.get_viewport().push_input(press)
	for i in range(1, corners.size()):
		var motion := InputEventMouseMotion.new()
		motion.position = corners[i]
		motion.relative = corners[i] - corners[i - 1]
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.shift_pressed = with_shift
		_vp.get_viewport().push_input(motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = corners[corners.size() - 1]
	_vp.get_viewport().push_input(release)


func _click(pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	_vp.get_viewport().push_input(press)
	press.pressed = false
	_vp.get_viewport().push_input(press)


func _on_layer() -> bool:
	for c in State.selection.to_array():
		if c[_plane.axis] != _seed[_plane.axis]:
			return false
	return true


func _screen_pos_of(cell: Vector3i) -> Vector2:
	var svp := _vp.get_viewport()
	for dy in range(0, int(svp.size.y), 10):
		for dx in range(0, int(svp.size.x), 10):
			var pos := Vector2(dx, dy)
			if aim(_vp, pos).target == cell:
				return pos
	return Vector2.INF
