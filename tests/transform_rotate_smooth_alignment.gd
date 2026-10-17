extends "res://tests/test.gd"

var viewport: SubViewport

# A solid, non-square, single-layer block. Non-square matters: a square selection would hide this
# bug entirely, since the correction this test checks for is exactly zero for a square (rotating a
# square around its own center already agrees with the exact min-corner-fixed convention at every
# 90 degree multiple). Solid matters too: RotSprite's own continuous point-rotation-and-floor
# sampling has the same grid-parity boundary sensitivity that the exact algorithm was built to
# avoid, and it can only surface at a true, exact cardinal angle. Real drags never land there
# (dispatch always hands an exact cardinal to the exact algorithm instead), so this test checks
# just short of the boundary, where a real free-rotation drag actually hands off to it.
const SHAPE: Array = [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0),
	Vector3i(0, 1, 0), Vector3i(1, 1, 0), Vector3i(2, 1, 0),
]

const NEAR := PI / 2.0 - deg_to_rad(1.0)


func _ready() -> void:
	test("the smooth rotation preview lands in the same place the exact rotation would, near a cardinal angle", _run)


func _run() -> void:
	step("Given a solid 3x2 block grabbed with the rotate tool in the front view", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		State.undo_redo.clear_history()
		_paint_shape()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
		camera_rig().set_view("front")
		_press_at_center()
	)

	step("When the live angle is forced just short of 90 degrees, where a real drag hands off to the smooth path", func():
		_rotate_tool()._angle = NEAR
	)

	step("Then the smooth preview already sits at the same bounding box the exact rotation would land on", func():
		var tool := _rotate_tool()
		tool._apply_preview()
		var smooth: Dictionary = tool._dest_colors
		var min_c := _min_corner(smooth)
		expect(min_c == Vector2i(0, 0), "the rotated block's low corner is (0, 0) (was %s)" % min_c)
		expect(smooth.size() >= 5, "the rotated block keeps nearly all 6 voxels (has %d)" % smooth.size())
	)

	step("Cleanup: release the press", func():
		_release()
	)


func _rotate_tool() -> Node:
	return plugin("TransformPlugin")._rotate


func _paint_shape() -> void:
	State.selection.clear()
	_frame().clear()
	for c in SHAPE:
		_frame().set_cell(c, VoxelFrame.material(Color.from_rgba8(200, 60, 60)))
		State.selection.add(c)
	State.selection_changed.emit()


func _frame() -> VoxelFrame:
	return State.document.frames[0]


func _min_corner(dest: Dictionary) -> Vector2i:
	var min_c := Vector2i(999999, 999999)
	for d in dest:
		var c: Vector3i = d
		min_c = Vector2i(mini(min_c.x, c.x), mini(min_c.y, c.y))
	return min_c


func _current_center() -> Vector3:
	var b := AABB()
	var first := true
	for c in _frame().positions():
		var cb := AABB(Vector3(c) - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
		b = cb if first else b.merge(cb)
		first = false
	return b.get_center()


func _press_at_center() -> void:
	var pos := camera_rig().unproject_position(_current_center())
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(ev)


func _release() -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = false
	ev.position = camera_rig().unproject_position(_current_center())
	ev.button_mask = 0
	viewport.push_input(ev)
