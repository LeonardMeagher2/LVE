extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var top: PickResult
var bottom: PickResult
var before: Array[Vector3i] = []
var last_drag := Vector2.ZERO


func _ready() -> void:
	test("the drawing plane follows the view direction, not the click position", _run)


func _run() -> void:
	step("Given the editor viewport at its default view", func():
		viewport = editor_viewport()
		var vsize: Vector2i = viewport.size
		if vsize.x <= 0 or vsize.y <= 0:
			viewport.size = Vector2i(800, 500)
			vsize = viewport.size
		center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
	)

	step("When the user aims at the top and bottom of the viewport", func():
		top = aim(Vector2(center.x, 60.0))
		bottom = aim(Vector2(center.x, float(viewport.size.y) - 60.0))
	)

	step("Then both aims get the same plane axis", func():
		expect(top.plane != null, "the top aim has a plane")
		expect(bottom.plane != null, "the bottom aim has a plane")
		expect(top.plane.axis == bottom.plane.axis, "the plane axis is the same at top and bottom")
	)

	step("Given a voxel above the floor at the center aim", func():
		State.document.set_cell(0, Vector3i(-3, 3, 0), State.current_color)
		sync_viewport()
	)

	step("When the user presses the voxel and drags down", func():
		before = State.document.frames[0].positions()
		_press(center)
		_drag_to(center + Vector2(0.0, 40.0))
		_drag_to(center + Vector2(0.0, 80.0))
		_drag_to(center + Vector2(0.0, 120.0))
		_release()
	)

	step("Then the stroke stays on one plane", func():
		var frame: VoxelFrame = State.document.frames[0]
		var drawn := 0
		var layer := -1
		var same := true
		for c in frame.positions():
			if before.has(c):
				continue
			drawn += 1
			if layer == -1:
				layer = c.y
			elif c.y != layer:
				same = false
		expect(drawn > 1, "the drag painted a stroke")
		expect(same, "every painted cell is on the same layer")
	)


func _press(pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	viewport.push_input(press)


func _drag_to(pos: Vector2) -> void:
	last_drag = pos
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.relative = Vector2.ZERO
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(motion)


func _release() -> void:
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = last_drag
	viewport.push_input(release)
