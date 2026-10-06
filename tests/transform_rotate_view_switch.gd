extends "res://tests/test.gd"

var viewport: SubViewport

# Same deliberately asymmetric shape used in transform_rotate_asymmetric.gd: parity mismatches on
# every axis catch rotation bugs that a solid or symmetric block would hide.
const SHAPE: Array = [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0),
	Vector3i(0, 1, 0), Vector3i(2, 1, 1),
	Vector3i(1, 0, 2), Vector3i(1, 1, 3),
	Vector3i(0, 0, 1), Vector3i(2, 0, 3),
]

# Hand-derived: SHAPE rotated 90 degrees around Z (front view), then 90 degrees around X (right
# view), both with the bounding box's own min corner held fixed, matching RotateTool's exact
# integer rotation convention.
const EXPECTED: Array = [
	Vector3i(1, 3, 0), Vector3i(1, 3, 1), Vector3i(1, 3, 2),
	Vector3i(0, 3, 0), Vector3i(0, 2, 2),
	Vector3i(1, 1, 1), Vector3i(0, 0, 1),
	Vector3i(1, 2, 0), Vector3i(1, 0, 2),
]


func _ready() -> void:
	test("a pending rotation continues correctly after the view changes mid-drag", _run)


func _run() -> void:
	step("Given the asymmetric shape rotated 90 degrees in the front view, not yet committed", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		State.undo_redo.clear_history()
		_paint_shape()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
		camera_rig().set_view("front")
		_drag_screen(Vector2(0, -100))
	)

	step("When the user switches to a perpendicular view and rotates again without committing", func():
		camera_rig().set_view("right")
		_drag_screen(Vector2(0, -100))
		_press_option("Commit")
	)

	step("Then both rotations compose correctly, seen from either view", func():
		expect(_frame().count() == SHAPE.size(), "the shape still holds %d voxels" % SHAPE.size())
		for c in EXPECTED:
			expect(_frame().has(c), "cell %s is at its expected composed position" % c)
		expect(State.undo_redo.has_undo(), "the composed rotation is still a single undo step")
	)

	step("When the user undoes", func():
		State.undo_redo.undo()
	)

	step("Then the original shape returns exactly", func():
		expect(_frame().count() == SHAPE.size(), "the shape still holds %d voxels" % SHAPE.size())
		for c in SHAPE:
			expect(_frame().has(c), "cell %s is back at its original position" % c)
	)


func _paint_shape() -> void:
	State.selection.clear()
	_frame().clear()
	for c in SHAPE:
		_frame().set_cell(c, Color.from_rgba8(200, 60, 60))
		State.selection.add(c)
	State.selection_changed.emit()


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
