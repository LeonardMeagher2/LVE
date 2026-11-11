extends "res://tests/test.gd"

# Focused lifecycle tests for the clipboard runner and the paste status.
#
# The copy, cut, and import workers now await `State.run_edit_job`. These tests
# prove that a document change cancels the worker, that the caller adopts a
# result only for its own document and frame, that one operation reports the
# paste placement and its preview, and that a cancel leaves no status.
#
#   godot --path . res://tests/clipboard_lifecycle.tscn
#
# The source volume is above the inline limit, so the copy and the import use the
# worker path. The paste tests pass their own large pattern to the paste tool.

## The edge of the large source volume.
const SOURCE_EDGE := 18
## The edge of the large paste pattern.
const PASTE_EDGE := 17
const CLIPBOARD_PREFIX := '{"voxel_voxels":'

var clipboard: Node
var original_clipboard := ""
var _job
var _operation_id := 0
var _pattern := {}
var _selection := {}
var _materials := {}


func _ready() -> void:
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		original_clipboard = DisplayServer.clipboard_get()
	timeout = 30.0
	test("a document change cancels the copy worker and adopts no pattern", _copy_context, "clipboard_copy_context")
	test("the copy and import runners keep one operation and adopt no stale result", _import_context, "clipboard_import_context")
	test("the paste placement and its preview share one operation and commit once", _paste_status, "paste_single_status")
	test("a cancelled paste releases its placement operation", _paste_cancel, "paste_cancel_status")


func before_test() -> void:
	clipboard = plugin("ClipboardPlugin")
	clipboard.cancel_paste()
	if clipboard._paste_tool.is_inside_tree():
		clipboard.remove_editor_node(clipboard._paste_tool)
	clipboard._pattern = {}
	clipboard._selection_pattern = {}
	clipboard._material_pattern = {}
	clipboard._clipboard_text = ""
	clipboard._has_clipboard_voxels = false
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	State.clear_selection()
	_job = null
	_operation_id = 0


func after_test() -> void:
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set(original_clipboard)


func _copy_context() -> void:
	step("Given a large selection and a copy", func():
		_fill_source()
		clipboard.copy_voxels()
		expect(State.edit_busy(), "the large copy reports foreground work")
		expect(clipboard._copy_job != null, "the copy runs on the worker")
		_operation_id = State.get_activity().id
		_expect_one_foreground(_operation_id, clipboard)
	)
	step("When the user asks for another copy", func():
		_job = clipboard._copy_job
		clipboard.copy_voxels()
		expect(clipboard._copy_job == _job, "the running copy keeps its job")
		expect(_foreground_count() == 1, "the second request adds no operation")
	)
	step("When the document changes", func():
		State.document = VoxelDocument.new()
	)
	while clipboard._copy_job:
		await get_tree().process_frame
	step("Then the runner adopts nothing from the old document", func():
		expect(clipboard._pattern.is_empty(), "the changed document installs no pattern")
		expect(clipboard._selection_pattern.is_empty(), "the changed document installs no selection")
		expect(not State.edit_busy(), "the cancelled copy releases editing")
		expect(not State.has_operation(_operation_id), "the copy finishes its operation")
		expect(not State.undo_redo.has_undo(), "the copy adds no history action")
	)


func _import_context() -> void:
	step("Given a large copied selection", func():
		_fill_source()
		clipboard.copy_voxels()
	)
	while clipboard._copy_job:
		await get_tree().process_frame
	step("Then the copy runner adopts its result", func():
		expect(clipboard._pattern.size() == 5832, "the copy runner installs the complete pattern")
		expect(clipboard._clipboard_text.begins_with(CLIPBOARD_PREFIX), "the copy runner writes the clipboard text")
		expect(not State.edit_busy(), "the copy runner releases editing")
	)
	step("When the clipboard is parsed again and the document changes", func():
		clipboard._pattern = {}
		clipboard.paste_voxels()
		expect(clipboard._import_job != null, "the new clipboard text runs on the worker")
		_operation_id = State.get_activity().id
		_expect_one_foreground(_operation_id, clipboard)
		State.document = VoxelDocument.new()
	)
	while clipboard._import_job:
		await get_tree().process_frame
	step("Then the import adopts nothing from the old document", func():
		expect(not clipboard._paste_tool._active, "the changed document starts no paste")
		expect(not clipboard._paste_tool.is_inside_tree(), "the changed document mounts no preview")
		expect(clipboard._pattern.is_empty(), "the cancelled import keeps the pattern empty")
		expect(not State.edit_busy(), "the cancelled import releases editing")
		expect(not State.has_operation(_operation_id), "the import finishes its operation")
	)


func _paste_status() -> void:
	step("Given a large copied pattern and a mounted paste tool", func():
		State.document = VoxelDocument.new()
		_build_paste_pattern()
		clipboard.add_editor_node(clipboard._paste_tool)
		clipboard._paste_tool.begin_paste(_pattern, _selection, Vector3i.ZERO, _materials)
		_operation_id = clipboard._paste_tool._placement_operation_id
		expect(_operation_id != 0, "the placement owns one operation")
		expect(clipboard._paste_tool._job != null, "the placement preview runs on the worker")
		expect(clipboard._paste_tool._operation_id == 0, "the preview adds no second operation")
		_expect_one_foreground(_operation_id, clipboard._paste_tool)
	)
	step("When the user moves to a newer position", func():
		_job = clipboard._paste_tool._job
		clipboard._paste_tool._update_endpoint(Vector3i(32, 0, 0))
		expect(clipboard._paste_tool._job == _job, "the newer position keeps the running job")
		expect(_job._cancel_requested, "the newer position cancels the running job")
		expect(clipboard._paste_tool._preview_requested, "the newest position waits for the worker")
		expect(State.has_operation(_operation_id), "the placement operation stays visible")
		expect(clipboard._paste_tool._operation_id == 0, "the newer position adds no second operation")
	)
	await _await_paste_preview()
	step("Then one operation reports the newest preview without a model write", func():
		expect(clipboard._paste_tool._preview_result != null, "the newest preview is ready")
		expect(clipboard._paste_tool._preview_result.revision == clipboard._paste_tool._revision, "the adopted preview is the newest request")
		expect(State.get_current_voxel_frame().count() == 0, "the preview writes no cell")
		expect(State.has_operation(_operation_id), "the placement operation stays open before the commit")
		_expect_one_foreground(_operation_id, clipboard._paste_tool)
	)
	step("When the user commits the paste", func():
		_key(clipboard._paste_tool, KEY_ENTER)
	)
	step("Then the commit writes only the newest position", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 4913, "the paste writes the pattern once")
		expect(frame.has(Vector3i(32, 0, 0)), "the newest position contains the pattern center")
		expect(not frame.has(Vector3i(0, 0, 0)), "the older position leaves no voxel")
		expect(State.selection.count() == 4913, "the paste restores the pasted selection")
		expect(not State.edit_busy(), "the commit releases the foreground status")
		expect(not State.has_operation(_operation_id), "the commit finishes the placement operation")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes the paste")
		expect(not State.undo_redo.has_undo(), "the paste creates one history action")
	)


func _paste_cancel() -> void:
	step("Given a running paste preview", func():
		State.document = VoxelDocument.new()
		_build_paste_pattern()
		clipboard.add_editor_node(clipboard._paste_tool)
		clipboard._paste_tool.begin_paste(_pattern, _selection, Vector3i.ZERO, _materials)
		_job = clipboard._paste_tool._job
		_operation_id = clipboard._paste_tool._placement_operation_id
		expect(_job != null, "the large paste starts a preview worker")
		expect(State.has_operation(_operation_id), "the placement reports one operation")
	)
	step("When the user cancels the placement", func():
		_key(clipboard._paste_tool, KEY_ESCAPE)
		expect(not clipboard._paste_tool._active, "the cancel ends the placement")
		expect(_job._cancel_requested, "the cancel stops the preview worker")
		expect(not State.has_operation(_operation_id), "the cancel finishes the placement operation")
		expect(clipboard._paste_tool._placement_operation_id == 0, "the cancel clears the placement operation id")
		expect(not State.edit_busy(), "the cancel releases the foreground status")
	)
	await get_tree().process_frame
	step("Then the cancelled paste writes no cell and removes its preview", func():
		expect(clipboard._paste_tool._job == null, "the runner retires the cancelled job")
		expect(State.get_current_voxel_frame().count() == 0, "the cancelled paste leaves the frame empty")
		expect(not State.undo_redo.has_undo(), "the cancelled paste adds no history action")
		expect(not clipboard._paste_tool.is_inside_tree(), "the cancel removes the preview tool")
	)


func _fill_source() -> void:
	State.document = VoxelDocument.new()
	var frame := State.get_current_voxel_frame()
	for x in SOURCE_EDGE:
		for y in SOURCE_EDGE:
			for z in SOURCE_EDGE:
				frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.RED if x < 9 else Color.BLUE))
	State.selection.from_box(Vector3i.ZERO, Vector3i(SOURCE_EDGE - 1, SOURCE_EDGE - 1, SOURCE_EDGE - 1))
	State.selection_changed.emit()


func _build_paste_pattern() -> void:
	_pattern = {}
	_selection = {}
	_materials = {}
	var half := PASTE_EDGE / 2
	for x in range(-half, half + 1):
		for y in range(-half, half + 1):
			for z in range(-half, half + 1):
				var offset := Vector3i(x, y, z)
				_pattern[offset] = Color.RED
				_selection[offset] = true
				_materials[offset] = VoxelFrame.material(Color.RED)


func _await_paste_preview() -> void:
	var paste = clipboard._paste_tool
	var deadline := Time.get_ticks_msec() + 8000
	while (paste._job != null or paste._preview_result == null or paste._preview_result.revision != paste._revision) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _foreground_count() -> int:
	var count := 0
	for operation in State._operations.values():
		if operation.foreground:
			count += 1
	return count


func _expect_one_foreground(operation_id: int, owner: Node) -> void:
	expect(_foreground_count() == 1, "one foreground operation reports the clipboard work")
	for operation in State._operations.values():
		if operation.foreground:
			expect(operation.id == operation_id, "the reported operation is the tracked one")
			expect(operation.owner_ref.get_ref() == owner, "the operation belongs to its owner")


func _key(tool: Node, code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	tool.handle_input(event, Vector2.ZERO)
