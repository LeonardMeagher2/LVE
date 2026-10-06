extends "res://tests/test.gd"

var clipboard: Node
var frame: VoxelFrame
var original_clipboard := ""


func _ready() -> void:
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		original_clipboard = DisplayServer.clipboard_get()
	test("Cut preserves a pasteable copy and Delete erases only selected voxels with undo", _run)


func _run() -> void:
	step("Given two selected voxels and an unselected marker", func():
		clipboard = plugin("ClipboardPlugin")
		_setup()
	)
	step("When the user cuts through the shared editing controls", func():
		if DisplayServer.get_name() == "headless":
			clipboard._options.get_node("Cut").pressed.emit()
		else:
			var event := InputEventKey.new()
			event.keycode = KEY_X
			event.ctrl_pressed = true
			event.pressed = true
			get_tree().root.push_input(event)
			event.pressed = false
			get_tree().root.push_input(event)
	)
	step("Then the selected voxels are copied and removed in one action", func():
		expect(clipboard._pattern.size() == 2, "Cut copies both selected voxels")
		expect(frame.count() == 1 and frame.get_color(Vector3i(8, 0, 0)) == Color.GREEN, "Cut preserves the unselected marker")
		expect(State.selection.is_empty(), "Cut clears the source selection")
		expect(State.document.palette == [Color.MAGENTA], "Cut preserves the existing palette")
		State.undo_redo.undo()
		expect(frame.count() == 3, "one undo restores both cut voxels")
		expect(State.selection.count() == 2, "undo restores the cut selection")
		expect(not State.undo_redo.has_undo(), "Cut creates one undo action")
		State.undo_redo.redo()
		expect(frame.count() == 1, "one redo removes the cut voxels")
		expect(State.selection.is_empty(), "redo clears the cut selection")
	)
	step("When the user pastes the cut voxels into another document", func():
		State.document = VoxiDocument.new()
		frame = State.get_current_voxel_frame()
		camera_rig().set_view("top")
		camera_rig().is_orthogonal = true
		clipboard.paste_voxels()
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = true
		clipboard._paste_tool.handle_input(event, camera_rig().unproject_position(Vector3.ZERO))
	)
	step("Then the cut voxels retain their colors", func():
		expect(frame.count() == 2, "Paste restores both cut voxels")
		expect(frame.get_color(Vector3i.ZERO) == Color.RED, "the cut red voxel retains its color")
		expect(frame.get_color(Vector3i.RIGHT) == Color.BLUE, "the cut blue voxel retains its color")
		expect(State.selection.count() == 2 and State.selection.contains(Vector3i.ZERO) and State.selection.contains(Vector3i.RIGHT), "Paste restores the cut selection")
	)
	step("Given another selected pair and an unselected marker", _setup)
	step("When the user presses the Delete key", func():
		var event := InputEventKey.new()
		event.physical_keycode = KEY_DELETE
		event.pressed = true
		get_tree().root.push_input(event)
	)
	step("Then Delete erases only the selected voxels and supports undo", func():
		expect(frame.count() == 1, "Delete removes the selected pair")
		expect(frame.get_color(Vector3i(8, 0, 0)) == Color.GREEN, "Delete preserves the unselected marker")
		expect(State.selection.count() == 2, "Delete preserves the source selection")
		State.undo_redo.undo()
		expect(frame.count() == 3, "one undo restores the deleted voxels")
		expect(not State.undo_redo.has_undo(), "Delete creates one undo action")
	)
	step("When the user cuts without a selection", func():
		State.clear_selection()
		State.undo_redo.clear_history()
		clipboard.cut_voxels()
	)
	step("Then Cut uses the whole frame", func():
		expect(frame.count() == 0, "Cut removes all frame voxels when no selection exists")
		expect(clipboard._pattern.size() == 3, "Cut copies the whole frame")
		State.undo_redo.undo()
		expect(frame.count() == 3, "one undo restores the whole-frame cut")
	)
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set(original_clipboard)


func _setup() -> void:
	State.document = VoxiDocument.new()
	frame = State.get_current_voxel_frame()
	State.document.palette.assign([Color.MAGENTA])
	frame.set_cell(Vector3i.ZERO, Color.RED)
	frame.set_cell(Vector3i.RIGHT, Color.BLUE)
	frame.set_cell(Vector3i(8, 0, 0), Color.GREEN)
	State.selection.add(Vector3i.ZERO)
	State.selection.add(Vector3i.RIGHT)
	State.selection_changed.emit()
