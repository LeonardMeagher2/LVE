extends "res://tests/test.gd"

var viewport: SubViewport
var options: Control
var tool: Node3D
var target := Vector3i.ZERO
var axis := 1


func _ready() -> void:
	test("cube and sphere brushes paint volumes and retain copied colors", _run)


func _run() -> void:
	step("Given a cube brush with a diameter of three", func():
		viewport = editor_viewport()
		viewport.get_parent().stretch = false
		viewport.size = Vector2i(800, 500)
		activate_tool("Toolbar")
		options = plugin("BrushPlugin")._options
		tool = plugin("BrushPlugin")._tool
		options.get_node("Diameter").value = 3
		State.current_color = Color.RED
		for shape_name in ["Cube", "Sphere", "Selection"]:
			var button := options.get_node("Shape/" + shape_name)
			expect(button.text.is_empty() and button.icon != null, "the %s shape uses an icon" % shape_name)
		expect(options.get_node("Shape/Cube").button_pressed, "the cube shape is active by default")
		expect(options.get_node("Shape/Selection").disabled, "the voxel shape needs source voxels")
		expect(options.get_node("Shape/Selection").icon == load("res://icons/select.svg"), "the voxel shape uses the selection icon")
		expect(options.get_node("ShapeSeparator") is VSeparator, "a separator follows the shape controls")
	)
	await get_tree().process_frame
	for view in ["right", "top", "front"]:
		step("When the user paints a cube in the %s view" % view, func():
			_empty(view)
			axis = {"right": 0, "top": 1, "front": 2}[view]
			var pick := aim(_position(Vector3.ZERO))
			target = pick.target
			var hover := InputEventMouseMotion.new()
			hover.position = _position(Vector3.ZERO)
			viewport.push_input(hover)
			expect(tool.visible, "the brush preview is visible")
			expect(tool.get_node("Cursor").mesh is BoxMesh, "the cube brush preview uses solid faces")
			expect(tool.get_node("Cursor").mesh.get_aabb().size.is_equal_approx(Vector3.ONE * 3), "the preview has the brush width on all three axes")
			_click(_position(Vector3.ZERO))
		)
		step("Then one cube stroke paints twenty-seven voxels and supports undo", func():
			var frame := State.get_current_voxel_frame()
			expect(frame.count() == 27, "the cube contains twenty-seven voxels")
			var colors_preserved := true
			for cell in frame.positions():
				colors_preserved = colors_preserved and frame.get_color(cell) == Color.RED
			expect(colors_preserved, "the cube uses the brush color")
			var depth_offset := Vector3i.ZERO
			depth_offset[axis] = 1
			expect(frame.has(target + depth_offset) and frame.has(target - depth_offset), "the cube extends on both sides of the drawing plane")
			State.undo_redo.undo()
			expect(frame.count() == 0, "one undo removes the complete cube")
			State.undo_redo.redo()
			expect(frame.count() == 27, "one redo restores the complete cube")
		)
	await get_tree().process_frame
	step("When the user selects a sphere with a diameter of five", func():
		_empty("top")
		options.get_node("Diameter").value = 5
		_click_shape("Sphere")
		expect(options.get_node("Shape/Sphere").button_pressed, "the sphere shape button is active")
		expect(not options.get_node("Shape/Cube").button_pressed, "the cube shape button is inactive")
		_click_shape("Sphere")
		expect(options.get_node("Shape/Sphere").button_pressed, "clicking the active shape keeps it selected")
		target = aim(_position(Vector3.ZERO)).target
		_click(_position(Vector3.ZERO))
	)
	step("Then the sphere has a filled center and rounded corners in three dimensions", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 81, "the sphere contains eighty-one voxels")
		expect(frame.has(target), "the sphere contains its center")
		expect(frame.has(target + Vector3i(2, 0, 0)), "the sphere reaches its horizontal edge")
		expect(frame.has(target + Vector3i(0, 2, 0)), "the sphere reaches its vertical edge")
		expect(not frame.has(target + Vector3i(2, 2, 2)), "the cube corner stays empty")
	)
	await get_tree().process_frame
	step("When the user sets the diameter below its minimum", func():
		_empty("top")
		_click_shape("Cube")
		options.get_node("Diameter").value = 0
		target = aim(_position(Vector3.ZERO)).target
		_click(_position(Vector3.ZERO))
	)
	step("Then diameter one paints a single voxel", func():
		var frame := State.get_current_voxel_frame()
		expect(options.get_node("Diameter").value == 1, "the minimum brush diameter is one")
		expect(frame.count() == 1, "the minimum cube contains one voxel")
		expect(frame.has(target), "the minimum cube contains the cursor cell")
	)
	await get_tree().process_frame
	step("When the user paints with the minimum sphere diameter", func():
		_empty("top")
		_click_shape("Sphere")
		_click(_position(Vector3.ZERO))
	)
	step("Then the minimum sphere also paints one voxel", func():
		expect(State.get_current_voxel_frame().count() == 1, "the minimum sphere contains one voxel")
	)
	await get_tree().process_frame
	step("When the user paints with a cube diameter of two", func():
		_empty("top")
		_click_shape("Cube")
		options.get_node("Diameter").value = 2
		_click(_position(Vector3.ZERO))
	)
	step("Then the even diameter paints the exact voxel width", func():
		expect(State.get_current_voxel_frame().count() == 8, "the even cube contains eight voxels")
		expect(State.get_current_voxel_frame().get_bounds().size == Vector3.ONE * 2, "the cube is two voxels wide on each axis")
		expect(tool.get_node("Cursor").mesh.get_aabb().size == Vector3.ONE * 2, "the solid cursor has the exact even diameter")
		expect(tool.get_node("Cursor").position == Vector3.ONE * -0.5, "the even cursor aligns with the stamped voxels")
	)
	await get_tree().process_frame
	step("Given a selection with three voxels and two colors", func():
		_empty("top")
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i(10, 0, 10), VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i(11, 0, 10), VoxelFrame.material(Color.BLUE))
		frame.set_cell(Vector3i(11, 1, 10), VoxelFrame.material(Color.BLUE))
		State.selection.from_box(Vector3i(10, 0, 10), Vector3i(11, 1, 10))
		State.selection_changed.emit()
	)
	step("When the user copies the selection as a brush", func():
		options.get_node("Shape/Selection").pressed.emit()
		expect(State.get_current_voxel_frame().count() == 3, "copying the brush preserves the source voxels")
		expect(State.selection.count() == 4, "copying the brush preserves the selection")
		expect(options.get_node("Shape/Selection").button_pressed, "the selection brush is active")
		expect(not options.get_node("Shape/Selection").disabled, "the copied selection shape is available")
		expect(not options.get_node("Shape/Cube").button_pressed and not options.get_node("Shape/Sphere").button_pressed, "the selection brush is the only active shape")
		expect(not options.get_node("Diameter").visible, "the selection brush retains its original size")
		_click_shape("Cube")
		expect(options.get_node("Shape/Cube").button_pressed, "the cube shape can replace the voxel brush")
		_click_shape("Selection")
		expect(options.get_node("Shape/Selection").button_pressed, "the voxel brush can be selected again")
		State.clear_selection()
		State.get_current_voxel_frame().clear()
		State.current_color = Color.GREEN
		target = aim(_position(Vector3.ZERO)).target
		_click(_position(Vector3.ZERO))
	)
	step("Then the copied brush keeps its shape and source colors", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 3, "the copied brush contains only the three occupied voxels")
		expect(frame.get_color(target) == Color.RED, "the first copied voxel keeps its red color")
		expect(frame.get_color(target + Vector3i(1, 0, 0)) == Color.BLUE, "the second copied voxel keeps its blue color")
		expect(frame.get_color(target + Vector3i(1, 1, 0)) == Color.BLUE, "the copied brush retains its depth")
		expect(not frame.has(target + Vector3i(0, 1, 0)), "the copied brush preserves its empty cell")
	)
	await get_tree().process_frame
	step("Given paint mode and a cube brush that overlaps a selection boundary", func():
		_empty("top")
		_click_shape("Cube")
		options.get_node("Diameter").value = 3
		select_toolbar_item("Toolbar", "Paint")
		State.current_color = Color.RED
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.BLUE))
		frame.set_cell(Vector3i.RIGHT, VoxelFrame.material(Color.BLUE))
		frame.set_cell(Vector3i.LEFT, VoxelFrame.material(Color.BLUE))
		State.selection.add(Vector3i.ZERO)
		State.selection.add(Vector3i.RIGHT)
		State.selection_changed.emit()
		_click(_position(Vector3.ZERO))
	)
	step("Then paint mode recolors only selected occupied voxels", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 3, "paint mode adds no voxels")
		expect(frame.get_color(Vector3i.ZERO) == Color.RED, "the selected center has the brush color")
		expect(frame.get_color(Vector3i.RIGHT) == Color.RED, "the selected neighbor has the brush color")
		expect(frame.get_color(Vector3i.LEFT) == Color.BLUE, "the unselected neighbor retains its color")
	)


func _empty(view: String) -> void:
	State.document = VoxelDocument.new()
	State.floor_axis = {"right": 0, "top": 1, "front": 2}[view]
	camera_rig().set_view(view)
	camera_rig().is_orthogonal = true


func _position(world: Vector3) -> Vector2:
	return camera_rig().unproject_position(world)


func _click(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = pos
	event.pressed = true
	viewport.push_input(event)
	event.pressed = false
	viewport.push_input(event)


func _click_shape(shape_name: String) -> void:
	var button := options.get_node("Shape/" + shape_name)
	if DisplayServer.get_name() == "headless":
		button.pressed.emit()
		return
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = button.get_global_rect().get_center()
	event.pressed = true
	get_tree().root.push_input(event, true)
	event.pressed = false
	get_tree().root.push_input(event, true)
