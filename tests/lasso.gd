extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var plane: StrokePlane
var seed := VoxelPicking.NONE
var near := VoxelPicking.NONE
var far := VoxelPicking.NONE
var du := Vector3i(1, 0, 0)
var dv := Vector3i(0, 0, 1)
var sweep_cells := {}
var sweep_last := VoxelPicking.NONE
var probe := VoxelPicking.NONE


func _ready() -> void:
	test("the lasso selects swept tiles and fills the enclosed area", _run)


func _run() -> void:
	step("Given the lasso tool and three voxels on one layer", func():
		viewport = editor_viewport()
		activate_tool("selection")
		select_toolbar_item("selection", "Lasso")
		var vsize: Vector2i = viewport.size
		if vsize.x <= 0 or vsize.y <= 0:
			viewport.size = Vector2i(800, 500)
			vsize = viewport.size
		center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
		var start := aim(center)
		seed = start.target
		plane = start.plane
		if plane.axis == 0:
			du = Vector3i(0, 1, 0)
			dv = Vector3i(0, 0, 1)
		elif plane.axis == 2:
			du = Vector3i(1, 0, 0)
			dv = Vector3i(0, 1, 0)
		else:
			du = Vector3i(1, 0, 0)
			dv = Vector3i(0, 0, 1)
		near = seed + du
		far = seed + du * 12
		var gray := Color.from_rgba8(150, 150, 150)
		var f: VoxelFrame = State.document.frames[State.current_frame]
		f.cells[seed] = gray
		f.cells[near] = gray
		f.cells[far] = gray
	)

	step("When the user drags across five tiles from the seeded voxel", func():
		var pts: Array[Vector2] = []
		for i in 5:
			pts.append(_screen_pos_of(seed + du * i))
		var pr := aim(pts[0])
		expect(pr.plane != null and pr.target != VoxelPicking.NONE, "the first tile resolves under the cursor")
		sweep_cells.clear()
		sweep_last = VoxelPicking.NONE
		_expect_sweep(pr.target)
		for i in range(1, pts.size()):
			_expect_sweep(drag(pts[i], pr.plane).target)
		_drag_through(pts)
	)

	step("Then exactly the crossed tiles are selected", func():
		var sel := State.selection
		expect(sel.cells.size() == sweep_cells.size(), "the selection holds the swept cells")
		for c in sweep_cells:
			expect(sel.contains(c), "a swept tile is selected")
		var has_air := false
		for c in sel.to_array():
			if not State.document.frames[State.current_frame].cells.has(c):
				has_air = true
				break
		expect(has_air, "a swept empty tile is selected")
		expect(not sel.contains(far), "the far voxel is not selected")
	)

	step("When the user draws a square loop around an empty patch", func():
		var hubc := seed + du * 6
		probe = hubc
		var cs: Array[Vector3i] = [
			hubc - du * 3 - dv * 3,
			hubc + du * 3 - dv * 3,
			hubc + du * 3 + dv * 3,
			hubc - du * 3 + dv * 3,
		]
		var pts: Array[Vector2] = []
		for c in cs:
			pts.append(_screen_pos_of(c))
		var pr := aim(pts[0])
		sweep_cells.clear()
		sweep_last = VoxelPicking.NONE
		_expect_sweep(pr.target)
		for i in range(1, pts.size()):
			_expect_sweep(drag(pts[i], pr.plane).target)
		_drag_through(pts)
	)

	step("Then the loop fills its interior and replaces the old selection", func():
		var sel := State.selection
		expect(not sweep_cells.has(probe), "the enclosed tile was not swept by the loop")
		expect(sel.contains(probe), "the enclosed tile is selected without being swept")
		for c in sweep_cells:
			expect(sel.contains(c), "a swept loop corner is selected")
		expect(sel.cells.size() > sweep_cells.size(), "the fill adds interior cells beyond the sweep")
		expect(not sel.contains(seed), "a plain drag replaces the previous selection")
	)

	step("Given add mode for the next drag", func():
		press_option("Add")
	)

	step("When the user drags over the far voxel and beyond", func():
		var pts: Array[Vector2] = [
			_screen_pos_of(far),
			_screen_pos_of(far + du * 3),
		]
		var pr := aim(pts[0])
		sweep_cells.clear()
		sweep_last = VoxelPicking.NONE
		_expect_sweep(pr.target)
		for i in range(1, pts.size()):
			_expect_sweep(drag(pts[i], pr.plane).target)
		_drag_through(pts)
	)

	step("Then the far side joins the selection", func():
		for c in sweep_cells:
			expect(State.selection.contains(c), "a dragged tile joins the selection")
		expect(State.selection.contains(probe), "the filled loop survives the add drag")
	)

	step("When the user undoes", func():
		State.undo_redo.undo()
	)

	step("Then the selection holds only the filled loop again", func():
		for c in sweep_cells:
			expect(not State.selection.contains(c), "the shifted tiles left the selection after undo")
		expect(State.selection.contains(probe), "the filled loop survives undo")
	)

	step("Given replace mode for the click", func():
		press_option("Replace")
	)

	step("When the user clicks without dragging", func():
		_click(_screen_pos_of(seed))
	)

	step("Then the click selects only the clicked voxel", func():
		expect(State.selection.cells.size() == 1, "the click selected one voxel")
		expect(State.selection.contains(seed), "the clicked voxel is selected")
	)


func _expect_sweep(c: Vector3i) -> void:
	if c == VoxelPicking.NONE or c == sweep_last:
		return
	sweep_cells[c] = true
	sweep_last = c


func _screen_pos_of(cell: Vector3i) -> Vector2:
	var cam := camera_rig()
	return cam.unproject_position(Vector3(cell))


func _drag_through(points: Array, with_shift := false) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = points[0]
	press.shift_pressed = with_shift
	viewport.push_input(press)
	for i in range(1, points.size()):
		var motion := InputEventMouseMotion.new()
		motion.position = points[i]
		motion.relative = points[i] - points[i - 1]
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.shift_pressed = with_shift
		viewport.push_input(motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = points[points.size() - 1]
	viewport.push_input(release)


func _click(pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	viewport.push_input(press)
	press.pressed = false
	viewport.push_input(press)
