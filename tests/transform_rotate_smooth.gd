extends "res://tests/test.gd"

var viewport: SubViewport
const SIZE := 6


func _ready() -> void:
	test("rotating without snap smooths the silhouette instead of aliasing it, and still undoes cleanly", _run)


func _run() -> void:
	step("Given a solid block selected with the rotate tool active and snap off", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		camera_rig().set_view("front")
		State.undo_redo.clear_history()
		State.selection.clear()
		_cells().clear()
		for x in SIZE:
			for y in SIZE:
				_cells()[Vector3i(x, y, 0)] = Color.from_rgba8(200, 60, 60)
				State.selection.add(Vector3i(x, y, 0))
		State.selection_changed.emit()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
		press_option("Snap to 90 degrees")
	)

	step("When the user drags a small angle short of a quarter turn", func():
		_drag_screen(Vector2(-30, -12))
	)

	step("Then the preview is a plausible rotated silhouette, not a hole-riddled mess", func():
		var count := _cells().size()
		var original := SIZE * SIZE
		expect(count > original * 0.6, "the rotated preview keeps most of the block's voxels (has %d, started with %d)" % [count, original])
		expect(count < original * 1.6, "the rotated preview does not balloon in voxel count (has %d, started with %d)" % [count, original])
	)

	step("When the user commits the unsnapped rotation", func():
		_press_option("Commit")
	)

	step("Then the rotation is one undo step", func():
		expect(State.undo_redo.has_undo(), "the committed unsnapped rotation is undoable")
	)

	step("When the user undoes the rotation", func():
		State.undo_redo.undo()
	)

	step("Then the original solid block returns exactly", func():
		expect(_cells().size() == SIZE * SIZE, "the block returns to its original %d voxels" % (SIZE * SIZE))
		for x in SIZE:
			for y in SIZE:
				expect(_cells().has(Vector3i(x, y, 0)), "cell (%d, %d, 0) is back" % [x, y])
	)


func _cells() -> Dictionary:
	return State.document.frames[0].cells


func _current_center() -> Vector3:
	var b := AABB()
	var first := true
	for c in _cells():
		var cb := AABB(Vector3(c) - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
		b = cb if first else b.merge(cb)
		first = false
	return b.get_center()


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