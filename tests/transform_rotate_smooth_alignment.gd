extends "res://tests/test.gd"

var viewport: SubViewport

const SHAPE: Array = [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0),
	Vector3i(0, 1, 0), Vector3i(1, 1, 0), Vector3i(2, 1, 0),
]

const NEAR := PI / 2.0 - deg_to_rad(2.1)

var _snap_source_center := Vector3.ZERO


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
		var tool := _rotate_tool()
		tool._job_axis = Vector3.BACK
		tool._job_angle = NEAR
		tool._angle = NEAR
	)

	step("Then the smooth preview stays within one cell of the exact rotation", func():
		var tool := _rotate_tool()
		tool._apply_preview()
		var smooth: Dictionary = tool._dest_colors
		var min_c := _min_corner(smooth)
		expect(abs(min_c.x) <= 1 and abs(min_c.y) <= 1, "the smooth low corner stays within one cell (was %s)" % min_c)
		expect(smooth.size() >= 5, "the rotated block keeps nearly all 6 voxels (has %d)" % smooth.size())
		_snap_source_center = _frame_center()
	)

	step("When the angle snaps to the exact quarter turn", func():
		var tool := _rotate_tool()
		tool._job_angle = PI / 2.0
		tool._apply_preview()
	)

	step("Then the snapped result keeps the smooth preview centre", func():
		var moved := _frame_center().distance_to(_snap_source_center)
		expect(moved <= 0.51, "the snap keeps the centre (moved %.2f cells)" % moved)
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
	return State.document.active_layer().frames[0]


func _frame_center() -> Vector3:
	var bounds := AABB()
	var first := true
	for cell in _frame().positions():
		var cell_bounds := AABB(Vector3(cell) - Vector3.ONE * 0.5, Vector3.ONE)
		bounds = cell_bounds if first else bounds.merge(cell_bounds)
		first = false
	return bounds.get_center()


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
