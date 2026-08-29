extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _last_drag := Vector2.ZERO

const HALF := Vector3(0.5, 0.5, 0.5)
const QUARTER := PI / 2.0
const BAR_MID := Vector3i(1, 0, 0)
const BAR_CELLS: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)]


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("rotates the selection around its center on all axes and commits or cancels", _run)


func _run() -> void:
	_rotate_test(Vector2(200.0, -30.0), "default", 1, 1.0)
	_rotate_test(Vector2(0.0, -100.0), "front", 2, 1.0)
	_rotate_test(Vector2(100.0, 0.0), "right", 0, 1.0)

	step("When the user rotates and cancels with the discard button", func():
		_vp.set_view("default")
		_setup_bar()
		_press(_center)
		_drag_to(_center + Vector2(200.0, -30.0))
		_release()
		_discard()
	)

	step("Then the original cells are restored", func():
		var frame: VoxelFrame = State.document.frames[0]
		var all_present := true
		for c in BAR_CELLS:
			if not frame.cells.has(c):
				all_present = false
		expect(all_present, "discard restored every original cell")
	)

	step("When the user rotates again and commits then undoes", func():
		_select_frame_cells()
		_press(_center)
		_drag_to(_center + Vector2(200.0, -30.0))
		_release()
		_commit()
	)

	step("Then the rotation is applied", func():
		var expected := _expected_cells(1, 1.0)
		var frame: VoxelFrame = State.document.frames[0]
		var all_present := true
		for c in expected:
			if not frame.cells.has(c):
				all_present = false
		expect(all_present, "rotated cells present after commit")
	)

	step("When the user undoes", func():
		State.undo_redo.undo()
	)

	step("Then the original cells return", func():
		var frame: VoxelFrame = State.document.frames[0]
		var all_present := true
		for c in BAR_CELLS:
			if not frame.cells.has(c):
				all_present = false
		expect(all_present, "undo restored every original cell")
	)

	step("When the user redoes", func():
		State.undo_redo.redo()
	)

	step("Then the rotation is restored", func():
		var expected := _expected_cells(1, 1.0)
		var frame: VoxelFrame = State.document.frames[0]
		var all_present := true
		for c in expected:
			if not frame.cells.has(c):
				all_present = false
		expect(all_present, "redo restored rotated cells")
	)


func _rotate_test(drag_offset: Vector2, view_name: String, axis: int, axis_sign: float) -> void:
	step("Given a bar along X with the rotate tool in the %s view" % view_name, func():
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		_setup_bar()
		_vp.set_view(view_name)
		State.set_tool_option("transform", "snap", true)
		State.set_tool(State.tools.rotate)
	)

	step("When the user drags a quarter turn and commits", func():
		_press(_center)
		_drag_to(_center + drag_offset)
		_release()
		_commit()
	)

	step("Then the bar sits at the rotated cells", func():
		var expected := _expected_cells(axis, axis_sign)
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.cells.size() == expected.size(), "the rotated frame holds three voxels")
		var all_present := true
		for c in expected:
			if not frame.cells.has(c):
				all_present = false
		expect(all_present, "every source voxel reached its rotated cell in %s view" % view_name)
	)

	step("When the user undoes the rotation", func():
		State.undo_redo.undo()
	)

	step("Then the original cells return", func():
		var frame: VoxelFrame = State.document.frames[0]
		var all_present := true
		for c in BAR_CELLS:
			if not frame.cells.has(c):
				all_present = false
		expect(all_present, "undo restored every original cell in %s view" % view_name)
	)


func _setup_bar() -> void:
	State.document.frames[0].cells.clear()
	for c in BAR_CELLS:
		State.document.frames[0].cells[c] = Color.from_rgba8(200, 60, 60)
	_select_frame_cells()
	_vp.sync_to(0)


func _expected_cells(axis: int, axis_sign: float) -> Dictionary:
	var axis_vec := Vector3.ZERO
	axis_vec[axis] = axis_sign
	var pivot := Vector3(BAR_MID) + HALF
	var rot := Basis(axis_vec, QUARTER)
	var out := {}
	for c in BAR_CELLS:
		var rel := Vector3(c) + HALF - pivot
		var abs_pos := rot * rel + pivot
		out[Vector3i(floori(abs_pos.x), floori(abs_pos.y), floori(abs_pos.z))] = true
	return out


func _select_frame_cells() -> void:
	State.selection.clear()
	for c in State.document.frames[0].cells:
		State.selection.add(c)
	State.selection_changed.emit()


func _commit() -> void:
	_press_option_button("commit")


func _discard() -> void:
	_press_option_button("cancel")


func _press_option_button(btn_name: String) -> void:
	var bar := _inst.get_node("%OptionBar")
	for c in bar.get_node("OptionsBox").get_children():
		if c.has_node(btn_name):
			(c.get_node(btn_name) as Button).pressed.emit()
			return


func _press(pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	_vp.get_viewport().push_input(press)


func _drag_to(pos: Vector2) -> void:
	_last_drag = pos
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.relative = Vector2.ZERO
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	_vp.get_viewport().push_input(motion)


func _release() -> void:
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = _last_drag
	_vp.get_viewport().push_input(release)
