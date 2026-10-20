extends "res://tests/test.gd"

# A Delete or Cut during a Box or Lasso drag changes the edit context. The drag
# must release its own edit, so the command can run, and the stale mouse release
# must not commit a selection.

var _selection_settings := preload("res://plugins/selection/settings.tres")

var viewport: SubViewport
var center := Vector2.ZERO
var frame: VoxelFrame
var tool: Node
var clipboard: Node
var original_clipboard := ""
var _default_mode := 0
var _default_empty := false
var _default_depth := true
var _defaults_ready := false


func _ready() -> void:
	timeout = 30.0
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		original_clipboard = DisplayServer.clipboard_get()
	test("Delete during a box drag releases the drag and erases the selection", _delete_during_box, "delete_during_box")
	test("Cut during a lasso drag releases the drag and cuts exactly once", _cut_during_lasso, "cut_during_lasso")


func _setup_test() -> void:
	if not _defaults_ready:
		_default_mode = _selection_settings.mode
		_default_empty = _selection_settings.include_empty
		_default_depth = _selection_settings.depth_test
		_defaults_ready = true
	State.stop()
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	_selection_settings.mode = _default_mode
	_selection_settings.include_empty = _default_empty
	_selection_settings.depth_test = _default_depth
	State.clear_selection()
	State.undo_redo.clear_history()
	camera_rig().is_orthogonal = false
	camera_rig().set_view("default")
	clipboard = plugin("ClipboardPlugin")
	await get_tree().process_frame


# Release only the tool's own drag handle. The document reset above already
# releases any transaction a failed test left open.
func _cleanup_test() -> void:
	var selection_plugin := plugin("SelectionPlugin")
	if selection_plugin != null and is_instance_valid(selection_plugin._current_tool):
		selection_plugin._current_tool.abort_stroke()
	State.clear_selection()
	State.undo_redo.clear_history()
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set(original_clipboard)
	await get_tree().process_frame


func _view_setup(tool_name: String) -> void:
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	center = Vector2(400.0, 250.0)
	activate_tool("selection")
	select_toolbar_item("selection", tool_name)
	tool = plugin("SelectionPlugin")._current_tool


func _select_pair() -> void:
	frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
	frame.set_cell(Vector3i.RIGHT, VoxelFrame.material(Color.BLUE))
	frame.set_cell(Vector3i(8, 0, 0), VoxelFrame.material(Color.GREEN))
	State.selection.add(Vector3i.ZERO)
	State.selection.add(Vector3i.RIGHT)
	State.selection_changed.emit()


func _delete_during_box() -> void:
	step("Given the box tool, a selected pair, and an unselected marker", func():
		_view_setup("Box")
		_select_pair()
	)
	step("When the user holds a box drag and presses Delete", func():
		_press(center)
		expect(tool._edit != null, "the box drag holds its own edit")
		clipboard._options.get_node("Delete").pressed.emit()
	)
	step("Then the drag released its edit and Delete erased the selection", func():
		expect(tool._edit == null, "the box drag released its edit")
		expect(State.active_edit() == null, "no edit stays active")
		expect(frame.count() == 1 and frame.get_color(Vector3i(8, 0, 0)) == Color.GREEN, "Delete erased only the selected voxels")
		expect(State.selection.count() == 2, "Delete keeps the source selection")
		_release(center)
		expect(frame.count() == 1, "the stale release commits nothing")
		expect(State.selection.count() == 2, "the stale release changes no selection")
		State.undo_redo.undo()
		expect(frame.count() == 3, "one undo restores the deleted voxels")
		expect(not State.undo_redo.has_undo(), "Delete creates one undo action")
	)
	step("When the user starts a new drag after the stale release", func():
		_press(center)
		expect(tool._edit != null, "the new drag opens a fresh edit")
		_release(center)
	)
	step("Then the new drag releases its edit cleanly", func():
		expect(tool._edit == null and State.active_edit() == null, "the new drag released its edit")
	)


func _cut_during_lasso() -> void:
	step("Given the lasso tool, a selected pair, and an unselected marker", func():
		_view_setup("Lasso")
		_select_pair()
	)
	step("When the user holds a lasso drag and cuts", func():
		_press(center)
		_move_to(center + Vector2(30.0, 30.0))
		expect(tool._edit != null, "the lasso drag holds its own edit")
		expect(tool._points.size() >= 1, "the lasso sampled its path")
		clipboard._options.get_node("Cut").pressed.emit()
	)
	step("Then the drag released its edit and Cut removed the source exactly once", func():
		expect(tool._edit == null, "the lasso released its edit")
		expect(State.active_edit() == null, "no edit stays active")
		expect(clipboard._pattern.size() == 2, "Cut copied both selected voxels")
		expect(frame.count() == 1 and frame.get_color(Vector3i(8, 0, 0)) == Color.GREEN, "Cut erased only the selected voxels")
		expect(State.selection.is_empty(), "Cut clears the source selection")
		expect(tool._points.is_empty(), "the lasso dropped its stale path")
		_release(center + Vector2(30.0, 30.0))
		expect(frame.count() == 1, "the stale release commits nothing")
		State.undo_redo.undo()
		expect(frame.count() == 3, "one undo restores the cut voxels")
		expect(State.selection.count() == 2, "one undo restores the cut selection")
		expect(not State.undo_redo.has_undo(), "Cut creates one undo action")
	)


func _press(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	viewport.push_input(event)


func _move_to(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(event)


func _release(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = pos
	viewport.push_input(event)
