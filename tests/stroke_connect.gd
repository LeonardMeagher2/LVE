extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _pressed := State.NONE
var _mouse_end := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("paints a connected stroke when the mouse jumps", _run)


func _run() -> void:
	step("Given a brush on an empty grid", func():
		State.current_color = Color8(200, 60, 60)
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		State.set_tool(State.tools.brush)
	)

	step("When the user clicks and jumps the mouse far in one motion", func():
		var start := aim(_vp, _center)
		_pressed = start.target
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = _center
		_vp.get_viewport().push_input(press)
		var drag_pos := _center + Vector2(0.0, 60.0)
		var motion := InputEventMouseMotion.new()
		motion.position = drag_pos
		motion.relative = Vector2(0.0, 60.0)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		_vp.get_viewport().push_input(motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = drag_pos
		_vp.get_viewport().push_input(release)
		_mouse_end = drag(_vp, drag_pos, start.plane).target
	)

	step("Then the cells between press and release are all painted", func():
		var frame: VoxelFrame = State.document.frames[0]
		var path := StrokeLine.cells(_pressed, _mouse_end)
		expect(frame.cells.has(_pressed), "the pressed cell is painted")
		expect(frame.cells.has(_mouse_end), "the cell under the mouse is painted")
		expect(path.size() >= 3, "the stroke spans several cells")
		for c in path:
			expect(frame.cells.has(c), "every cell along the stroke is painted")
	)
