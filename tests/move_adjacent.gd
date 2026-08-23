extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _last := Vector2.ZERO
var _a := State.NONE
var _b := State.NONE
var _obstacle := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("moves two adjacent voxels, commits on a click, cancels on an outside click", _run)


func _run() -> void:
	step("Given two adjacent selected voxels, an obstacle, and the move tool", func():
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		var start := aim(_vp, _center)
		_a = start.target
		_b = drag(_vp, _center + Vector2(0.0, 20.0), start.plane).target
		var obstacle := drag(_vp, _center + Vector2(0.0, 40.0), start.plane)
		_obstacle = obstacle.target
		State.document.frames[0].cells[_a] = State.document.ensure_color(State.current_color)
		State.document.frames[0].cells[_b] = State.document.ensure_color(Color8(200, 60, 200))
		State.document.frames[0].cells[_obstacle] = State.document.ensure_color(Color8(40, 120, 40))
		State.selection.add(_a)
		State.selection.add(_b)
		_vp.sync_to(0)
		State.set_tool(State.tools.move)
	)

	step("When the user drags the pair over the obstacle and releases", func():
		_press(_center)
		_drag_to(_center + Vector2(0.0, 40.0))
		_release()
	)

	step("Then the move is pending and the pair sits on the obstacle cell", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(not frame.cells.has(_a), "first original cell is cleared")
		expect(not frame.cells.has(_b), "second original cell is cleared")
		expect(frame.cells.size() == 2, "two voxels remain")
		expect(State.selection.size() == 2, "selection keeps two cells")
	)

	step("When the user clicks the selection without moving", func():
		_press(_center + Vector2(0.0, 40.0))
		_release()
	)

	step("Then the move is committed and the selection is cleared", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(not frame.cells.has(_a), "first original cell is cleared")
		expect(not frame.cells.has(_b), "second original cell is cleared")
		expect(frame.cells.size() == 2, "two voxels remain")
		expect(State.selection.is_empty(), "selection is cleared after commit")
	)

	step("When the user undoes the move", func():
		State.undo_redo.undo()
	)

	step("Then both voxels and the obstacle return", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.cells.has(_a), "first voxel back")
		expect(frame.cells.has(_b), "second voxel back")
		expect(frame.cells.has(_obstacle), "obstacle voxel back")
	)

	step("When the user drags again and clicks outside the selection", func():
		_press(_center)
		_drag_to(_center + Vector2(0.0, 40.0))
		_release()
		_press(_center + Vector2(200.0, 0.0))
		_release()
	)

	step("Then the outside click cancels the move", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.cells.has(_a), "first voxel stayed")
		expect(frame.cells.has(_b), "second voxel stayed")
		expect(frame.cells.has(_obstacle), "obstacle voxel survived")
	)


func _plane() -> StrokePlane:
	return aim(_vp, _center).plane


func _press(pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	_vp.get_viewport().push_input(press)


func _drag_to(pos: Vector2) -> void:
	_last = pos
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.relative = Vector2.ZERO
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	_vp.get_viewport().push_input(motion)


func _release() -> void:
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = _last
	_vp.get_viewport().push_input(release)
