extends "res://tests/test.gd"

var viewport: SubViewport

# A shape whose per-axis extents deliberately mismatch parity, mirroring the Flamingo asset that
# exposed the bug: X spans 3 cells, Y spans 2, Z spans 4. Rotating about Z (X,Y in-plane) or about
# Y (X,Z in-plane) both hit a genuine parity mismatch, which produced holes under the old
# floating-point rotation. Deliberately irregular (not a solid block), like real voxel art.
const SHAPE: Array = [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0),
	Vector3i(0, 1, 0), Vector3i(2, 1, 1),
	Vector3i(1, 0, 2), Vector3i(1, 1, 3),
	Vector3i(0, 0, 1), Vector3i(2, 0, 3),
]


func _ready() -> void:
	test("rotating an asymmetric selection 90 degrees never leaves holes or duplicates, on any axis", _run)


func _run() -> void:
	step("Given the asymmetric shape selected with the rotate tool active", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		State.undo_redo.clear_history()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
	)

	for axis_name in ["front", "right", "top"]:
		step("When the user rotates the shape 90 degrees viewed from %s" % axis_name, func():
			_paint_shape()
			camera_rig().set_view(axis_name)
			_drag_screen(Vector2(0, -100))
			_press_option("Commit")
		)

		step("Then the rotated shape (%s) keeps every voxel, with no holes or duplicates" % axis_name, func():
			expect(_cells().size() == SHAPE.size(), "the rotated shape still holds %d voxels" % SHAPE.size())
		)

		step("When the user rotates the same shape 90 degrees three more times", func():
			for _i in 3:
				_drag_screen(Vector2(0, -100))
				_press_option("Commit")
		)

		step("Then four quarter turns (%s) return the exact original shape" % axis_name, func():
			var expected := {}
			for c in SHAPE:
				expected[c] = true
			expect(_cells().size() == SHAPE.size(), "the shape still holds %d voxels after four turns" % SHAPE.size())
			for c in expected:
				expect(_cells().has(c), "cell %s returned to its original position" % c)
		)


func _paint_shape() -> void:
	State.selection.clear()
	_cells().clear()
	for c in SHAPE:
		_cells()[c] = Color.from_rgba8(200, 60, 60)
		State.selection.add(c)
	State.selection_changed.emit()


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