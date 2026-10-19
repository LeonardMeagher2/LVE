extends "res://tests/test.gd"

var clipboard: Node
var frame: VoxelFrame
var source_selection := {}
var original_clipboard := ""


func _ready() -> void:
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		original_clipboard = DisplayServer.clipboard_get()
	test("clipboard operations restore the exact source selection including empty cells", _run)


func _run() -> void:
	step("Given two voxels and an irregular selection with empty cells", func():
		clipboard = plugin("ClipboardPlugin")
		_setup()
	)
	step("When the user copies the selection", func():
		clipboard.copy_voxels()
	)
	step("Then Copy preserves all selected cells", func():
		expect(State.selection.capture() == source_selection, "Copy preserves the exact source selection")
		expect(frame.count() == 2, "Copy preserves both source voxels")
		clipboard._pattern = {}
		clipboard._selection_pattern = {}
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		State.selection.add(Vector3i(-20, 0, 0))
		State.selection_changed.emit()
	)
	step("When the user reads the clipboard text and starts a paste", func():
		clipboard.paste_voxels()
	)
	while clipboard._import_job:
		await get_tree().process_frame
	step("Then the preview preserves the current selection", func():
		expect(State.selection.count() == 1 and State.selection.contains(Vector3i(-20, 0, 0)), "the paste preview preserves the target selection")
	)
	step("When the user places the copied voxels at an offset", func():
		_place(Vector3i(10, 0, 0))
	)
	step("Then Paste restores the exact translated selection", func():
		_expect_paste()
		State.undo_redo.undo()
		expect(frame.count() == 0, "undo removes the pasted voxels")
		expect(State.selection.count() == 1 and State.selection.contains(Vector3i(-20, 0, 0)), "undo restores the target selection")
		State.undo_redo.redo()
		_expect_paste()
	)
	step("Given the same source selection again", _setup)
	step("When the user cuts the selection", func():
		clipboard.cut_voxels()
	)
	step("Then Cut clears the selection and supports undo", func():
		expect(frame.count() == 0, "Cut removes both source voxels")
		expect(State.selection.is_empty(), "Cut clears all source selection cells")
		State.undo_redo.undo()
		expect(frame.count() == 2, "undo restores the cut voxels")
		expect(State.selection.capture() == source_selection, "undo restores the exact cut selection")
		State.undo_redo.redo()
		expect(State.selection.is_empty(), "redo clears the cut selection")
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
	)
	step("When the user pastes the cut voxels", func():
		clipboard.paste_voxels()
		_place(Vector3i(10, 0, 0))
	)
	step("Then Paste restores the cut selection with its empty cells", _expect_paste)
	step("When the user copies the whole frame without a selection", func():
		State.clear_selection()
		clipboard.copy_voxels()
		State.selection.add(Vector3i(-20, 0, 0))
		State.selection_changed.emit()
		clipboard.paste_voxels()
		_place(Vector3i(20, 0, 0))
	)
	step("Then Paste restores the empty source selection", func():
		expect(frame.count() == 4, "the whole-frame paste adds both copied voxels")
		expect(State.selection.is_empty(), "the whole-frame paste restores an empty selection")
	)
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set(original_clipboard)


func _setup() -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	frame.set_cell(Vector3i(2, 0, 0), VoxelFrame.material(Color.RED))
	frame.set_cell(Vector3i(4, 0, 0), VoxelFrame.material(Color.BLUE))
	for cell_position in [Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(4, 0, 0), Vector3i(5, 0, 0), Vector3i(3, 2, -1)]:
		State.selection.add(cell_position)
	State.selection_changed.emit()
	source_selection = State.selection.capture()


func _place(center: Vector3i) -> void:
	clipboard._paste_tool._update_endpoint(center)
	var event := InputEventKey.new()
	event.keycode = KEY_ENTER
	event.pressed = true
	clipboard._paste_tool.handle_input(event, Vector2.ZERO)


func _expect_paste() -> void:
	var expected := {}
	for cell_position: Vector3i in source_selection:
		expected[cell_position + Vector3i(7, 0, 0)] = true
	expect(State.selection.capture() == expected, "the pasted selection matches every translated source cell")
	expect(frame.count() == 2, "Paste contains only the two source voxels")
	expect(frame.get_color(Vector3i(9, 0, 0)) == Color.RED and frame.get_color(Vector3i(11, 0, 0)) == Color.BLUE, "the pasted voxels retain their colors and offset")
	expect(not frame.has(Vector3i(8, 0, 0)) and State.selection.contains(Vector3i(8, 0, 0)), "the selected empty cell remains empty and selected")
