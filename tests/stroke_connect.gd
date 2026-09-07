extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var pressed := VoxelPicking.NONE
var mouse_end := VoxelPicking.NONE


func _ready() -> void:
	test("paints a connected stroke when the mouse jumps", _run)


func _run() -> void:
	step("Given a brush on an empty grid", func():
		State.current_color = Color.from_rgba8(200, 60, 60)
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		center = Vector2(400.0, 250.0)
		activate_tool("Toolbar")
	)

	step("When the user clicks and jumps the mouse far in one motion", func():
		var start := aim(center)
		pressed = start.target
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = center
		viewport.push_input(press)
		var drag_pos := center + Vector2(0.0, 60.0)
		var motion := InputEventMouseMotion.new()
		motion.position = drag_pos
		motion.relative = Vector2(0.0, 60.0)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		viewport.push_input(motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = drag_pos
		viewport.push_input(release)
		mouse_end = drag(drag_pos, start.plane).target
	)

	step("Then the cells between press and release are all painted", func():
		var frame: VoxelFrame = State.document.frames[0]
		var path := StrokeLine.cells(pressed, mouse_end)
		expect(frame.cells.has(pressed), "the pressed cell is painted")
		expect(frame.cells.has(mouse_end), "the cell under the mouse is painted")
		expect(path.size() >= 3, "the stroke spans several cells")
		for c in path:
			expect(frame.cells.has(c), "every cell along the stroke is painted")
	)
