extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _seed := State.NONE
var _blob_a: Array[Vector3i] = []
var _blob_b: Array[Vector3i] = []
var _red := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("the wand selects all connected voxels of one color", _run)


func _run() -> void:
	step("Given the wand tool and two gray blobs plus one red voxel", func():
		_vp = editor_viewport(_inst)
		State.set_tool(State.tools.wand)
		var svp := _vp.get_viewport()
		var vsize: Vector2i = svp.size
		if vsize.x <= 0 or vsize.y <= 0:
			svp.size = Vector2i(800, 500)
			vsize = svp.size
		_center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
		var start := aim(_vp, _center)
		_seed = start.target
		_blob_a = [_seed, _seed + Vector3i(1, 0, 0), _seed + Vector3i(0, 0, 1)]
		_blob_b = [_seed + Vector3i(8, 0, 0), _seed + Vector3i(9, 0, 0)]
		_red = _seed + Vector3i(0, 1, 0)
		var gray := State.document.add_color(Color8(150, 150, 150))
		var red := State.document.add_color(Color8(200, 60, 60))
		var f: VoxelFrame = State.document.frames[State.current_frame]
		for c in _blob_a:
			f.cells[c] = gray
		for c in _blob_b:
			f.cells[c] = gray
		f.cells[_red] = red
	)

	step("When the user clicks one gray voxel of the first blob", func():
		_click(_center, false)
	)

	step("Then only that connected blob is selected", func():
		expect(State.selection.cells.size() == _blob_a.size(), "selection holds exactly the first blob")
		for c in _blob_a:
			expect(State.selection.contains(c), "blob voxel is selected")
		expect(not State.selection.contains(_red), "the red voxel is not selected")
		expect(not State.selection.contains(_blob_b[0]), "the distant blob is not selected")
	)

	step("Given a shift click on the distant blob", func():
		var pos := _screen_pos_of(_blob_b[0])
		expect(pos != Vector2.INF, "the distant blob is visible on screen")
		_click(pos, true)
	)

	step("Then both blobs are selected", func():
		expect(State.selection.cells.size() == _blob_a.size() + _blob_b.size(), "selection holds both blobs")
		for c in _blob_b:
			expect(State.selection.contains(c), "distant blob voxel is selected")
	)

	step("When the user clicks an empty cell", func():
		var empty := _empty_screen_pos()
		expect(empty != Vector2.INF, "an empty cell screen position exists")
		_click(empty, false)
	)

	step("Then the selection is unchanged", func():
		expect(State.selection.cells.size() == _blob_a.size() + _blob_b.size(), "the empty cell click changed nothing")
	)

	step("When the user undoes", func():
		State.undo_redo.undo()
	)

	step("Then the selection reverts to the first blob", func():
		expect(State.selection.cells.size() == _blob_a.size(), "undo removes the added blob")
		expect(not State.selection.contains(_blob_b[0]), "the added blob is gone")
	)


func _click(pos: Vector2, with_shift: bool) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	press.shift_pressed = with_shift
	_vp.get_viewport().push_input(press)
	press.pressed = false
	press.shift_pressed = false
	_vp.get_viewport().push_input(press)


func _screen_pos_of(cell: Vector3i) -> Vector2:
	var svp := _vp.get_viewport()
	for dy in range(0, int(svp.size.y), 10):
		for dx in range(0, int(svp.size.x), 10):
			var pos := Vector2(dx, dy)
			if aim(_vp, pos).target == cell:
				return pos
	return Vector2.INF


func _empty_screen_pos() -> Vector2:
	var svp := _vp.get_viewport()
	for dy in range(int(svp.size.y) - 20, 0, -40):
		for dx in range(20, int(svp.size.x), 40):
			var res := aim(_vp, Vector2(dx, dy))
			if res.target != State.NONE and res.hit == State.NONE:
				return Vector2(dx, dy)
	return Vector2.INF
