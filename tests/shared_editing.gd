extends "res://tests/test.gd"

var brush: Node
var clipboard: Node
var options: Control
var frame: VoxelFrame
var original_clipboard := ""
var paste_mesh: Mesh


func _ready() -> void:
	timeout = 30.0
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		original_clipboard = DisplayServer.clipboard_get()
	test("voxel brushes use selections or whole frames and shared clipboard controls place one undoable copy", _run)


func _run() -> void:
	step("Given three colored voxels with no selection", func():
		brush = plugin("BrushPlugin")._brush_tool
		clipboard = plugin("ClipboardPlugin")
		options = plugin("BrushPlugin")._options
		_empty()
		frame.set_cell(Vector3i.ZERO, Color.RED)
		frame.set_cell(Vector3i.RIGHT, Color.BLUE)
		frame.set_cell(Vector3i.UP, Color.GREEN)
	)
	step("When the user chooses the voxel brush", func():
		options.get_node("Shape/Selection").pressed.emit()
		frame.clear()
		_click(brush, Vector3.ZERO)
	)
	step("Then the brush contains the whole frame with its colors", func():
		expect(frame.count() == 3, "the whole-frame brush contains three voxels")
		expect(frame.get_color(Vector3i.ZERO) == Color.RED, "the voxel brush preserves red")
		expect(frame.get_color(Vector3i.RIGHT) == Color.BLUE, "the voxel brush preserves blue")
		expect(frame.get_color(Vector3i.UP) == Color.GREEN, "the voxel brush preserves depth and green")
	)
	step("Given only the two base voxels are selected", func():
		State.selection.add(Vector3i.ZERO)
		State.selection.add(Vector3i.RIGHT)
		State.selection_changed.emit()
		options.get_node("Shape/Selection").pressed.emit()
		State.clear_selection()
		frame.clear()
		_click(brush, Vector3.ZERO)
	)
	step("Then the voxel brush contains only the selected voxels", func():
		expect(frame.count() == 2, "the selection brush excludes the unselected voxel")
		expect(not frame.has(Vector3i.UP), "the unselected green voxel is absent")
	)
	step("When the user copies all frame voxels through the shared controls", func():
		State.document.palette.assign([Color.GREEN])
		State.palette_changed.emit()
		options.get_node("Shape/Cube").pressed.emit()
		clipboard._options.get_node("Copy").pressed.emit()
		expect(options.get_node("Shape/Cube").button_pressed, "copying leaves the brush shape unchanged")
		expect(frame.count() == 2, "copying preserves the source frame")
		expect(clipboard._pattern.size() == 2, "copying without a selection captures the whole frame")
		expect(State.document.palette == [Color.GREEN], "Copy preserves the existing palette")
		activate_tool("selection")
	)
	await get_tree().process_frame
	step("Then the same clipboard controls are available to selection tools", func():
		expect(clipboard._options.get_parent() == plugin("SelectionPlugin")._options, "selection tools use the shared clipboard controls")
		expect(clipboard._options.get_node("Separator") is VSeparator, "a separator precedes the clipboard controls")
		activate_tool("transform")
	)
	await get_tree().process_frame
	step("Then the same clipboard controls are available to transform tools", func():
		expect(clipboard._options.get_parent() == plugin("TransformPlugin")._options, "transform tools use the shared clipboard controls")
		select_toolbar_item("Toolbar", "Pencil")
		State.selection.add(Vector3i.ZERO)
		State.selection_changed.emit()
		clipboard.copy_voxels()
		expect(clipboard._pattern.size() == 1, "copying a selection captures only selected voxels")
		State.clear_selection()
		clipboard.copy_voxels()
		State.selection.add(Vector3i.ZERO)
		State.selection_changed.emit()
		State.undo_redo.clear_history()
	)
	step("When the user starts a paste and moves its preview", func():
		clipboard.paste_voxels()
		expect(frame.count() == 2, "the paste preview preserves the source frame")
		expect(State.edit_busy(), "paste placement reserves editing")
	)
	while not clipboard._paste_tool.get_node("Cursor").is_settled():
		await get_tree().process_frame
	step("Then moving the paste reuses its colored preview mesh", func():
		paste_mesh = clipboard._paste_tool.get_node("Cursor").mesh
		_motion(clipboard._paste_tool, Vector3(8, 0, 0))
		expect(clipboard._paste_tool.position == Vector3(8, 0, 0), "the paste preview follows its latest position")
		expect(clipboard._paste_tool.get_node("Cursor").mesh == paste_mesh, "the moved paste reuses its colored mesh")
		expect(clipboard._paste_tool.get_node("Cursor").is_settled(), "the moved paste needs no mesh worker")
		_click(clipboard._paste_tool, Vector3(8, 0, 0))
	)
	step("Then the copy appears at the cursor and supports one undo", func():
		expect(frame.count() == 4, "the pasted copy adds two voxels")
		expect(frame.get_color(Vector3i(8, 0, 0)) == Color.RED, "the pasted red voxel has the cursor offset")
		expect(frame.get_color(Vector3i(9, 0, 0)) == Color.BLUE, "the pasted blue voxel preserves its relative position")
		expect(State.selection.is_empty(), "Paste restores the copied empty selection")
		expect(not State.edit_busy(), "paste placement releases editing")
		expect(State.document.palette == [Color.GREEN], "Paste preserves the existing palette")
		State.undo_redo.undo()
		expect(frame.count() == 2, "one undo removes only the pasted voxels")
		expect(State.selection.contains(Vector3i.ZERO) and State.selection.count() == 1, "undo preserves the existing selection")
		expect(not State.undo_redo.has_undo(), "the paste creates one history action")
		State.undo_redo.redo()
		expect(frame.count() == 4, "one redo restores the pasted voxels")
		expect(State.selection.is_empty(), "redo restores the copied empty selection")
	)
	step("When the user pastes into a new document and cancels", func():
		_empty()
		clipboard.paste_voxels()
		_motion(clipboard._paste_tool, Vector3(4, 0, 0))
		_key(clipboard._paste_tool, KEY_ESCAPE)
	)
	step("Then cancellation preserves the new document", func():
		expect(frame.count() == 0, "the cancelled paste leaves the frame empty")
		expect(not State.edit_busy(), "paste cancellation releases editing")
		expect(not State.undo_redo.has_undo(), "paste cancellation adds no history action")
	)
	step("When the clipboard is read again from its voxel text", func():
		clipboard._pattern = {}
		clipboard.paste_voxels()
	)
	while clipboard._import_job:
		await get_tree().process_frame
	step("Then the clipboard can be pasted across documents", func():
		_click(clipboard._paste_tool, Vector3(4, 0, 0))
		expect(frame.count() == 2, "the clipboard text restores both voxels")
		expect(frame.get_color(Vector3i(4, 0, 0)) == Color.RED, "the clipboard text preserves red")
		expect(frame.get_color(Vector3i(5, 0, 0)) == Color.BLUE, "the clipboard text preserves blue")
	)
	step("Given a cube brush and a filled volume", func():
		_empty()
		options.get_node("Shape/Cube").pressed.emit()
		options.get_node("Diameter").value = 3
		for x in range(-2, 3):
			for y in range(-2, 3):
				for z in range(-2, 3):
					frame.set_cell(Vector3i(x, y, z), Color.BLUE)
		select_toolbar_item("Toolbar", "Eraser")
	)
	step("When the user erases one cube stamp", func():
		_click(brush, Vector3.ZERO)
	)
	step("Then the eraser uses the shared cube diameter and undo", func():
		expect(frame.count() == 107, "the cube eraser removes the eighteen occupied voxels in its surface footprint")
		State.undo_redo.undo()
		expect(frame.count() == 125, "one undo restores the complete erased volume")
	)
	step("When the user erases one sphere stamp", func():
		options.get_node("Shape/Sphere").pressed.emit()
		_click(brush, Vector3.ZERO)
	)
	step("Then the eraser uses the sphere shape", func():
		expect(frame.count() == 111, "the sphere eraser removes only its fourteen occupied surface voxels")
	)
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set(original_clipboard)


func _empty() -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	State.floor_axis = Vector3.Axis.AXIS_Y
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true


func _click(tool: Node, world: Vector3) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	var pos := camera_rig().unproject_position(world)
	event.position = pos
	if tool == clipboard._paste_tool:
		editor_viewport().push_input(event)
	else:
		tool.handle_input(event, pos)
	event.pressed = false
	if tool == clipboard._paste_tool:
		editor_viewport().push_input(event)
	else:
		tool.handle_input(event, pos)


func _motion(tool: Node, world: Vector3) -> void:
	tool.handle_input(InputEventMouseMotion.new(), camera_rig().unproject_position(world))


func _key(tool: Node, code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	tool.handle_input(event, Vector2.ZERO)
