extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var mouse_end := VoxelPicking.NONE


func _ready() -> void:
	test("pixel perfect mode paints the cursor cell and stays connected", _run)


func _run() -> void:
	step("Given a brush with pixel perfect enabled", func():
		State.current_color = Color.from_rgba8(200, 60, 60)
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		center = Vector2(400.0, 250.0)
		activate_tool("Toolbar")
		press_option("Pixel perfect strokes")
	)

	step("When the user draws a slow stroke", func():
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = center
		viewport.push_input(press)
		var pos := center
		for i in 4:
			pos += Vector2(0.0, 14.0)
			var motion := InputEventMouseMotion.new()
			motion.position = pos
			motion.relative = Vector2(0.0, 14.0)
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT
			viewport.push_input(motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = pos
		viewport.push_input(release)
		var req_end := pick_request(pos)
		mouse_end = VoxelPicking.start_pick(req_end.origin, req_end.dir, req_end.cells, req_end.forward).target
	)

	step("Then the stroke is connected and the cursor cell is painted", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.cells.size() >= 2, "the stroke painted a line")
		expect(frame.cells.has(mouse_end), "the cursor cell is painted")
	)
