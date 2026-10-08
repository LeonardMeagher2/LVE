extends "res://tests/test.gd"

var viewport: SubViewport
var options: Control
var tool: Node3D


func _ready() -> void:
	test("the line tool previews two-click and drag strokes with shared brush shapes", _run)


func _run() -> void:
	step("Given a three-voxel brush and the line tool", func():
		viewport = editor_viewport()
		viewport.get_parent().stretch = false
		viewport.size = Vector2i(800, 500)
		plugin("BrushPlugin")._options.get_node("Diameter").value = 3
		select_toolbar_item("Toolbar", "Line")
		tool = plugin("BrushPlugin")._tool
		options = plugin("BrushPlugin")._options
		_empty()
		expect(options.get_node("Diameter").value == 3, "the line tool retains the paint brush diameter")
		expect(not options.get_node("PixelPerfect").visible, "the line options show only the line brush controls")
	)
	step("When the user clicks the start and moves the endpoint twice", func():
		_click(Vector3.ZERO)
		_motion(Vector3(6, 0, 0))
		_motion(Vector3(0, 0, 4))
	)
	while not tool.get_node("Cursor").is_settled():
		await get_tree().process_frame
	step("Then the current line is visible without changing the document", func():
		expect(State.get_current_voxel_frame().count() == 0, "the preview leaves the document empty")
		expect(not State.undo_redo.has_undo(), "the preview adds no undo action")
		expect(tool.visible, "the line preview is visible")
		expect(tool.get_node("Cursor").mesh.surface_get_primitive_type(0) == Mesh.PRIMITIVE_TRIANGLES, "the line preview uses solid faces")
		expect(tool.get_node("Cursor").mesh.get_aabb().size == Vector3(3, 3, 7), "the preview follows the latest endpoint and brush volume")
	)
	step("When the user clicks the second endpoint", func():
		_click(Vector3(0, 0, 4))
	)
	step("Then the complete line is one undo operation", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 63, "the line contains sixty-three voxels")
		expect(frame.has(Vector3i(-1, -1, -1)) and frame.has(Vector3i(1, 1, 5)), "the line includes both cube brush caps")
		expect(not frame.has(Vector3i(6, 0, 0)), "the previous endpoint leaves no voxels")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes the complete line")
		expect(not State.undo_redo.has_undo(), "the line creates exactly one undo action")
		State.undo_redo.redo()
		expect(frame.count() == 63, "one redo restores the complete line")
	)
	step("When the user drags a thin diagonal line", func():
		_empty()
		options.get_node("Diameter").value = 1
		_button(Vector3.ZERO, true)
		_motion(Vector3(4, 0, 4), true)
		expect(State.get_current_voxel_frame().count() == 0, "the drag remains a preview before release")
		_button(Vector3(4, 0, 4), false)
	)
	step("Then releasing the mouse commits a connected diagonal", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 5, "the diagonal contains five voxels")
		var connected := true
		for offset in 5:
			connected = connected and frame.has(Vector3i(offset, 0, offset))
		expect(connected, "the diagonal contains each cell between its endpoints")
	)
	step("Given a voxel above the floor and a thin line brush", func():
		_empty()
		State.get_current_voxel_frame().set_cell(Vector3i(4, 3, 0), Color.BLUE)
	)
	step("When the user clicks the floor and previews an elevated hit", func():
		_click(Vector3.ZERO)
		_motion(Vector3(4, 3, 0))
	)
	while not tool.get_node("Cursor").is_settled():
		await get_tree().process_frame
	step("Then the preview connects the floor to the elevated surface", func():
		expect(State.get_current_voxel_frame().count() == 1, "the preview preserves the source voxel")
		expect(tool.get_node("Cursor").mesh.get_aabb().size == Vector3(5, 5, 1), "the two-click preview spans both endpoint heights")
	)
	step("When the user clicks the elevated hit", func():
		_click(Vector3(4, 3, 0))
	)
	step("Then the line follows both hits without a plane restriction", func():
		var frame := State.get_current_voxel_frame()
		var connected := true
		for offset in 5:
			connected = connected and frame.has(Vector3i(offset, offset, 0))
		expect(connected, "the line connects the floor to the elevated surface")
		expect(frame.count() == 6, "the line adds five voxels beside the source voxel")
		State.undo_redo.undo()
		expect(frame.count() == 1 and frame.has(Vector3i(4, 3, 0)), "one undo retains the source voxel")
	)
	step("When the user drags from the floor across the elevated hit", func():
		_button(Vector3.ZERO, true)
		_motion(Vector3(4, 3, 0), true)
		_button(Vector3(4, 3, 0), false)
	)
	step("Then the dragged line stays on the starting plane", func():
		var frame := State.get_current_voxel_frame()
		var connected := true
		for offset in 5:
			connected = connected and frame.has(Vector3i(offset, 0, 0))
		expect(connected, "the dragged line connects five floor cells")
		expect(not frame.has(Vector3i(4, 4, 0)), "the elevated surface has no line endpoint")
		expect(frame.count() == 6, "the dragged line preserves the source voxel")
	)
	step("Given two voxels at different heights", func():
		_empty()
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i(0, 3, 0), Color.BLUE)
		frame.set_cell(Vector3i(4, 0, 0), Color.BLUE)
	)
	step("When the user starts above the floor and previews empty space", func():
		_click(Vector3(0, 3, 0))
		_motion(Vector3(8, 0, 0))
	)
	while not tool.get_node("Cursor").is_settled():
		await get_tree().process_frame
	step("Then the empty-space preview stays on the starting plane", func():
		var bounds: AABB = tool.get_node("Cursor").mesh.get_aabb()
		expect(bounds.position.y == 3.5 and bounds.size.y == 1.0, "the preview stays at the starting height")
	)
	step("When the user clicks that empty space", func():
		_click(Vector3(8, 0, 0))
	)
	step("Then the line ends on the starting plane", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.has(Vector3i(8, 4, 0)), "the empty-space endpoint uses the starting plane")
		expect(not frame.has(Vector3i(8, 0, 0)), "the floor remains empty below the endpoint")
		State.undo_redo.undo()
	)
	step("When the user starts again and clicks the lower voxel", func():
		_click(Vector3(0, 3, 0))
		_motion(Vector3(4, 0, 0))
		_click(Vector3(4, 0, 0))
	)
	step("Then the voxel hit moves the endpoint off the starting plane", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.has(Vector3i(0, 4, 0)) and frame.has(Vector3i(4, 1, 0)), "the line connects both voxel surfaces")
		expect(not frame.has(Vector3i(4, 4, 0)), "the endpoint follows the lower voxel surface")
	)
	step("Given a pending line in the top view", func():
		_empty()
		_click(Vector3.ZERO)
	)
	step("When the user changes to the front view and moves the endpoint", func():
		camera_rig().set_view("front")
		_motion(Vector3(4, 3, 0))
	)
	while not tool.get_node("Cursor").is_settled():
		await get_tree().process_frame
	step("Then the preview follows the front-view plane through the start", func():
		expect(tool.get_node("Cursor").mesh.get_aabb().size == Vector3(5, 4, 1), "the front-view preview spans width and height")
		expect(State.get_current_voxel_frame().count() == 0, "the view change leaves the line pending")
	)
	step("When the user changes to the side view and moves the endpoint", func():
		camera_rig().set_view("right")
		_motion(Vector3(0, 3, 4))
	)
	while not tool.get_node("Cursor").is_settled():
		await get_tree().process_frame
	step("Then the preview follows the side-view plane through the start", func():
		expect(tool.get_node("Cursor").mesh.get_aabb().size == Vector3(1, 4, 5), "the side-view preview spans height and depth")
	)
	step("When the user clicks the endpoint in the side view", func():
		_click(Vector3(0, 3, 4))
	)
	step("Then the line retains its start and uses the current view plane", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.has(Vector3i.ZERO) and frame.has(Vector3i(0, 3, 4)), "the line connects the original start to the side-view endpoint")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes the line after the view changes")
	)
	step("Given a voxel viewed from an angle", func():
		_empty()
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, Color.BLUE)
		camera_rig().set_view("isometric")
	)
	step("When the user clicks and releases on the voxel", func():
		_click(Vector3.ZERO)
	)
	step("Then the first click leaves the line pending", func():
		expect(State.get_current_voxel_frame().count() == 1, "the first click preserves the document")
		expect(not State.undo_redo.has_undo(), "the first click adds no undo action")
		expect(tool.visible, "the first click shows the pending endpoint")
	)
	step("When the user clicks a second endpoint", func():
		_motion(Vector3(4, 0, 0))
		_click(Vector3(4, 0, 0))
	)
	step("Then the second click commits one line", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() > 1, "the second click adds the line voxels")
		State.undo_redo.undo()
		expect(frame.count() == 1 and frame.has(Vector3i.ZERO), "one undo retains the source voxel")
		expect(not State.undo_redo.has_undo(), "the two clicks create one undo action")
	)
	step("When the user draws a line with a sphere brush", func():
		_empty()
		options.get_node("Diameter").value = 3
		options.get_node("Shape/Sphere").pressed.emit()
		_click(Vector3.ZERO)
		_motion(Vector3(4, 0, 0))
		_click(Vector3(4, 0, 0))
	)
	step("Then the line has rounded caps and depth", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 55, "the sphere stroke contains fifty-five voxels")
		expect(frame.has(Vector3i(-1, 0, 0)) and frame.has(Vector3i(5, 0, 0)), "the sphere stroke includes both rounded caps")
		expect(frame.has(Vector3i(2, 1, 0)), "the sphere stroke has vertical depth")
		expect(not frame.has(Vector3i(-1, 1, 1)), "the cube cap corner stays empty")
	)
	step("When the user cancels a pending line with Escape", func():
		_empty()
		_click(Vector3.ZERO)
		_motion(Vector3(3, 0, 0))
		_key(KEY_ESCAPE)
	)
	step("Then cancellation leaves no edit or undo action", func():
		expect(State.get_current_voxel_frame().count() == 0, "the cancelled line leaves the document empty")
		expect(not State.undo_redo.has_undo(), "the cancelled line adds no history action")
		expect(not tool.visible, "the cancelled preview is hidden")
	)
	step("When the user switches tools during a line preview", func():
		_click(Vector3.ZERO)
		_motion(Vector3(3, 0, 0))
		select_toolbar_item("Toolbar", "Pencil")
	)
	step("Then switching tools discards the preview and shares the current size", func():
		expect(State.get_current_voxel_frame().count() == 0, "tool switching leaves the line uncommitted")
		expect(plugin("BrushPlugin")._options.get_node("Diameter").value == 3, "the paint tool retains the line brush diameter")
		select_toolbar_item("Toolbar", "Line")
	)
	step("Given a selection that crosses only part of the line", func():
		_empty()
		options.get_node("Diameter").value = 1
		State.selection.from_box(Vector3i(1, 0, 0), Vector3i(3, 0, 0))
		State.selection_changed.emit()
	)
	step("When the user draws across the selection boundary", func():
		_click(Vector3.ZERO)
		_motion(Vector3(5, 0, 0))
		_click(Vector3(5, 0, 0))
	)
	step("Then the line edits only selected cells", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 3, "the line contains only three selected cells")
		expect(frame.has(Vector3i(1, 0, 0)) and frame.has(Vector3i(3, 0, 0)), "the selected endpoints are painted")
		expect(not frame.has(Vector3i.ZERO) and not frame.has(Vector3i(5, 0, 0)), "the unselected endpoints stay empty")
	)
	step("Given a copied brush with two colors", func():
		_empty()
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i(8, 0, 8), Color.RED)
		frame.set_cell(Vector3i(8, 0, 9), Color.BLUE)
		State.selection.from_box(Vector3i(8, 0, 8), Vector3i(8, 0, 9))
		State.selection_changed.emit()
		options.get_node("Shape/Selection").pressed.emit()
		State.clear_selection()
		frame.clear()
		State.current_color = Color.GREEN
	)
	step("When the user draws a line with the copied brush", func():
		_click(Vector3.ZERO)
		_motion(Vector3(4, 0, 0))
		_click(Vector3(4, 0, 0))
	)
	step("Then each stamp retains its source colors", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 10, "the copied brush paints two rows of five voxels")
		var colors_preserved := true
		for offset in 5:
			colors_preserved = colors_preserved and frame.get_color(Vector3i(offset, 0, 0)) == Color.RED
			colors_preserved = colors_preserved and frame.get_color(Vector3i(offset, 0, 1)) == Color.BLUE
		expect(colors_preserved, "the copied line keeps both source colors")
	)


func _empty() -> void:
	State.document = VoxelDocument.new()
	State.floor_axis = Vector3.Axis.AXIS_Y
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true
	State.current_color = Color.RED


func _button(world: Vector3, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = camera_rig().unproject_position(world)
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(event)


func _click(world: Vector3) -> void:
	_button(world, true)
	_button(world, false)


func _motion(world: Vector3, pressed := false) -> void:
	var event := InputEventMouseMotion.new()
	event.position = camera_rig().unproject_position(world)
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(event)


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	viewport.push_input(event)
