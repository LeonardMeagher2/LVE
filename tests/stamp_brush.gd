extends "res://tests/test.gd"


var plugin_node: Node
var settings: StampToolSettings
var panel: Control
var viewport: SubViewport
var source_path := ""
var source_document: VoxelDocument
var stamp_target := Vector3i.ZERO
var metal := VoxelFrame.material(Color.RED, Color(0.5, 0.25, 0.125), 1.0, 0.25)
var blue := VoxelFrame.material(Color.BLUE, Color(0.125, 0.5, 0.25), 0.25, 0.75)
var green := VoxelFrame.material(Color.GREEN, Color(0.25, 0.5, 0.125), 0.5, 0.75)


func _ready() -> void:
	timeout = 30.0
	test("a file frame becomes a centered stamp with full materials", _file_frame_stamp, "stamp_file_frame")
	test("the frame panel switches the stamp without reopening the file", _frame_switch, "stamp_frame_switch")
	test("the selection source stamps outside the source selection", _selection_source, "stamp_selection_source")
	test("the center option chooses the frame origin or the cursor center", _center_option, "stamp_center_option")
	test("the stamp source follows the tab", _tab_state, "stamp_tab_state")
	test("the clear button clears the file source", _clear_file_source, "stamp_clear_file")
	test("the clear button clears the selection source", _clear_selection_source, "stamp_clear_selection")
	test("a press without a stamp source changes nothing", _no_source, "stamp_no_source")
	test("an invalid file keeps the previous stamp", _invalid_file, "stamp_invalid_file")
	test("the frame panel follows the stamp tool", _panel_lifecycle, "stamp_panel_lifecycle")


func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.current_frame = 0
	State.active_tag = 0
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	State.slice_layers = 0
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true
	camera_rig().center_on(AABB(Vector3(-20, -1, -20), Vector3(40, 2, 40)))
	plugin_node = plugin("StampPlugin")
	settings = plugin_node._settings
	settings.clear_stamp()
	plugin_node._file_document = null
	plugin_node._file_path = ""
	plugin_node._frame_index = -1
	plugin_node._source_label = "No stamp source"
	plugin_node._center_on_cursor = false
	plugin_node._selection_source_frame = null
	plugin_node._selection_source_mask = {}
	plugin_node._selection_label = ""
	plugin_node._pending_recenter = false
	source_path = "user://stamp_brush_%s.lve" % Time.get_ticks_usec()
	_make_source_file()
	activate_tool("stamp")
	panel = plugin_node._frame_panel
	plugin_node._options.get_node("Center").set_pressed_no_signal(false)
	await get_tree().process_frame


func after_test() -> void:
	State.clear_selection()
	await get_tree().process_frame
	if FileAccess.file_exists(source_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(source_path))


func _file_frame_stamp() -> void:
	step("Given an LVE file with two frames and center on", func():
		plugin_node._options.get_node("Center").button_pressed = true
		plugin_node.open_source_file(source_path)
		expect(panel.visible, "the frame panel shows after the file loads")
		expect(panel._buttons.size() == 2, "the panel lists both frames")
	)
	await _await_source()
	step("Then the first frame becomes the stamp automatically", func():
		expect(_selected_frame() == 0, "the panel selects the first frame")
		expect(settings.shape == settings.BrushShape.STAMP, "the stamp shape is active")
		expect(settings.stamp_pattern.size() == 2, "the stamp holds both occupied cells")
		expect(settings.stamp_material_pattern.size() == 2, "the stamp holds one material per cell")
	)
	step("When the user stamps the frame in an empty document", func():
		State.get_current_voxel_frame().clear()
		sync_viewport()
		stamp_target = _target(Vector3.ZERO)
		_click(Vector3.ZERO)
	)
	await _settle()
	step("Then the stamp keeps its shape, materials, and one undo action", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 2, "the stamp contains the two source cells")
		expect(frame.get_material(stamp_target) == metal, "the first stamp cell keeps its full material")
		expect(frame.get_material(stamp_target + Vector3i.RIGHT) == blue, "the second stamp cell keeps its full material")
		expect(State.undo_redo.get_current_action_name() == "Stamp", "the stamp records one Stamp action")
		expect(panel.visible and _selected_frame() == 0, "the frame panel stays open on the selected frame")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes the complete stamp")
		expect(not State.undo_redo.has_undo(), "the stamp creates one history action")
	)


func _frame_switch() -> void:
	step("Given a file frame stamp with center on", func():
		plugin_node._options.get_node("Center").button_pressed = true
		_select_frame(0)
	)
	await _await_source()
	step("When the user stamps the first frame", func():
		_click(Vector3.ZERO)
	)
	await _settle()
	step("Then the user switches to the second frame in the open panel", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 2, "the first frame stamp contains two cells")
		frame.clear()
		State.undo_redo.clear_history()
		_select_frame_button(1)
	)
	await _await_source()
	step("Then the second stamp replaces the first without reopening the file", func():
		expect(panel.visible, "the frame panel stays open")
		expect(_selected_frame() == 1, "the panel selects the new frame")
		expect(settings.stamp_pattern.size() == 1, "the new stamp holds the second frame cell")
		stamp_target = _target(Vector3.ZERO)
		_click(Vector3.ZERO)
	)
	await _settle()
	step("Then the placed stamp uses the second frame", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 1, "the second frame stamp contains one cell")
		expect(frame.get_material(stamp_target) == green, "the second frame keeps its green material")
	)


func _selection_source() -> void:
	step("Given two selected cells with different materials", func():
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, metal)
		frame.set_cell(Vector3i.RIGHT, blue)
		State.selection.from_box(Vector3i.ZERO, Vector3i.RIGHT)
		State.selection_changed.emit()
	)
	step("When the user uses the selection as a stamp", func():
		plugin_node.use_current_selection()
	)
	await _await_source()
	step("Then the stamp holds both source materials and clears the selection", func():
		expect(settings.stamp_pattern.size() == 2, "the selection stamp holds two cells")
		expect(settings.stamp_material_pattern.size() == 2, "the selection stamp holds two materials")
		expect(State.selection.is_empty(), "the selection source clears the selection")
	)
	step("When the user removes the source cells and stamps outside the selection", func():
		State.get_current_voxel_frame().clear()
		sync_viewport()
		stamp_target = _target(Vector3(5, 0, 5))
		_click(Vector3(5, 0, 5))
	)
	await _settle()
	step("Then the destination selection does not limit the stamp", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 2, "the stamp lands outside the old selection")
		expect(frame.get_material(stamp_target) == metal, "the outside stamp keeps the first material")
		expect(frame.get_material(stamp_target + Vector3i.RIGHT) == blue, "the outside stamp keeps the second material")
		expect(State.selection.is_empty(), "the selection stays clear after the stamp")
	)


func _center_option() -> void:
	step("Given a file frame with center off by default", func():
		expect(not plugin_node._options.get_node("Center").button_pressed, "the center option starts off")
		_select_frame(0)
	)
	await _await_source()
	step("When the user stamps in an empty document", func():
		State.get_current_voxel_frame().clear()
		sync_viewport()
		stamp_target = _target(Vector3.ZERO)
		_click(Vector3.ZERO)
	)
	await _settle()
	step("Then the stamp keeps the source frame offsets", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 2, "the stamp contains the two source cells")
		expect(frame.has(stamp_target + Vector3i(10, 0, 10)), "the first cell keeps its frame X and Z offset")
		expect(frame.has(stamp_target + Vector3i(11, 0, 10)), "the second cell keeps its frame X and Z offset")
	)
	step("When the user turns on center on cursor", func():
		plugin_node._options.get_node("Center").button_pressed = true
	)
	await _await_source()
	step("When the user stamps in the cleared document", func():
		var frame := State.get_current_voxel_frame()
		frame.clear()
		State.undo_redo.clear_history()
		sync_viewport()
		stamp_target = _target(Vector3.ZERO)
		_click(Vector3.ZERO)
	)
	await _settle()
	step("Then the stamp centers its bounds on the cursor", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 2, "the centered stamp contains two cells")
		expect(frame.get_material(stamp_target) == metal, "the centered stamp starts at the cursor")
		expect(frame.get_material(stamp_target + Vector3i.RIGHT) == blue, "the centered stamp keeps the cell offset")
	)


func _tab_state() -> void:
	step("Given a file frame stamp with center on", func():
		plugin_node._options.get_node("Center").button_pressed = true
		_select_frame(0)
	)
	await _await_source()
	step("When the user opens another tab", func():
		var second := State.new_document()
		var index := State.add_tab(second)
		State.activate_tab(index)
		expect(settings.stamp_pattern.is_empty(), "the new tab starts without a stamp")
		expect(panel.get_parent() == null, "the new tab hides the frame panel")
		expect(not plugin_node._options.get_node("Center").button_pressed, "the new tab starts with center off")
	)
	step("When the user returns to the first tab", func():
		State.activate_tab(0)
		expect(settings.stamp_pattern.size() == 2, "the first tab restores its stamp")
		expect(panel.visible, "the first tab restores the frame panel")
		expect(_selected_frame() == 0, "the first tab restores the selected frame")
		expect(plugin_node._options.get_node("Center").button_pressed, "the first tab restores center on")
	)


func _clear_file_source() -> void:
	step("Given a file frame stamp", func():
		_select_frame(0)
	)
	await _await_source()
	step("When the user clicks Clear", func():
		var clear_button: Button = plugin_node._options.get_node("Clear")
		expect(not clear_button.disabled, "clear is enabled with a file source")
		clear_button.pressed.emit()
	)
	step("Then the file source and panel clear", func():
		expect(settings.stamp_pattern.is_empty(), "the file stamp pattern clears")
		expect(plugin_node._file_document == null, "the file source unloads")
		expect(panel.get_parent() == null, "the frame panel leaves the viewport")
		expect(plugin_node._options.get_node("Clear").disabled, "clear disables without a source")
		expect(plugin_node._options.get_node("Source").text == "No stamp source", "the label returns to no source")
	)
	step("When the user presses in the viewport", func():
		_click(Vector3.ZERO)
	)
	await _settle()
	step("Then no stamp is placed", func():
		expect(State.get_current_voxel_frame().count() == 0, "the cleared stamp leaves the frame empty")
		expect(not State.undo_redo.has_undo(), "the cleared stamp adds no history")
	)


func _clear_selection_source() -> void:
	step("Given a selection stamp", func():
		var frame := State.get_current_voxel_frame()
		frame.set_cells({Vector3i.ZERO: metal, Vector3i.RIGHT: blue})
		State.selection.from_box(Vector3i.ZERO, Vector3i.RIGHT)
		State.selection_changed.emit()
		plugin_node.use_current_selection()
		expect(State.selection.is_empty(), "the selection clears after the capture")
	)
	await _await_source()
	step("When the user clicks Clear", func():
		var clear_button: Button = plugin_node._options.get_node("Clear")
		expect(not clear_button.disabled, "clear is enabled with a selection source")
		clear_button.pressed.emit()
	)
	step("Then the selection source clears", func():
		expect(settings.stamp_pattern.is_empty(), "the selection stamp pattern clears")
		expect(plugin_node._selection_source_frame == null, "the selection snapshot clears")
		expect(plugin_node._options.get_node("Clear").disabled, "clear disables without a source")
		expect(plugin_node._options.get_node("Source").text == "No stamp source", "the label returns to no source")
	)


func _no_source() -> void:
	step("Given the stamp tool without a source", func():
		settings.clear_stamp()
	)
	step("When the user presses in the viewport", func():
		_click(Vector3.ZERO)
	)
	await _settle()
	step("Then no cell and no history action appear", func():
		expect(State.get_current_voxel_frame().count() == 0, "the empty stamp leaves the frame empty")
		expect(not State.undo_redo.has_undo(), "the empty stamp creates no history action")
		expect(not State.edit_busy(), "the empty stamp opens no edit")
	)


func _invalid_file() -> void:
	step("Given a valid file frame stamp", func():
		_select_frame(0)
	)
	await _await_source()
	step("When the user chooses a missing file", func():
		plugin_node.open_source_file("user://missing_stamp_source.lve")
		expect(plugin_node._file_path == source_path, "the invalid file keeps the previous file")
		expect(settings.stamp_pattern.size() == 2, "the invalid file keeps the previous stamp")
		expect(panel._buttons.size() == 2, "the invalid file keeps the frame list")
		expect(plugin_node._options.get_node("Error").visible, "the invalid file shows an error")
	)


func _panel_lifecycle() -> void:
	step("Given a loaded file frame", func():
		_select_frame(0)
	)
	await _await_source()
	step("When the user switches to the brush tool", func():
		activate_tool("Toolbar")
	)
	step("Then the frame panel leaves the viewport", func():
		expect(panel.get_parent() == null, "the stamp panel hides with its tool")
	)
	step("When the user returns to the stamp tool", func():
		activate_tool("stamp")
	)
	step("Then the same file and frame return", func():
		expect(panel.get_parent() == main.get_node("%Viewport"), "the stamp panel returns to the viewport")
		expect(panel.visible, "the stamp panel is visible")
		expect(panel._buttons.size() == 2, "the frame list stays loaded")
		expect(_selected_frame() == 0, "the selected frame stays current")
	)


func _make_source_file() -> void:
	source_document = VoxelDocument.new()
	source_document.active_layer().frames[0].set_cell(Vector3i(10, 0, 10), metal)
	source_document.active_layer().frames[0].set_cell(Vector3i(11, 0, 10), blue)
	source_document.add_frame()
	source_document.active_layer().frames[1].set_cell(Vector3i(-5, 0, -5), green)
	expect(source_document.save_file(source_path) == OK, "the stamp source file saves")


func _select_frame(index: int) -> void:
	plugin_node.open_source_file(source_path)
	if index != 0:
		_select_frame_button(index)


func _select_frame_button(index: int) -> void:
	var button: Button = panel._buttons[index]
	button.button_pressed = true
	button.pressed.emit()


func _selected_frame() -> int:
	for index in panel._buttons.size():
		if panel._buttons[index].button_pressed:
			return index
	return -1


func _await_source() -> void:
	for i in 600:
		if plugin_node == null or plugin_node._source_job == null:
			break
		await get_tree().process_frame
	await get_tree().process_frame


func _settle() -> void:
	var tool: Node = plugin_node._tool
	for i in 600:
		if not State.edit_busy() and tool._job == null and tool._edit == null:
			break
		await get_tree().process_frame
	await get_tree().process_frame


func _target(world: Vector3) -> Vector3i:
	return aim(camera_rig().unproject_position(world)).target


func _click(world: Vector3) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = camera_rig().unproject_position(world)
	event.pressed = true
	viewport.push_input(event)
	event.pressed = false
	viewport.push_input(event)
