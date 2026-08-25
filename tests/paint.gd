extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _pressed := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("can paint a stroke of voxels with a drag", _run)


func _run() -> void:
	step("Given a red brush on an empty grid", func():
		State.current_color = Color.from_rgba8(200, 60, 60)
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
	)

	step("When the user presses and drags the viewport", func():
		var req := _vp.pick_request(_center)
		_pressed = VoxelPicking.start_pick(req.origin, req.dir, req.cells, req.forward).target
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = _center
		_vp.get_viewport().push_input(press)
		var drag_pos := _center + Vector2(0.0, 150.0)
		var motion := InputEventMouseMotion.new()
		motion.position = drag_pos
		motion.relative = Vector2(0.0, 150.0)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		_vp.get_viewport().push_input(motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = drag_pos
		_vp.get_viewport().push_input(release)
	)

	step("Then a stroke of voxels is painted", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.cells.size() > 1, "the drag painted a stroke")
		expect(frame.cells.has(_pressed), "the pressed cell is painted")
	)

	step("When the user undoes the stroke", func():
		State.undo_redo.undo()
	)

	step("Then the stroke is removed", func():
		expect(State.document.frames[0].cells.is_empty(), "the stroke is removed")
	)
