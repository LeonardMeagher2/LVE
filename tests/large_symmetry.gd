extends "res://tests/test.gd"

var viewport: SubViewport
var brush: Node
var frame: VoxelFrame


func _ready() -> void:
	timeout = 30.0
	test("large mirrored brush edits use a stable settings snapshot and cancel across frame changes", _run)


func _run() -> void:
	step("Given a volume brush and all three symmetry planes", func():
		viewport = editor_viewport()
		viewport.get_parent().stretch = false
		viewport.size = Vector2i(800, 500)
		brush = plugin("BrushPlugin")
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		State.symmetry_axes = 7
		State.symmetry_origin = Vector3.ZERO
		State.floor_axis = Vector3.Axis.AXIS_Y
		State.floor_index = 10
		select_toolbar_item("Toolbar", "Pencil")
		brush._settings.shape = brush._settings.BrushShape.CUBE
		brush._settings.diameter = 16
		brush._settings.pixel_perfect = false
		State.set_color(Color.BLUE)
		State.undo_redo.clear_history()
		camera_rig().is_orthogonal = true
		camera_rig().set_view("top")
		camera_rig().center_on(AABB(Vector3(-20, -20, -20), Vector3(40, 40, 40)))
	)
	step("When the user paints and changes the symmetry settings during worker processing", func():
		_click()
		expect(State.edit_busy(), "the expanded volume brush runs as foreground worker work")
		State.symmetry_axes = 0
		State.symmetry_origin = Vector3.ONE * 100
	)
	await _settle()
	step("Then the edit uses the captured origin and enabled planes", func():
		expect(frame.count() == 32768, "the original cube and seven disjoint reflections are painted")
		for x in [-10, 10]:
			for y in [-10, 10]:
				for z in [-10, 10]:
					expect(frame.get_color(Vector3i(x, y, z)) == Color.BLUE, "each reflected cube contains the original brush color")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes all eight cubes")
		expect(not State.undo_redo.has_undo(), "the worker stroke creates one undo action")
		State.undo_redo.redo()
		expect(frame.count() == 32768, "redo restores all eight cubes without mirroring them again")
	)
	step("When the user changes frames during another mirrored worker stroke", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		State.symmetry_axes = 7
		State.symmetry_origin = Vector3.ZERO
		_click()
		expect(State.edit_busy(), "the second mirrored stroke starts worker processing")
		State.add_frame()
	)
	while brush._brush_tool._job != null:
		await get_tree().process_frame
	step("Then the cancelled worker leaves both frames unchanged", func():
		expect(frame.count() == 0, "the original frame retains no cancelled stroke voxels")
		expect(State.get_current_voxel_frame().count() == 0, "the new frame retains no cancelled stroke voxels")
		expect(not State.edit_busy(), "the cancelled mirrored stroke releases editing")
	)
	State.symmetry_axes = 0
	State.symmetry_origin = Vector3.ZERO
	State.floor_index = 0


func _click() -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = camera_rig().unproject_position(Vector3(10, 9.5, 10))
		viewport.push_input(event)


func _settle() -> void:
	while State.edit_busy() or brush._brush_tool._stroke_open:
		await get_tree().process_frame
	await get_tree().process_frame
