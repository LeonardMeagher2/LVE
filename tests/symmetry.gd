extends "res://tests/test.gd"

var viewport: SubViewport
var symmetry: Node
var brush: Node
var settings: Resource
var frame: VoxelFrame


func _ready() -> void:
	test("symmetry planes share an adjustable origin and mirror drawing edits with one undo action", _run)


func _run() -> void:
	step("Given the Symmetry tool with all planes disabled", func():
		viewport = editor_viewport()
		viewport.get_parent().stretch = false
		viewport.size = Vector2i(800, 500)
		symmetry = plugin("SymmetryPlugin")
		expect(State.symmetry_origin == Vector3(-0.5, -0.5, -0.5), "the default origin places all planes between voxel cells")
		brush = plugin("BrushPlugin")
		settings = brush._settings
		State.document = VoxelDocument.new()
		State.symmetry_axes = 0
		State.symmetry_origin = Vector3.ZERO
		activate_tool("Symmetry")
		camera_rig().is_orthogonal = true
		camera_rig().set_view("front")
		camera_rig().center_on(AABB(Vector3(-10, -10, -1), Vector3(20, 20, 2)))
	)
	step("When the user enables the three cardinal symmetry planes", func():
		for axis in ["X", "Y", "Z"]:
			symmetry._options.get_node(axis).button_pressed = true
	)
	step("Then each plane stays enabled independently", func():
		expect(State.symmetry_axes == 7, "all three symmetry axes are enabled")
		for plane_name in ["XPlane", "YPlane", "ZPlane"]:
			expect(symmetry._tool.get_node(plane_name).visible, "the enabled symmetry plane is visible")
	)
	step("When the user drags the symmetry origin", func():
		_button(Vector3.ZERO, true)
		var motion := InputEventMouseMotion.new()
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.position = camera_rig().unproject_position(Vector3(2, 1, 0))
		viewport.push_input(motion)
		_button(Vector3(2, 1, 0), false)
	)
	step("Then the origin and coordinate controls follow the drag", func():
		expect(State.symmetry_origin == Vector3(2, 1, 0), "the dragged origin moves in the view plane")
		expect(symmetry._options.get_node("OriginX").value == 2.0, "the X origin control follows the drag")
		expect(symmetry._options.get_node("OriginY").value == 1.0, "the Y origin control follows the drag")
		expect(not State.undo_redo.has_undo(), "origin setup adds no document undo action")
	)
	step("When the user presses far from the origin and presses Escape", func():
		_button(Vector3(6, 5, 0), true)
		expect(State.symmetry_origin == Vector3(2, 1, 0), "pressing elsewhere keeps the origin in place")
		var event := InputEventKey.new()
		event.keycode = KEY_ESCAPE
		event.pressed = true
		viewport.push_input(event)
		expect(State.symmetry_origin == Vector3(2, 1, 0), "Escape keeps the origin in place")
		var motion := InputEventMouseMotion.new()
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.position = camera_rig().unproject_position(Vector3(7, 7, 0))
		viewport.push_input(motion)
		_button(Vector3(7, 7, 0), false)
	)
	step("Then dragging uses the pointer offset and continues after Escape", func():
		expect(State.symmetry_origin == Vector3(3, 3, 0), "the origin follows the drag offset without jumping to the pointer")
	)
	step("When the user drags the origin in an angled top-facing view", func():
		camera_rig().set_view("isometric")
		State.symmetry_origin = Vector3(0, 1.5, 0)
		_button(Vector3(5, 1.5, 5), true)
		var motion := InputEventMouseMotion.new()
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.position = camera_rig().unproject_position(Vector3(6, 1.5, 7))
		viewport.push_input(motion)
		_button(Vector3(6, 1.5, 7), false)
	)
	step("Then the drag stays on the same view-facing voxel plane", func():
		expect(State.symmetry_origin == Vector3(1, 1.5, 2), "the angled drag changes X and Z while preserving the Y offset")
	)
	step("When the user sets a half-voxel origin and disables two planes", func():
		symmetry._options.get_node("OriginX").value = 0.5
		symmetry._options.get_node("Y").button_pressed = false
		symmetry._options.get_node("Z").button_pressed = false
		symmetry._options.get_node("OriginY").value = 0.0
		symmetry._options.get_node("OriginZ").value = 0.0
		select_toolbar_item("Toolbar", "Pencil")
		settings.shape = settings.BrushShape.CUBE
		settings.diameter = 1
		settings.pixel_perfect = false
		camera_rig().set_view("top")
		State.set_color(Color.RED)
		State.undo_redo.clear_history()
	)
	step("Then symmetry stays enabled while the Pencil tool is active", func():
		expect(State.symmetry_axes == 1 and State.symmetry_origin.x == 0.5, "the X mirror plane stays between voxel cells")
		expect(symmetry._tool.get_node("XPlane").visible, "the mirror plane stays visible during drawing")
		expect(not symmetry._tool.get_node("Origin").visible, "the origin handle is hidden while drawing")
	)
	step("When the user paints one voxel beside the mirror plane", func():
		_click(Vector3(2, -0.5, 3))
	)
	await _settle()
	step("Then the original and reflected voxels form one edit", func():
		frame = State.get_current_voxel_frame()
		expect(frame.count() == 2, "the stroke creates two voxels")
		expect(frame.get_color(Vector3i(2, 0, 3)) == Color.RED, "the original voxel has the brush color")
		expect(frame.get_color(Vector3i(-1, 0, 3)) == Color.RED, "the mirrored voxel uses the moved origin")
		var cursor: MeshInstance3D = brush._brush_tool.get_node("Cursor")
		var mirror: MeshInstance3D = cursor.get_node("Mirror1")
		expect(mirror.visible and mirror.mesh == cursor.mesh, "the mirrored cursor reuses the original preview mesh")
		expect(mirror.global_position == Vector3(-1, 0, 3), "the mirrored cursor follows the symmetry origin")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes both voxels")
		expect(not State.undo_redo.has_undo(), "the mirrored stroke adds only one undo action")
		State.undo_redo.redo()
		expect(frame.count() == 2, "redo restores both voxels")
	)
	step("When the user recolors and erases the mirrored voxels", func():
		select_toolbar_item("Toolbar", "Paint")
		State.set_color(Color.BLUE)
		_click(Vector3(2, 0.5, 3))
		expect(frame.count() == 2 and frame.get_color(Vector3i(-1, 0, 3)) == Color.BLUE, "Paint recolors existing mirrored voxels")
		select_toolbar_item("Toolbar", "Eraser")
		_click(Vector3(2, 0.5, 3))
	)
	await _settle()
	step("Then Eraser removes both existing voxels", func():
		expect(frame.count() == 0, "Eraser removes the original and mirrored voxels")
	)
	step("Given two symmetry axes and a selected drawing region", func():
		State.document = VoxelDocument.new()
		State.symmetry_origin = Vector3.ZERO
		State.symmetry_axes = 5
		State.selection.add(Vector3i(2, 0, 3))
		State.selection.add(Vector3i(-2, 0, 3))
		State.selection_changed.emit()
		State.begin_stroke()
		State.paint(Vector3i(2, 0, 3), Color.GREEN)
		State.end_stroke()
	)
	step("Then State applies symmetry within the selection", func():
		frame = State.get_current_voxel_frame()
		expect(frame.count() == 2, "the selection keeps only the allowed reflections")
		expect(not frame.has(Vector3i(2, 0, -3)), "the excluded reflected position stays empty")
		frame.set_cell(Vector3i(8, 0, 8), Color.YELLOW)
		expect(not frame.has(Vector3i(-8, 0, -8)), "raw frame storage writes only the requested voxel")
	)
	step("Given all three axes and a voxel on the symmetry origin", func():
		State.document = VoxelDocument.new()
		State.symmetry_axes = 7
		State.begin_stroke()
		State.paint(Vector3i.ZERO, Color.RED)
		State.end_stroke()
	)
	step("Then coincident reflections create one voxel", func():
		expect(State.get_current_voxel_frame().count() == 1, "reflection duplicates on the origin are removed")
	)
	step("Given an asymmetric colored voxel brush", func():
		State.document = VoxelDocument.new()
		State.symmetry_axes = 1
		settings.use_selection({Vector3i(-1, 0, 0): Color.RED, Vector3i(1, 0, 0): Color.BLUE})
		select_toolbar_item("Toolbar", "Pencil")
		_click(Vector3(0, -0.5, 0))
	)
	await _settle()
	step("Then overlapping reflections preserve the original source colors", func():
		frame = State.get_current_voxel_frame()
		expect(frame.count() == 2, "the overlapping brush creates two unique voxels")
		expect(frame.get_color(Vector3i.LEFT) == Color.RED and frame.get_color(Vector3i.RIGHT) == Color.BLUE, "the original colored pattern wins at overlapping positions")
	)
	step("Given the Line tool and a symmetric drawing plane", func():
		State.document = VoxelDocument.new()
		settings.shape = settings.BrushShape.CUBE
		settings.diameter = 1
		State.symmetry_axes = 1
		select_toolbar_item("Toolbar", "Line")
		_click(Vector3(2, -0.5, 2))
		_click(Vector3(2, -0.5, 4))
	)
	await _settle()
	step("Then the line and its reflection commit together", func():
		frame = State.get_current_voxel_frame()
		expect(frame.count() == 6, "the Line tool creates two three-voxel lines")
		expect(frame.has(Vector3i(-2, 0, 3)), "the Line tool includes the reflected midpoint")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes both lines")
	)
	step("Given two matching regions for Fill", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cells({Vector3i(2, 0, 2): Color.RED, Vector3i(2, 0, 3): Color.RED, Vector3i(-2, 0, 2): Color.RED, Vector3i(-2, 0, 3): Color.GREEN})
		activate_tool("fill")
		State.set_color(Color.BLUE)
		State.undo_redo.clear_history()
		_click(Vector3(2, 0.5, 2))
	)
	await _settle()
	step("Then Fill mirrors recoloring without adding cells or replacing different colors", func():
		expect(frame.count() == 4, "Fill preserves the number of existing voxels")
		expect(frame.get_color(Vector3i(-2, 0, 2)) == Color.BLUE, "Fill recolors the matching reflected voxel")
		expect(frame.get_color(Vector3i(-2, 0, 3)) == Color.GREEN, "Fill preserves a different reflected color")
		State.undo_redo.undo()
		expect(frame.get_color(Vector3i(-2, 0, 2)) == Color.RED, "one undo restores the reflected fill color")
	)
	State.symmetry_axes = 0
	step("When the user resets the symmetry origin", func():
		symmetry._options.get_node("Reset").pressed.emit()
	)
	step("Then the origin returns to the default voxel boundary", func():
		expect(State.symmetry_origin == Vector3(-0.5, -0.5, -0.5), "Reset restores the default half-voxel origin")
	)


func _button(world: Vector3, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = camera_rig().unproject_position(world)
	viewport.push_input(event)


func _click(world: Vector3) -> void:
	_button(world, true)
	_button(world, false)


func _settle() -> void:
	while State.edit_busy() or brush._brush_tool._stroke_open or brush._line_tool._job != null or brush._line_tool._preview_requested:
		await get_tree().process_frame
	await get_tree().process_frame
