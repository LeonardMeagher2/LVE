extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _mouse_end := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("pixel perfect mode paints the cursor cell and stays connected", _run)


func _run() -> void:
	step("Given a brush with pixel perfect enabled", func():
		State.current_color = Color.from_rgba8(200, 60, 60)
		State.set_tool_option("brush", "pixel_perfect", true)
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		State.set_tool(State.tools.pencil)
	)

	step("When the user draws a slow stroke", func():
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = _center
		_vp.get_viewport().push_input(press)
		var pos := _center
		for i in 4:
			pos += Vector2(0.0, 14.0)
			var motion := InputEventMouseMotion.new()
			motion.position = pos
			motion.relative = Vector2(0.0, 14.0)
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT
			_vp.get_viewport().push_input(motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = pos
		_vp.get_viewport().push_input(release)
		var req_end := _vp.pick_request(pos)
		_mouse_end = VoxelPicking.start_pick(req_end.origin, req_end.dir, req_end.cells, req_end.forward).target
	)

	step("Then the stroke is connected and the cursor cell is painted", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.cells.size() >= 2, "the stroke painted a line")
		expect(frame.cells.has(_mouse_end), "the cursor cell is painted")
	)
