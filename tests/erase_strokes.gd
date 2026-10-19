extends "res://tests/test.gd"

# One process runs the eraser tests. Each test keeps the steps and checks of its
# original scene. The user arguments after `--` name the tests to run, so an old
# scene name still selects its own test.

var viewport: SubViewport
var center := Vector2.ZERO
var c0 := VoxelPicking.NONE
var c1 := VoxelPicking.NONE
var c_mid := VoxelPicking.NONE


func _ready() -> void:
	test("can erase a stroke of voxels with a drag", _erase_drag, "erase_drag")
	test("the eraser highlight is always visible", _erase_hover, "erase_hover")
	test("the eraser highlight follows the voxel being erased", _erase_drag_visual, "erase_drag_visual")


# Each test starts from a fresh document. Every test selects the eraser itself.
func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()


# Shared viewport setup. Every test uses the same view and center.
func _view_setup() -> void:
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	center = Vector2(400.0, 250.0)


# Shared input helpers. Every test drives the real viewport input path.
func _press(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	viewport.push_input(event)


func _release(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = pos
	viewport.push_input(event)


func _motion(pos: Vector2, relative: Vector2, pressed := true) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(event)


func _erase_drag() -> void:
	step("Given a row of voxels under the drag path", func():
		_view_setup()
		select_toolbar_item("Toolbar", "Eraser")
		var start := aim(center)
		c0 = start.target
		c1 = drag(center + Vector2(0.0, -20.0), start.plane).target
		State.document.set_cell(0, c0, VoxelFrame.material(State.current_color))
		State.document.set_cell(0, c1, VoxelFrame.material(State.current_color))
		sync_viewport()
	)

	step("When the user presses on the wall face and drags up", func():
		_press(center)
		var drag_pos := center + Vector2(0.0, -20.0)
		_motion(drag_pos, Vector2(0.0, -20.0))
		_release(drag_pos)
	)

	step("Then the voxels under the drag are erased", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(not frame.has(c0), "pressed voxel is erased")
		expect(not frame.has(c1), "dragged voxel is erased")
	)

	step("Then the whole stroke can be undone", func():
		State.undo_redo.undo()
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.has(c0), "pressed voxel returns after undo")
		expect(frame.has(c1), "dragged voxel returns after undo")
	)


func _erase_hover() -> void:
	step("Given an eraser on an empty grid", func():
		_view_setup()
		select_toolbar_item("Toolbar", "Eraser")
	)

	step("When the user hovers the empty grid", func():
		_motion(center, Vector2.ZERO, false)
	)

	step("Then the highlight is visible at the cursor cell", func():
		var v: Node3D = active_tool_node("BrushPlugin")
		var req := pick_request(center)
		var target := VoxelPicking.start_pick(req.origin, req.dir, req.frame, req.forward).target
		expect(v.visible, "the highlight is visible")
		expect(v.get_node("Cursor").mesh.surface_get_primitive_type(0) == Mesh.PRIMITIVE_LINES, "the eraser preview uses an outline mesh")
		expect(v.position == Vector3(target), "the highlight is at the cursor cell")
	)


func _erase_drag_visual() -> void:
	step("Given an eraser and a row of voxels under the drag path", func():
		_view_setup()
		select_toolbar_item("Toolbar", "Eraser")
		var start := aim(center)
		c0 = start.target
		c_mid = drag(center + Vector2(0.0, 20.0), start.plane).target
		State.document.set_cell(0, c0, VoxelFrame.material(State.current_color))
		State.document.set_cell(0, c_mid, VoxelFrame.material(State.current_color))
		sync_viewport()
	)

	step("When the user presses the wall and drags onto the lower voxel", func():
		_press(center)
		var mid := center + Vector2(0.0, 20.0)
		_motion(mid, Vector2(0.0, 20.0))
	)

	step("Then the highlight is on the voxel being erased", func():
		var v: Node3D = active_tool_node("BrushPlugin")
		expect(v.visible, "the highlight is visible")
		expect(v.position == Vector3(c_mid), "the highlight is on the voxel being erased")
	)

	step("When the user drags below the wall", func():
		var low := center + Vector2(0.0, 50.0)
		_motion(low, Vector2(0.0, 30.0))
	)

	step("Then the highlight stays visible", func():
		var v: Node3D = active_tool_node("BrushPlugin")
		expect(v.visible, "the highlight is still visible")
	)

	step("When the user releases the drag", func():
		_release(center + Vector2(0.0, 50.0))
	)
