extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var seed := VoxelPicking.NONE
var blob_a: Array[Vector3i] = []
var blob_b: Array[Vector3i] = []
var red := VoxelPicking.NONE


func _ready() -> void:
	test("the wand selects all connected voxels of one color", _run)


func _run() -> void:
	step("Given the wand tool and two gray blobs plus one red voxel", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		activate_tool("selection")
		select_toolbar_item("selection", "Wand")
		center = Vector2(viewport.size.x * 0.5, viewport.size.y * 0.5)
		var start := aim(center)
		seed = start.target
		blob_a = [seed, seed + Vector3i(1, 0, 0), seed + Vector3i(0, 0, 1)]
		blob_b = [seed + Vector3i(8, 0, 0), seed + Vector3i(9, 0, 0)]
		# Offset in X, not placed directly above seed. The center click's ray has no X
		# component at the default camera angle, so a voxel stacked with the same X and Z as
		# seed can sit exactly on that ray and get hit instead of seed.
		red = seed + Vector3i(1, 1, 0)
		var gray := Color.from_rgba8(150, 150, 150)
		var red_c := Color.from_rgba8(200, 60, 60)
		var f: VoxelFrame = State.document.frames[State.current_frame]
		for c in blob_a:
			f.cells[c] = gray
		for c in blob_b:
			f.cells[c] = gray
		f.cells[red] = red_c
	)

	step("When the user clicks one gray voxel of the first blob", func():
		_click(center, false)
	)

	step("Then only that connected blob is selected", func():
		expect(State.selection.cells.size() == blob_a.size(), "selection holds exactly the first blob")
		for c in blob_a:
			expect(State.selection.contains(c), "blob voxel is selected")
		expect(not State.selection.contains(red), "the red voxel is not selected")
		expect(not State.selection.contains(blob_b[0]), "the distant blob is not selected")
	)

	step("Given add mode for the next click", func():
		press_option("Add")
	)

	step("When the user clicks the distant blob", func():
		var pos := _screen_pos_of(blob_b[0])
		expect(pos != Vector2.INF, "the distant blob is visible on screen")
		_click(pos, false)
	)

	step("Then both blobs are selected", func():
		expect(State.selection.cells.size() == blob_a.size() + blob_b.size(), "selection holds both blobs")
		for c in blob_b:
			expect(State.selection.contains(c), "distant blob voxel is selected")
	)

	step("When the user clicks an empty cell", func():
		var empty := _empty_screen_pos()
		expect(empty != Vector2.INF, "an empty cell screen position exists")
		_click(empty, false)
	)

	step("Then the selection is unchanged", func():
		expect(State.selection.cells.size() == blob_a.size() + blob_b.size(), "the empty cell click changed nothing")
	)

	step("When the user undoes", func():
		State.undo_redo.undo()
	)

	step("Then the selection reverts to the first blob", func():
		expect(State.selection.cells.size() == blob_a.size(), "undo removes the added blob")
		expect(not State.selection.contains(blob_b[0]), "the added blob is gone")
	)


func _click(pos: Vector2, with_shift: bool) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	press.shift_pressed = with_shift
	viewport.push_input(press)
	press.pressed = false
	press.shift_pressed = false
	viewport.push_input(press)


func _screen_pos_of(cell: Vector3i) -> Vector2:
	for dy in range(0, int(viewport.size.y), 10):
		for dx in range(0, int(viewport.size.x), 10):
			var pos := Vector2(dx, dy)
			if aim(pos).target == cell:
				return pos
	return Vector2.INF


func _empty_screen_pos() -> Vector2:
	for dy in range(int(viewport.size.y) - 20, 0, -40):
		for dx in range(20, int(viewport.size.x), 40):
			var res := aim(Vector2(dx, dy))
			if res.target != VoxelPicking.NONE and res.hit == VoxelPicking.NONE:
				return Vector2(dx, dy)
	return Vector2.INF
