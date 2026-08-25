extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _plane: StrokePlane
var _seed := State.NONE
var _near := State.NONE
var _far := State.NONE
var _du := Vector3i(1, 0, 0)
var _dv := Vector3i(0, 0, 1)
var _sweep_cells := {}
var _sweep_last := State.NONE
var _probe := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("the lasso selects swept tiles and fills the enclosed area", _run)


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
		if _plane.axis == 0:
			_du = Vector3i(0, 1, 0)
			_dv = Vector3i(0, 0, 1)
		elif _plane.axis == 2:
			_du = Vector3i(1, 0, 0)
			_dv = Vector3i(0, 1, 0)
		else:
			_du = Vector3i(1, 0, 0)
			_dv = Vector3i(0, 0, 1)
		_near = _seed + _du
		_far = _seed + _du * 12
		var gray := Color.from_rgba8(150, 150, 150)
		var f: VoxelFrame = State.document.frames[State.current_frame]
		f.cells[_seed] = gray
		f.cells[_near] = gray
		f.cells[_far] = gray
	)

	step("When the user drags across five tiles from the seeded voxel", func():
		var pts: Array[Vector2] = []
		for i in 5:
			pts.append(_screen_pos_of(_seed + _du * i))
		var pr := aim(_vp, pts[0])
		expect(pr.plane != null and pr.target != State.NONE, "the first tile resolves under the cursor")
		_sweep_cells.clear()
		_sweep_last = State.NONE
		_expect_sweep(pr.target)
		for i in range(1, pts.size()):
			_expect_sweep(drag(_vp, pts[i], pr.plane).target)
		_drag_through(pts)
	)

	step("Then exactly the crossed tiles are selected", func():
		var sel := State.selection
		expect(sel.cells.size() == _sweep_cells.size(), "the selection holds the swept cells")
		for c in _sweep_cells:
			expect(sel.contains(c), "a swept tile is selected")
		var has_air := false
		for c in sel.to_array():
			if not State.document.frames[State.current_frame].cells.has(c):
				has_air = true
				break
		expect(has_air, "a swept empty tile is selected")
		expect(not sel.contains(_far), "the far voxel is not selected")
	)

	step("When the user draws a square loop around an empty patch", func():
		var hubc := _seed + _du * 6
		_probe = hubc
		var cs: Array[Vector3i] = [
			hubc - _du * 3 - _dv * 3,
			hubc + _du * 3 - _dv * 3,
			hubc + _du * 3 + _dv * 3,
			hubc - _du * 3 + _dv * 3,
		]
		var pts: Array[Vector2] = []
		for c in cs:
			pts.append(_screen_pos_of(c))
		var pr := aim(_vp, pts[0])
		_sweep_cells.clear()
		_sweep_last = State.NONE
		_expect_sweep(pr.target)
		for i in range(1, pts.size()):
			_expect_sweep(drag(_vp, pts[i], pr.plane).target)
		_drag_through(pts)
	)

	step("Then the loop fills its interior and replaces the old selection", func():
		var sel := State.selection
		expect(not _sweep_cells.has(_probe), "the enclosed tile was not swept by the loop")
		expect(sel.contains(_probe), "the enclosed tile is selected without being swept")
		for c in _sweep_cells:
			expect(sel.contains(c), "a swept loop corner is selected")
		expect(sel.cells.size() > _sweep_cells.size(), "the fill adds interior cells beyond the sweep")
		expect(not sel.contains(_seed), "a plain drag replaces the previous selection")
	)

	step("Given a shift drag over the far voxel and beyond", func():
		var pts: Array[Vector2] = [
			_screen_pos_of(_far),
			_screen_pos_of(_far + _du * 3),
		]
		var pr := aim(_vp, pts[0])
		_sweep_cells.clear()
		_sweep_last = State.NONE
		_expect_sweep(pr.target)
		for i in range(1, pts.size()):
			_expect_sweep(drag(_vp, pts[i], pr.plane).target)
		_drag_through(pts, true)
	)

	step("Then the far side joins the selection", func():
		for c in _sweep_cells:
			expect(State.selection.contains(c), "a shifted drag tile joins the selection")
		expect(State.selection.contains(_probe), "the filled loop survives the shift drag")
	)

	step("When the user undoes", func():
		State.undo_redo.undo()
	)

	step("Then the selection holds only the filled loop again", func():
		for c in _sweep_cells:
			expect(not State.selection.contains(c), "the shifted tiles left the selection after undo")
		expect(State.selection.contains(_probe), "the filled loop survives undo")
	)

	step("When the user clicks without dragging", func():
		_click(_screen_pos_of(_seed))
	)

	step("Then the click selects only the clicked voxel", func():
		expect(State.selection.cells.size() == 1, "the click selected one voxel")
		expect(State.selection.contains(_seed), "the clicked voxel is selected")
	)


func _expect_sweep(c: Vector3i) -> void:
	if c == State.NONE or c == _sweep_last:
		return
	_sweep_cells[c] = true
	_sweep_last = c


func _screen_pos_of(cell: Vector3i) -> Vector2:
	var cam := _vp.camera_rig.camera()
	return cam.unproject_position(Vector3(cell))


func _drag_through(points: Array, with_shift := false) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = points[0]
	press.shift_pressed = with_shift
	_vp.get_viewport().push_input(press)
	for i in range(1, points.size()):
		var motion := InputEventMouseMotion.new()
		motion.position = points[i]
		motion.relative = points[i] - points[i - 1]
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.shift_pressed = with_shift
		_vp.get_viewport().push_input(motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = points[points.size() - 1]
	_vp.get_viewport().push_input(release)


func _click(pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	_vp.get_viewport().push_input(press)
	press.pressed = false
	_vp.get_viewport().push_input(press)
