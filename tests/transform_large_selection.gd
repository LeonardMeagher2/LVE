extends "res://tests/test.gd"

var viewport: SubViewport
const SIZE := 10


func _ready() -> void:
	test("moving and rotating a large selection completes quickly with no leftover or lost voxels", _run)


func _run() -> void:
	step("Given a solid 10x10x10 block selected with the move tool active", func():
		_view_setup()
		State.undo_redo.clear_history()
		State.selection.clear()
		_frame().clear()
		for x in SIZE:
			for y in SIZE:
				for z in SIZE:
					var c := Vector3i(x, y, z)
					_frame().set_cell(c, VoxelFrame.material(Color.from_rgba8(200, 60, 60)))
					State.selection.add(c)
		State.selection_changed.emit()
		activate_tool("transform")
	)

	step("When the user drags the block several times and commits", func():
		var started := Time.get_ticks_msec()
		for i in 5:
			_drag_voxels(Vector3i(1, 0, 0))
		_press_option("Commit")
		var elapsed := Time.get_ticks_msec() - started
		expect(elapsed < 5000, "five incremental drags of a 1000-voxel block finish in under 5s (took %dms)" % elapsed)
	)

	step("Then the block kept exactly its voxel count with no duplicates", func():
		expect(_frame().count() == SIZE * SIZE * SIZE, "the block still holds %d voxels" % (SIZE * SIZE * SIZE))
	)

	step("When the user switches to Rotate with snap and turns the block a quarter turn", func():
		select_toolbar_item("transform", "Rotate")
		press_option("Snap to 90 degrees")
		var started := Time.get_ticks_msec()
		_drag_screen(Vector2(0, -100))
		_press_option("Commit")
		var elapsed := Time.get_ticks_msec() - started
		expect(elapsed < 5000, "a quarter turn of a 1000-voxel block finishes in under 5s (took %dms)" % elapsed)
	)

	step("Then the block still holds exactly its voxel count after rotating", func():
		expect(_frame().count() == SIZE * SIZE * SIZE, "the rotated block still holds %d voxels" % (SIZE * SIZE * SIZE))
	)


func _view_setup() -> void:
	viewport = editor_viewport()
	var container := viewport.get_parent()
	container.stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().set_view("front")


func _frame() -> VoxelFrame:
	return State.document.frames[0]


func _current_center() -> Vector3:
	var b := AABB()
	var first := true
	for c in _frame().positions():
		var cb := AABB(Vector3(c) - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
		b = cb if first else b.merge(cb)
		first = false
	return b.get_center()


func _drag_voxels(off: Vector3i) -> void:
	var c := _current_center()
	_mouse_button(camera_rig().unproject_position(c), true)
	_mouse_motion(camera_rig().unproject_position(c + Vector3(off)))
	_mouse_button(camera_rig().unproject_position(c + Vector3(off)), false)


func _drag_screen(rel: Vector2) -> void:
	var from := camera_rig().unproject_position(_current_center())
	var to := from + rel
	_mouse_button(from, true)
	_mouse_motion(to)
	_mouse_button(to, false)


func _mouse_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(ev)


func _mouse_motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(ev)


func _press_option(tooltip: String) -> void:
	var b := _find_option_button(tooltip)
	if b != null:
		b.pressed.emit()
