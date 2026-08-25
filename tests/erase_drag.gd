extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _c0 := State.NONE
var _c1 := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("can erase a stroke of voxels with a drag", _run)


func _run() -> void:
	step("Given a row of voxels under the drag path", func():
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		State.set_tool(State.tools.eraser)
		var start := aim(_vp, _center)
		_c0 = start.target
		_c1 = drag(_vp, _center + Vector2(0.0, 20.0), start.plane).target
		State.document.frames[0].cells[_c0] = State.current_color
		State.document.frames[0].cells[_c1] = State.current_color
		_vp.sync_to(0)
	)

	step("When the user presses on the wall face and drags down", func():
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = _center
		_vp.get_viewport().push_input(press)
		var drag_pos := _center + Vector2(0.0, 20.0)
		var motion := InputEventMouseMotion.new()
		motion.position = drag_pos
		motion.relative = Vector2(0.0, 20.0)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		_vp.get_viewport().push_input(motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = drag_pos
		_vp.get_viewport().push_input(release)
	)

	step("Then the voxels under the drag are erased", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(not frame.cells.has(_c0), "pressed voxel is erased")
		expect(not frame.cells.has(_c1), "dragged voxel is erased")
	)

	step("Then the whole stroke can be undone", func():
		State.undo_redo.undo()
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.cells.has(_c0), "pressed voxel returns after undo")
		expect(frame.cells.has(_c1), "dragged voxel returns after undo")
	)
