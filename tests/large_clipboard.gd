extends "res://tests/test.gd"

var clipboard: Node
var source: VoxelFrame
var target: VoxelFrame
var original_clipboard := ""


func _ready() -> void:
	timeout = 30.0
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		original_clipboard = DisplayServer.clipboard_get()
	test("large clipboard copies and paste previews preserve source data and cancel on frame changes", _run)


func _run() -> void:
	step("Given a selected colored volume and an unselected marker", func():
		clipboard = plugin("ClipboardPlugin")
		State.document = VoxiDocument.new()
		source = State.get_current_voxel_frame()
		for x in 18:
			for y in 18:
				for z in 18:
					source.set_cell(Vector3i(x, y, z), Color.RED if x < 9 else Color.BLUE)
		source.set_cell(Vector3i(-32, 0, 0), Color.GREEN)
		State.selection.from_box(Vector3i.ZERO, Vector3i(17, 17, 17))
		State.selection_changed.emit()
	)
	step("When the user copies the large selection", func():
		clipboard.copy_voxels()
		expect(State.edit_busy(), "the large copy reports foreground work")
	)
	while clipboard._copy_job:
		await get_tree().process_frame
	step("Then the clipboard contains the selection and the source is unchanged", func():
		expect(clipboard._pattern.size() == 5832, "the clipboard contains all selected voxels")
		expect(source.count() == 5833, "the source volume and marker remain unchanged")
		expect(State.selection.count() == 5832, "the source selection remains unchanged")
		expect(not State.edit_busy(), "the copy releases editing")
		_empty_target()
	)
	step("When the user replaces a paste position and clicks to place", func():
		clipboard.paste_voxels()
		_motion(Vector3(48, 0, 0))
		_motion(Vector3(32, 0, 0))
		_click(Vector3(32, 0, 0))
		expect(target.count() == 0, "the running paste leaves the target unchanged")
	)
	while clipboard._paste_tool._active:
		await get_tree().process_frame
	step("Then the latest position contains one complete colored copy", func():
		expect(target.count() == 5832, "the paste contains the complete selected volume")
		expect(target.get_color(Vector3i(24, 0, 0)) == Color.RED, "the left side preserves red")
		expect(target.get_color(Vector3i(41, 0, 0)) == Color.BLUE, "the right side preserves blue")
		expect(not target.has(Vector3i(57, 0, 0)), "the old position leaves no voxels")
		expect(State.selection.count() == 5832, "the pasted volume becomes selected")
		expect(not State.edit_busy(), "the completed paste releases editing")
		State.undo_redo.undo()
		expect(target.count() == 0, "one undo removes the complete paste")
		expect(not State.undo_redo.has_undo(), "the paste creates one undo action")
	)
	step("When the user changes frames during another paste", func():
		State.undo_redo.clear_history()
		clipboard.paste_voxels()
		_motion(Vector3(32, 0, 0))
		State.document.add_frame()
		State.current_frame = 1
	)
	await get_tree().process_frame
	step("Then the old paste cannot change either frame", func():
		expect(target.count() == 0, "the original target stays empty")
		expect(State.get_current_voxel_frame().count() == 0, "the new frame receives no old paste")
		expect(not clipboard._paste_tool.is_inside_tree(), "the cancelled paste preview is removed")
		expect(not State.edit_busy(), "the frame change releases editing")
		expect(not State.undo_redo.has_undo(), "the cancelled paste adds no history action")
	)
	step("Given another copy of the selected source volume", func():
		var document := VoxiDocument.new()
		document.frames[0] = source.copy_frame()
		State.document = document
		target = State.get_current_voxel_frame()
		State.selection.from_box(Vector3i.ZERO, Vector3i(17, 17, 17))
		State.selection_changed.emit()
	)
	step("When the user cuts the large selection", func():
		clipboard.cut_voxels()
		expect(State.edit_busy(), "the large cut reports foreground work")
	)
	while clipboard._copy_job:
		await get_tree().process_frame
	step("Then the large cut preserves the marker and supports one undo", func():
		expect(target.count() == 1, "the large cut removes the selected volume")
		expect(target.get_color(Vector3i(-32, 0, 0)) == Color.GREEN, "the large cut preserves the unselected marker")
		expect(clipboard._pattern.size() == 5832, "the large cut keeps a complete clipboard copy")
		expect(not State.edit_busy(), "the large cut releases editing")
		State.undo_redo.undo()
		expect(target.count() == 5833, "one undo restores the large cut")
		expect(State.selection.count() == 5832, "undo restores the large cut selection")
	)
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set(original_clipboard)


func _empty_target() -> void:
	State.document = VoxiDocument.new()
	target = State.get_current_voxel_frame()
	State.floor_axis = Vector3.Axis.AXIS_Y
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true


func _motion(world: Vector3) -> void:
	clipboard._paste_tool.handle_input(InputEventMouseMotion.new(), camera_rig().unproject_position(world))


func _click(world: Vector3) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	clipboard._paste_tool.handle_input(event, camera_rig().unproject_position(world))
