extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _c0 := State.NONE
var _c1 := State.NONE
var _c2 := State.NONE
var _c3 := State.NONE
var _obstacle := State.NONE
var _last_drag := Vector2.ZERO


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("can move a selected voxel, move it again, and sweep without destroying", _run)


func _run() -> void:
	step("Given a selected voxel, an obstacle, and the move tool", func():
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		var start := aim(_vp, _center)
		_c0 = start.target
		_c1 = drag(_vp, _center + Vector2(0.0, 20.0), start.plane).target
		_c2 = drag(_vp, _center + Vector2(0.0, 40.0), start.plane).target
		_c3 = drag(_vp, _center + Vector2(0.0, 80.0), start.plane).target
		var obstacle := drag(_vp, _center + Vector2(0.0, 20.0), start.plane)
		_obstacle = obstacle.target
		State.document.frames[0].cells[_c0] = State.document.add_color(State.current_color)
		State.document.frames[0].cells[_obstacle] = State.document.add_color(Color8(40, 120, 40))
		State.selection.add(_c0)
		_vp.sync_to(0)
		State.set_tool(State.tools.move)
	)

	step("When the user sweeps the selection over the obstacle and commits", func():
		_press(_center)
		_drag_to(_center + Vector2(0.0, 20.0))
		_drag_to(_center + Vector2(0.0, 40.0))
		_release()
		_commit()
	)

	step("Then the voxel moved and the obstacle survived", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(not frame.cells.has(_c0), "original cell is cleared")
		expect(frame.cells.has(_c2), "voxel reached the far cell")
		expect(frame.cells.has(_obstacle), "obstacle voxel is not destroyed")
		expect(State.selection.is_empty(), "selection cleared after commit")
	)

	step("When the user selects the moved voxel, drags it again, and commits", func():
		State.selection.add(_c2)
		State.selection_changed.emit()
		_press(_center + Vector2(0.0, 40.0))
		_drag_to(_center + Vector2(0.0, 80.0))
		_release()
		_commit()
	)

	step("Then the voxel moved again and the obstacle still survives", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(not frame.cells.has(_c2), "second start is cleared")
		expect(frame.cells.has(_c3), "voxel reached the far cell")
		expect(frame.cells.has(_obstacle), "obstacle voxel still present")
		expect(State.selection.is_empty(), "selection cleared after commit")
	)

	step("When the user undoes the second move", func():
		State.undo_redo.undo()
	)

	step("Then the voxel returns to the sweep destination", func():
		expect(State.document.frames[0].cells.has(_c2), "voxel back at the sweep destination")
	)

	step("When the user undoes the sweep", func():
		State.undo_redo.undo()
	)

	step("Then the voxel returns", func():
		expect(State.document.frames[0].cells.has(_c0), "voxel back at the original cell")
	)


func _commit() -> void:
	var key := InputEventKey.new()
	key.keycode = KEY_ENTER
	key.pressed = true
	_vp.get_viewport().push_input(key)


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
