extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _last := Vector2.ZERO
var _a := State.NONE
var _b := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("moves all cells when there is no selection", _run)


func _run() -> void:
	step("Given two voxels, no selection, and the move tool", func():
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		var start := aim(_vp, _center)
		var plane := start.plane
		_a = start.target
		_b = drag(_vp, _center + Vector2(0.0, 20.0), plane).target
		State.document.set_cell(0, _a, VoxelFrame.material(State.current_color))
		State.document.set_cell(0, _b, VoxelFrame.material(Color.from_rgba8(200, 60, 200)))
		State.selection.clear()
		_vp.sync_to(0)
		State.set_tool(State.tools.move)
	)

	step("When the user drags on a voxel and commits", func():
		_press(_center)
		_drag_to(_center + Vector2(0.0, 40.0))
		_release()
		_commit()
	)

	step("Then both voxels moved", func():
		var frame: VoxelFrame = State.document.frames[0]
		var expected := drag(_vp, _center + Vector2(0.0, 40.0), aim(_vp, _center).plane).target
		expect(not frame.has(_a), "first original cell is cleared")
		expect(not frame.has(_b), "second original cell is cleared")
		expect(frame.count() == 2, "two voxels remain")
		expect(frame.has(expected), "the drag target holds a voxel")
	)

	step("When the user undoes the move", func():
		State.undo_redo.undo()
	)

	step("Then both voxels return", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.has(_a), "first voxel back")
		expect(frame.has(_b), "second voxel back")
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
