extends "res://tests/test.gd"

# Editor chrome: the status bar dimensions, the frame thumbnail, the tool menu
# button, the startup document, the history buttons, and the camera menu. Each
# case drives one shared editor control, so one process covers them.

var status: EditorStatusBar
var thumbnail_renders := 0
var thumbnail_frame: VoxelFrame
var brush_button: MenuButton
var startup_menu: Node
var session_path := ""
var saved_path := ""
var menu_bar: Node
var undo_btn: Button
var redo_btn: Button
var operation := 0
var camera_menu_btn: MenuButton
var mcp_status: EditorStatusBar
var mcp_blocker: TCPServer
var mcp_client: StreamPeerTCP
var mcp_settings_path := ""
var mcp_saved_path := ""
var mcp_saved_port := 0


func _ready() -> void:
	timeout = 20.0
	test("the status bar shows the current document dimensions", _status_run, "status_bar")
	test("thumbnail requests coalesce and render the final document state", _thumbnail_run, "thumbnail_updates")
	test("the tool menu button selects on the first click and opens its menu on the second", _tool_select_run, "tool_select")
	test("the editor reopens the last document or the Flamingo sample", _startup_run, "startup_document")
	test("the menu bar undo and redo buttons follow the edit history", _history_run, "history")
	test("the camera menu drives views, projection, and shading", _camera_menu_run, "control_bar_views")
	test("the status bar toggles the MCP server and saves the state", _mcp_toggle_run, "mcp_toggle")
	test("a busy MCP port keeps the server off", _mcp_bind_failure_run, "mcp_bind_failure")


# Each case starts from a clean document and history. The cases share one
# process, so no case may inherit another case's document or undo stack.
func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	State.clear_selection()
	State.symmetry_axes = 0
	thumbnail_renders = 0
	thumbnail_frame = null


func after_test() -> void:
	if VoxelImageRenderer.frame_rendered.is_connected(_thumbnail_rendered):
		VoxelImageRenderer.frame_rendered.disconnect(_thumbnail_rendered)
	if is_instance_valid(status):
		status.queue_free()
		status = null
	if is_instance_valid(mcp_status):
		mcp_status.queue_free()
		mcp_status = null
	if mcp_blocker != null:
		mcp_blocker.stop()
		mcp_blocker = null
	if mcp_client != null:
		mcp_client.disconnect_from_host()
		mcp_client = null
	if not mcp_settings_path.is_empty():
		DirAccess.remove_absolute(mcp_settings_path)
		mcp_settings_path = ""
	if is_instance_valid(main) and not mcp_saved_path.is_empty():
		main.call("set_mcp_enabled", false, false)
		main.set("interface_settings_path", mcp_saved_path)
		main.set("mcp_port", mcp_saved_port)
		main.set_ui_scale(0.0, false)
		mcp_saved_path = ""
	if is_instance_valid(brush_button) and brush_button.get_popup().visible:
		brush_button.get_popup().hide()
	if is_instance_valid(camera_menu_btn) and camera_menu_btn.get_popup().visible:
		camera_menu_btn.get_popup().hide()
	# The camera menu case leaves the viewport unshaded and orthographic.
	var scene := viewport_scene()
	if scene != null:
		editor_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
	await get_tree().process_frame


func _status_run() -> void:
	step("Given the status bar and an empty document", func():
		status = load("res://ui/StatusBar/status_bar.tscn").instantiate()
		main.add_child(status)
	)
	await get_tree().process_frame
	step("Then the empty document shows zero dimensions", func():
		var text: String = status.get_node("StatusLeft").text
		expect(text.begins_with("#" + State.current_color.to_html(false)), "the color comes first")
		expect(text.contains("0×0×0"), "the empty document shows zero dimensions")
		expect(text.contains("#1/1"), "the frame number uses a hash")
		expect(not text.contains("Frame "), "the status bar omits the word Frame")
	)
	step("Then the version link opens the releases page", func():
		var link: LinkButton = status.get_node("Version")
		var version := str(ProjectSettings.get_setting("application/config/version", ""))
		expect(link.text == "v" + version, "the status bar shows the application version")
		expect(link.uri == EditorStatusBar.RELEASES_URL, "the version link opens the releases page")
	)
	step("When a voxel is painted", func():
		State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var affected: Array[Vector3i] = []
		State.cells_changed.emit(State.current_frame, affected)
	)
	await get_tree().process_frame
	step("Then the status bar shows the new dimensions", func():
		expect(status.get_node("StatusLeft").text.contains("1×1×1"), "painting a voxel updates the shown dimensions")
	)
	step("When the only voxel is erased", func():
		State.document.erase(0, Vector3i.ZERO)
		var affected: Array[Vector3i] = []
		State.chunks_changed.emit(State.current_frame, affected)
	)
	await get_tree().process_frame
	step("Then the status bar returns to zero dimensions", func():
		expect(status.get_node("StatusLeft").text.contains("0×0×0"), "erasing the last voxel shrinks the shown dimensions")
	)


func _mcp_toggle_run() -> void:
	mcp_saved_path = str(main.get("interface_settings_path"))
	mcp_saved_port = int(main.get("mcp_port"))
	mcp_settings_path = "user://mcp_toggle_test.cfg"
	DirAccess.remove_absolute(mcp_settings_path)
	step("Given a free port and a temporary settings file", func():
		main.set("interface_settings_path", mcp_settings_path)
		main.set("mcp_port", 0)
		expect(not bool(main.call("is_mcp_enabled")), "the server starts off")
		mcp_status = load("res://ui/StatusBar/status_bar.tscn").instantiate()
		main.add_child(mcp_status)
	)
	await get_tree().process_frame
	var button: Button = mcp_status.get_node("%MCP")
	step("Then the status icon is visible and off", func():
		expect(button.visible, "the MCP icon is visible")
		expect(button.tooltip_text.contains("off"), "the tooltip says the server is off")
	)
	step("When the user clicks the status icon", func():
		button.pressed.emit()
	)
	await get_tree().process_frame
	step("Then the server listens and saves the on state", func():
		expect(bool(main.call("is_mcp_enabled")), "the server starts")
		var port := int(main.call("mcp_local_port"))
		expect(port > 0, "the server has a port")
		expect(button.tooltip_text.contains("127.0.0.1"), "the tooltip shows the endpoint")
		var settings := ConfigFile.new()
		settings.load(mcp_settings_path)
		expect(bool(settings.get_value("agent", "mcp_enabled", false)), "the on state is saved")
		mcp_client = StreamPeerTCP.new()
		expect(mcp_client.connect_to_host("127.0.0.1", port) == OK, "a client can reach the port")
	)
	await _wait_client(mcp_client)
	step("Then the server accepts the client", func():
		expect(mcp_client.get_status() == StreamPeerTCP.STATUS_CONNECTED, "the server accepts the client")
		mcp_client.disconnect_from_host()
		mcp_client = null
	)
	step("When the user clicks the status icon again", func():
		button.pressed.emit()
	)
	await get_tree().process_frame
	step("Then the server stops and saves the off state", func():
		expect(not bool(main.call("is_mcp_enabled")), "the server stops")
		expect(int(main.call("mcp_local_port")) == 0, "the port is free")
		var settings := ConfigFile.new()
		settings.load(mcp_settings_path)
		expect(not bool(settings.get_value("agent", "mcp_enabled", true)), "the off state is saved")
	)
	step("When the UI scale changes", func():
		var settings := ConfigFile.new()
		settings.set_value("agent", "mcp_enabled", true)
		settings.save(mcp_settings_path)
		main.call("set_ui_scale", 1.0, true)
	)
	step("Then the scale write keeps the agent state", func():
		var settings := ConfigFile.new()
		settings.load(mcp_settings_path)
		expect(bool(settings.get_value("agent", "mcp_enabled", false)), "the agent state survives the scale write")
		expect(is_equal_approx(float(settings.get_value("interface", "scale", 0.0)), 1.0), "the scale is saved")
	)


func _mcp_bind_failure_run() -> void:
	mcp_saved_path = str(main.get("interface_settings_path"))
	mcp_saved_port = int(main.get("mcp_port"))
	mcp_settings_path = "user://mcp_toggle_test.cfg"
	DirAccess.remove_absolute(mcp_settings_path)
	mcp_blocker = TCPServer.new()
	step("Given a blocked port and the status bar", func():
		expect(mcp_blocker.listen(0, "127.0.0.1") == OK, "the blocker listens")
		main.set("interface_settings_path", mcp_settings_path)
		main.set("mcp_port", mcp_blocker.get_local_port())
		mcp_status = load("res://ui/StatusBar/status_bar.tscn").instantiate()
		main.add_child(mcp_status)
	)
	await get_tree().process_frame
	step("When the user clicks the status icon", func():
		var button: Button = mcp_status.get_node("%MCP")
		button.pressed.emit()
	)
	await get_tree().process_frame
	step("Then the server stays off and the dialog explains why", func():
		expect(not bool(main.call("is_mcp_enabled")), "the server stays off")
		var dialog: AcceptDialog = mcp_status.get_node("%MCPError")
		expect(dialog.visible, "the error dialog is shown")
		expect(dialog.dialog_text.contains("127.0.0.1"), "the dialog names the address")
		dialog.hide()
	)


func _wait_client(client: StreamPeerTCP) -> void:
	for _frame in 100:
		client.poll()
		if client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			return
		await get_tree().process_frame


func _thumbnail_run() -> void:
	thumbnail_frame = State.get_current_voxel_frame()
	VoxelImageRenderer.frame_rendered.connect(_thumbnail_rendered)
	step("When the user repeatedly edits one frame", func():
		for x in 32:
			State.paint(Vector3i(x, 0, 0), VoxelFrame.material(Color.BLUE))
			VoxelImageRenderer.request_frame_render(0)
	)
	await get_tree().create_timer(0.1).timeout
	step("Then the thumbnail waits for the edit burst to finish", func():
		expect(thumbnail_renders == 0, "the edit burst has no intermediate thumbnail")
	)
	while thumbnail_renders == 0:
		await get_tree().process_frame
	step("Then the final thumbnail is rendered once", func():
		expect(thumbnail_renders == 1, "the burst produces one thumbnail")
		expect(thumbnail_frame.count() == 32, "the final document keeps all edited cells")
	)
	step("When the user edits the same frame again", func():
		State.paint(Vector3i(32, 0, 0), VoxelFrame.material(Color.RED))
		VoxelImageRenderer.request_frame_render(0)
	)
	while thumbnail_renders < 2:
		await get_tree().process_frame
	step("Then the thumbnail refreshes after the next edit", func():
		expect(thumbnail_renders == 2, "the next edit produces another thumbnail")
		expect(thumbnail_frame.get_color(Vector3i(32, 0, 0)) == Color.RED, "the new voxel keeps its red color")
	)


func _thumbnail_rendered(index: int, _texture: ImageTexture) -> void:
	if index == 0 and State.get_voxel_frame(index) == thumbnail_frame:
		thumbnail_renders += 1


func _tool_select_run() -> void:
	step("Given the inactive brush tool button", func():
		for b in main.get_node("%ToolBar").get_children():
			if b is MenuButton and b.tooltip_text == "Brush tools":
				brush_button = b
				break
		expect(brush_button != null, "the brush tool is a menu button")
		brush_button.button_pressed = false
	)

	step("When the user clicks the inactive button", func():
		_tool_click(brush_button)
	)

	step("Then the tool activates and the menu stays closed", func():
		expect(brush_button.button_pressed, "the button is pressed")
		expect(not brush_button.get_popup().is_visible(), "the menu stays closed")
	)

	step("When the user clicks the active button", func():
		_tool_click(brush_button)
	)

	step("Then the menu opens", func():
		expect(brush_button.get_popup().is_visible(), "the menu opens")
		expect(brush_button.button_pressed, "the button stays pressed")
	)

	step("When the user dismisses the menu", func():
		brush_button.get_popup().hide()
	)

	step("Then the tool stays active", func():
		expect(brush_button.button_pressed, "the button stays pressed after the menu closes")
	)


func _tool_click(button: Control) -> void:
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = button.get_global_rect().get_center()
	click.pressed = true
	get_tree().root.push_input(click, true)
	click.pressed = false
	get_tree().root.push_input(click, true)


func _startup_run() -> void:
	step("Given a saved copy of a document", func():
		startup_menu = main.get_node("%MenuBar")
		var stamp := Time.get_ticks_usec()
		session_path = "user://startup_document_%s.cfg" % stamp
		saved_path = "user://startup_document_%s.lve" % stamp
		expect(startup_menu.open_document("res://Flamingo.lve", false), "the sample document opens")
		var document: VoxelDocument = State.document
		expect(document.save_file(saved_path, null, document.encode_document()) == OK, "the document copy saves")
		State.remember_document(saved_path, session_path)
	)

	step("Then the session stores the document path", func():
		expect(State.last_document_path(session_path) == saved_path, "the saved path is the last document")
	)

	step("When the editor starts with that session", func():
		startup_menu.current_save_path = ""
		main._restore_startup_document(true, session_path)
	)

	step("Then the remembered document opens with its save path", func():
		expect(startup_menu.current_save_path == saved_path, "the remembered document keeps its save path")
	)

	step("When the editor starts without a remembered document", func():
		State.forget_document(session_path)
		expect(State.last_document_path(session_path).is_empty(), "the session has no document")
		startup_menu.current_save_path = ""
		main._restore_startup_document(true, session_path)
	)

	step("Then the Flamingo sample opens as an unsaved document", func():
		expect(State.document.file_path == "res://Flamingo.lve", "the sample document is open")
		expect(startup_menu.current_save_path.is_empty(), "the sample has no save path")
	)

	for path in [saved_path, session_path]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _history_run() -> void:
	step("Given the menu bar and a fresh document", func():
		menu_bar = main.get_node("Content/VBoxContainer/MenuBar")
		undo_btn = menu_bar.get_node("UndoBtn")
		redo_btn = menu_bar.get_node("RedoBtn")
	)

	step("Then both history buttons are disabled", func():
		expect(undo_btn.disabled, "undo is disabled without history")
		expect(redo_btn.disabled, "redo is disabled without history")
	)

	step("When the user paints a voxel in a stroke", func():
		var tx := State.begin_edit()
		State.paint(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.finish_edit(tx)
	)

	step("Then undo is enabled and redo is disabled", func():
		expect(not undo_btn.disabled, "undo is enabled after a stroke")
		expect(redo_btn.disabled, "redo stays disabled after a new edit")
	)

	step("When the user undoes the stroke", func():
		menu_bar._on_undo_btn_pressed()
	)

	step("Then undo is disabled and redo is enabled", func():
		expect(undo_btn.disabled, "undo is disabled at the start of the history")
		expect(not redo_btn.disabled, "redo is enabled after an undo")
	)

	step("When the user redoes the stroke", func():
		menu_bar._on_redo_btn_pressed()
	)

	step("Then undo is enabled and redo is disabled", func():
		expect(not undo_btn.disabled, "undo is enabled after a redo")
		expect(redo_btn.disabled, "redo is disabled at the end of the history")
	)

	step("When adding a frame records a non-stroke action", func():
		State.add_frame()
	)

	step("Then undo is enabled for the frame action", func():
		expect(not undo_btn.disabled, "undo is enabled after adding a frame")
		expect(redo_btn.disabled, "redo stays disabled after adding a frame")
	)

	step("When a foreground operation starts", func():
		operation = State.begin_operation("Test operation", -1, true, self)
	)

	step("Then both history buttons are disabled while busy", func():
		expect(undo_btn.disabled, "undo is disabled while busy")
		expect(redo_btn.disabled, "redo is disabled while busy")
	)

	step("When the foreground operation finishes", func():
		State.finish_operation(operation)
	)

	step("Then the history buttons follow the history again", func():
		expect(not undo_btn.disabled, "undo is enabled after the operation")
		expect(redo_btn.disabled, "redo is disabled after the operation")
	)


func _camera_popup() -> PopupMenu:
	return camera_menu_btn.get_popup()


func _camera_index(text: String) -> int:
	var popup := _camera_popup()
	for i in popup.item_count:
		if str(popup.get_item_text(i)).to_lower() == text:
			return i
	return -1


func _pick_view(text: String) -> void:
	var i := _camera_index(text)
	expect(i >= 0, "the menu holds a %s item" % text)
	if i >= 0:
		_camera_popup().index_pressed.emit(i)


func _camera_menu_run() -> void:
	step("Given the editor control bar and viewport", func():
		editor_viewport()
		camera_menu_btn = camera_menu()
	)

	step("When the user picks Front in the camera menu", func():
		_pick_view("front")
	)
	step("Then the camera faces the front", func():
		expect(is_equal_approx(camera_rig()._yaw, 0.0), "front view sets yaw 0")
		expect(is_equal_approx(camera_rig()._pitch, 0.0), "front view sets pitch 0")
	)

	step("When the user picks Bottom in the camera menu", func():
		_pick_view("bottom")
	)
	step("Then the camera moves below", func():
		expect(is_equal_approx(camera_rig()._pitch, deg_to_rad(-89.0)), "bottom view sets pitch -89 degrees")
	)

	step("When the user picks Orthographic in the camera menu", func():
		_pick_view("orthographic")
	)
	step("Then the camera turns orthographic and the light uses orthogonal shadow mapping", func():
		expect(camera_rig().is_orthogonal, "the camera uses orthogonal projection")
		expect(_camera_popup().is_item_checked(_camera_index("orthographic")), "the Orthographic item shows checked")
		var light := viewport_scene().get_node("Light")
		expect(light.directional_shadow_mode == DirectionalLight3D.SHADOW_ORTHOGONAL, "the light uses orthogonal shadow mapping")
	)

	step("When the user picks Orthographic again", func():
		_pick_view("orthographic")
	)
	step("Then the camera returns to perspective and the light returns to split shadow mapping", func():
		expect(not camera_rig().is_orthogonal, "the camera uses perspective projection")
		expect(not _camera_popup().is_item_checked(_camera_index("orthographic")), "the Orthographic item shows unchecked")
		var light := viewport_scene().get_node("Light")
		expect(light.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS, "the light uses split shadow mapping")
	)

	step("When the user picks Unshaded in the camera menu", func():
		_pick_view("unshaded")
	)
	step("Then the viewport renders unshaded and the item shows checked", func():
		var svp := editor_viewport() as SubViewport
		expect(svp.debug_draw == Viewport.DEBUG_DRAW_UNSHADED, "the viewport renders unshaded")
		expect(_camera_popup().is_item_checked(_camera_index("unshaded")), "the Unshaded item shows checked")
	)
