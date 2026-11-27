extends "res://tests/test.gd"


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
var mcp_live_port := 0
var clipboard_before := ""
var clipboard_saved := false
var settings_saved_path := ""
var mcp_saved_port := 0
var mcp_port_saved := false
var startup_settings_path := ""
var startup_session_path := ""
var startup_documents := PackedStringArray()
var migration_paths := PackedStringArray()


func _ready() -> void:
	timeout = 20.0
	test("the status bar shows the current document dimensions", _status_run, "status_bar")
	test("thumbnail requests coalesce and render the final document state", _thumbnail_run, "thumbnail_updates")
	test("the tool menu button selects on the first click and opens its menu on the second", _tool_select_run, "tool_select")
	test("the editor reopens the last document or the splash sample", _startup_run, "startup_document")
	test("a restart without open documents opens the splash", _startup_closed_run, "startup_closed_documents")
	test("a new version opens the splash as the active first tab", _startup_splash_run, "startup_splash")
	test("a first run opens the splash once", _startup_first_run, "startup_first_run")
	test("an existing splash tab moves to the first position", _splash_reorder_run, "splash_reorder")
	test("the legacy settings merge into one file", _settings_migration_run, "settings_migration")
	test("the menu bar undo and redo buttons follow the edit history", _history_run, "history")
	test("the camera menu drives views and projection, and the environment row drives shading", _camera_menu_run, "control_bar_views")
	test("the status bar toggles the MCP server and saves the state", _mcp_toggle_run, "mcp_toggle")
	test("a busy MCP port keeps the server off", _mcp_bind_failure_run, "mcp_bind_failure")


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
	if clipboard_saved:
		DisplayServer.clipboard_set(clipboard_before)
		clipboard_saved = false
	if not mcp_settings_path.is_empty():
		DirAccess.remove_absolute(mcp_settings_path)
		mcp_settings_path = ""
	if not startup_session_path.is_empty() and startup_session_path != startup_settings_path:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(startup_session_path))
	startup_session_path = ""
	if not startup_settings_path.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(startup_settings_path))
		startup_settings_path = ""
	for path in startup_documents:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	startup_documents.clear()
	for path in migration_paths:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	migration_paths.clear()
	if is_instance_valid(main) and not settings_saved_path.is_empty():
		main.call("set_mcp_enabled", false, false)
		main.set("settings_path", settings_saved_path)
		if mcp_port_saved:
			main.set("mcp_port", mcp_saved_port)
			mcp_port_saved = false
		main.set_ui_scale(0.0, false)
		settings_saved_path = ""
	if is_instance_valid(brush_button) and brush_button.get_popup().visible:
		brush_button.get_popup().hide()
	if is_instance_valid(camera_menu_btn) and camera_menu_btn.get_popup().visible:
		camera_menu_btn.get_popup().hide()
	var scene := viewport_scene()
	if scene != null:
		scene.get_node("%Shaded").button_pressed = true
		editor_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
		scene._sync_shading_controls()
	await get_tree().process_frame


func _status_run() -> void:
	step("Given the status bar and an empty document", func():
		status = load("res://ui/StatusBar/StatusBar.tscn").instantiate()
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
	settings_saved_path = str(main.get("settings_path"))
	mcp_saved_port = int(main.get("mcp_port"))
	mcp_port_saved = true
	mcp_settings_path = "user://mcp_toggle_test.cfg"
	DirAccess.remove_absolute(mcp_settings_path)
	step("Given a free port and a temporary settings file", func():
		main.set("settings_path", mcp_settings_path)
		main.set("mcp_port", 0)
		expect(not bool(main.call("is_mcp_enabled")), "the server starts off")
		clipboard_before = DisplayServer.clipboard_get()
		clipboard_saved = true
		mcp_status = load("res://ui/StatusBar/StatusBar.tscn").instantiate()
		main.add_child(mcp_status)
	)
	await get_tree().process_frame
	var button: Button = mcp_status.get_node("%MCP")
	step("Then the status icon is visible and off", func():
		expect(button.visible, "the MCP icon is visible")
		expect(button.tooltip_text == "MCP server off. Click to start.", "the tooltip says the server is off")
	)
	step("When the user clicks the status icon", func():
		button.pressed.emit()
	)
	await get_tree().process_frame
	step("Then the server listens and saves the on state", func():
		expect(bool(main.call("is_mcp_enabled")), "the server starts")
		var port := int(main.call("mcp_local_port"))
		mcp_live_port = port
		expect(port > 0, "the server has a port")
		expect(button.tooltip_text == "MCP server on at http://127.0.0.1:%d/mcp. Click to stop." % port, "the tooltip shows the endpoint")
		var settings := ConfigFile.new()
		settings.load(mcp_settings_path)
		expect(bool(settings.get_value("agent", "mcp_enabled", false)), "the on state is saved")
		mcp_client = StreamPeerTCP.new()
		expect(mcp_client.connect_to_host("127.0.0.1", port) == OK, "a client can reach the port")
	)
	step("Then the setup prompt is in the clipboard", func():
		var notice: Label = mcp_status.get_node("%Notice")
		expect(notice.visible, "the status bar shows a notice")
		expect(notice.text == "Setup prompt copied to the clipboard", "the notice names the clipboard")
		if DisplayServer.get_name() == "headless":
			return
		var prompt := DisplayServer.clipboard_get()
		expect(prompt.contains("http://127.0.0.1:%d/mcp" % mcp_live_port), "the prompt names the endpoint")
		expect(prompt.contains("docs/MCP.md"), "the prompt links to the MCP doc")
	)
	step("When the notice time ends", func():
		mcp_status.get_node("NoticeTimer").timeout.emit()
	)
	step("Then the notice clears", func():
		expect(not mcp_status.get_node("%Notice").visible, "the notice hides")
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
		expect(button.tooltip_text == "MCP server off. Click to start.", "the tooltip drops the endpoint")
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
	settings_saved_path = str(main.get("settings_path"))
	mcp_saved_port = int(main.get("mcp_port"))
	mcp_port_saved = true
	mcp_settings_path = "user://mcp_toggle_test.cfg"
	DirAccess.remove_absolute(mcp_settings_path)
	mcp_blocker = TCPServer.new()
	step("Given a blocked port and the status bar", func():
		expect(mcp_blocker.listen(0, "127.0.0.1") == OK, "the blocker listens")
		main.set("settings_path", mcp_settings_path)
		main.set("mcp_port", mcp_blocker.get_local_port())
		mcp_status = load("res://ui/StatusBar/StatusBar.tscn").instantiate()
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
		startup_settings_path = "user://startup_document_%s.cfg" % stamp
		settings_saved_path = str(main.get("settings_path"))
		main.set("settings_path", startup_settings_path)
		session_path = startup_settings_path
		saved_path = "user://startup_document_%s.lve" % stamp
		var settings := ConfigFile.new()
		settings.set_value("application", "version", str(ProjectSettings.get_setting("application/config/version", "")))
		expect(settings.save(startup_settings_path) == OK, "the settings file saves")
		expect(startup_menu.open_document("res://splash.lve", false), "the splash document opens")
		var document: VoxelDocument = State.document
		expect(document.save_file(saved_path, null, document.encode_document()) == OK, "the document copy saves")
		startup_documents.append(saved_path)
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

	step("Then the splash sample opens as an unsaved document", func():
		expect(State.document.file_path == "res://splash.lve", "the splash document is open")
		expect(startup_menu.current_save_path.is_empty(), "the sample has no save path")
	)


func _startup_closed_run() -> void:
	step("Given a session with a remembered document", func():
		startup_menu = main.get_node("%MenuBar")
		var stamp := Time.get_ticks_usec()
		startup_settings_path = "user://startup_closed_%s.cfg" % stamp
		startup_session_path = startup_settings_path
		settings_saved_path = str(main.get("settings_path"))
		main.set("settings_path", startup_settings_path)
		var saved := "user://startup_closed_%s.lve" % stamp
		expect(startup_menu.open_document("res://splash.lve", false), "the splash document opens")
		var document: VoxelDocument = State.document
		expect(document.save_file(saved, null, document.encode_document()) == OK, "the document copy saves")
		startup_documents.append(saved)
		State.remember_document(saved, startup_session_path)
		expect(State.last_document_path(startup_session_path) == saved, "the session remembers the document")
	)

	step("When the last document closes", func():
		var blank := State.new_document()
		var documents: Array[VoxelDocument] = [blank]
		State.set_tabs(documents, 0)
		State.remember_session(startup_session_path)
	)

	step("Then the session forgets the document", func():
		expect(State.last_document_path(startup_session_path).is_empty(), "the session has no last document")
	)

	step("When the editor starts again", func():
		main._restore_startup_document(true, startup_session_path)
	)

	step("Then the splash opens", func():
		expect(State.tabs.size() == 1, "only the splash opens")
		expect(State.document.file_path == "res://splash.lve", "the splash is the active document")
		expect(startup_menu.current_save_path.is_empty(), "the splash has no save path")
	)


func _startup_splash_run() -> void:
	step("Given two saved documents and a new version", func():
		var stamp := Time.get_ticks_usec()
		startup_settings_path = "user://startup_splash_%s.cfg" % stamp
		settings_saved_path = str(main.get("settings_path"))
		main.set("settings_path", startup_settings_path)
		startup_session_path = startup_settings_path
		var first := "user://startup_splash_a_%s.lve" % stamp
		var second := "user://startup_splash_b_%s.lve" % stamp
		var sample := VoxelDocument.load_file("res://splash.lve")
		expect(sample != null, "the splash document loads")
		var data := sample.encode_document()
		expect(sample.save_file(first, null, data) == OK, "the first copy saves")
		expect(sample.save_file(second, null, data) == OK, "the second copy saves")
		startup_documents.append(first)
		startup_documents.append(second)
		var settings := ConfigFile.new()
		settings.set_value("interface", "scale", 1.0)
		settings.set_value("agent", "mcp_enabled", true)
		settings.set_value("files", "tabs", PackedStringArray([first, second]))
		settings.set_value("files", "active", 1)
		expect(settings.save(startup_settings_path) == OK, "the settings file saves")
	)

	step("When the editor starts with a new version", func():
		main._restore_startup_document(true, startup_session_path)
	)

	step("Then the splash is the first and active tab", func():
		expect(State.tabs.size() == 3, "all saved documents stay open")
		expect(State.active_tab == 0, "the splash is the active tab")
		expect(State.document.file_path == "res://splash.lve", "the active document is the splash")
		expect(State.document.edit_save_path.is_empty(), "the splash has no save path")
		expect(State.tabs[1].edit_save_path == startup_documents[0], "the first saved document loads")
		expect(State.tabs[2].edit_save_path == startup_documents[1], "the second saved document loads")
	)

	step("Then the settings keep every value", func():
		var settings := ConfigFile.new()
		expect(settings.load(startup_settings_path) == OK, "the settings file loads")
		expect(settings.get_value("files", "tabs") == PackedStringArray([startup_documents[0], startup_documents[1]]), "the session keeps both paths")
		expect(str(settings.get_value("application", "version", "")) == str(ProjectSettings.get_setting("application/config/version", "")), "the version is recorded")
		expect(bool(settings.get_value("agent", "mcp_enabled", false)), "the agent setting survives")
		expect(is_equal_approx(float(settings.get_value("interface", "scale", 0.0)), 1.0), "the interface setting survives")
	)

	step("When the app quits with the splash active", func():
		State.remember_session(startup_session_path)
	)

	step("Then the previously active saved tab stays", func():
		var settings := ConfigFile.new()
		expect(settings.load(startup_session_path) == OK, "the settings file loads")
		expect(int(settings.get_value("files", "active", -1)) == 1, "the saved active tab survives the splash")
		expect(settings.get_value("files", "tabs") == PackedStringArray([startup_documents[0], startup_documents[1]]), "the saved tabs survive the splash")
	)

	step("When the same version starts again", func():
		main._restore_startup_document(true, startup_session_path)
	)

	step("Then the splash does not open again", func():
		expect(State.tabs.size() == 2, "the splash does not open again")
		expect(State.active_tab == 1, "the saved active tab restores")
		expect(State.document.edit_save_path == startup_documents[1], "the saved active document is active")
	)

	step("When a later version starts", func():
		var settings := ConfigFile.new()
		settings.load(startup_settings_path)
		settings.set_value("application", "version", "0.0")
		expect(settings.save(startup_settings_path) == OK, "the old version saves")
		main._restore_startup_document(true, startup_session_path)
	)

	step("Then the splash opens again", func():
		expect(State.tabs.size() == 3, "the splash opens")
		expect(State.active_tab == 0, "the splash is active")
	)


func _startup_first_run() -> void:
	step("Given a new install without a settings file", func():
		startup_settings_path = "user://startup_first_%s.cfg" % Time.get_ticks_usec()
		settings_saved_path = str(main.get("settings_path"))
		main.set("settings_path", startup_settings_path)
		startup_session_path = startup_settings_path
		DirAccess.remove_absolute(ProjectSettings.globalize_path(startup_settings_path))
	)

	step("When the editor starts", func():
		main._restore_startup_document(true, startup_session_path)
	)

	step("Then the splash is the only open document", func():
		expect(State.tabs.size() == 1, "the splash does not open twice")
		expect(State.active_tab == 0, "the splash is active")
		expect(State.document.file_path == "res://splash.lve", "the splash is open")
		expect(State.document.edit_save_path.is_empty(), "the splash has no save path")
	)

	step("Then the version is recorded", func():
		var settings := ConfigFile.new()
		expect(settings.load(startup_settings_path) == OK, "the settings file saves")
		expect(str(settings.get_value("application", "version", "")) == str(ProjectSettings.get_setting("application/config/version", "")), "the version is recorded")
	)


func _splash_reorder_run() -> void:
	step("Given a document before an open splash", func():
		var document := VoxelDocument.new()
		var splash := VoxelDocument.load_file("res://splash.lve")
		expect(splash != null, "the splash loads")
		if splash == null:
			return
		var documents: Array[VoxelDocument] = [document, splash]
		State.set_tabs(documents, 0)
	)
	step("When the splash opens", func():
		main.call("_open_splash")
	)
	step("Then the splash is the first and active tab", func():
		expect(State.tabs.size() == 2, "both tabs stay open")
		expect(State.tabs[0].file_path == "res://splash.lve", "the splash is first")
		expect(State.active_tab == 0, "the splash is active")
	)


func _settings_migration_run() -> void:
	step("Given three legacy settings files", func():
		var stamp := Time.get_ticks_usec()
		var target := "user://settings_migration_%s.cfg" % stamp
		var interface_path := "user://interface_migration_%s.cfg" % stamp
		var session_path := "user://session_migration_%s.cfg" % stamp
		var dialog_path := "user://dialog_migration_%s.cfg" % stamp
		var broken_path := "user://broken_migration_%s.cfg" % stamp
		migration_paths.append(target)
		migration_paths.append(interface_path)
		migration_paths.append(session_path)
		migration_paths.append(dialog_path)
		migration_paths.append(broken_path)
		var interface_settings := ConfigFile.new()
		interface_settings.set_value("interface", "scale", 1.5)
		interface_settings.set_value("agent", "mcp_enabled", true)
		expect(interface_settings.save(interface_path) == OK, "the interface settings save")
		var session_settings := ConfigFile.new()
		session_settings.set_value("files", "tabs", PackedStringArray(["user://first.lve", "user://second.lve"]))
		session_settings.set_value("files", "active", 1)
		expect(session_settings.save(session_path) == OK, "the session settings save")
		var dialog_settings := ConfigFile.new()
		dialog_settings.set_value("files", "favorites", PackedStringArray(["user://"]))
		dialog_settings.set_value("files", "recent", PackedStringArray(["user://"]))
		dialog_settings.set_value("files", "last_dir", "user://")
		expect(dialog_settings.save(dialog_path) == OK, "the dialog settings save")
		var broken := FileAccess.open(broken_path, FileAccess.WRITE)
		expect(broken != null, "the broken legacy file opens")
		if broken != null:
			broken.store_string("[broken\nkey=1\n")
			broken.close()
		var broken_config := ConfigFile.new()
		expect(broken_config.load(broken_path) != OK, "the broken legacy file is unreadable")
		var target_settings := ConfigFile.new()
		target_settings.set_value("application", "version", "test")
		target_settings.set_value("interface", "scale", 2.0)
		expect(target_settings.save(target) == OK, "the target settings save")
		expect(State.migrate_settings(target, PackedStringArray([interface_path, session_path, dialog_path, broken_path])) == OK, "the migration succeeds")
	)

	step("Then one file holds every setting", func():
		var settings := ConfigFile.new()
		expect(settings.load(migration_paths[0]) == OK, "the target loads")
		expect(str(settings.get_value("application", "version", "")) == "test", "the target version stays")
		expect(is_equal_approx(float(settings.get_value("interface", "scale", 0.0)), 2.0), "the target value wins")
		expect(bool(settings.get_value("agent", "mcp_enabled", false)), "the agent setting moves")
		expect(settings.get_value("files", "tabs") == PackedStringArray(["user://first.lve", "user://second.lve"]), "the tabs move")
		expect(int(settings.get_value("files", "active", 0)) == 1, "the active tab moves")
		expect(settings.get_value("files", "favorites") == PackedStringArray(["user://"]), "the favorites move")
		expect(settings.get_value("files", "recent") == PackedStringArray(["user://"]), "the recent folders move")
		expect(str(settings.get_value("files", "last_dir", "")) == "user://", "the last folder moves")
	)

	step("Then the legacy files are gone", func():
		expect(not FileAccess.file_exists(migration_paths[1]), "the interface settings are gone")
		expect(not FileAccess.file_exists(migration_paths[2]), "the session settings are gone")
		expect(not FileAccess.file_exists(migration_paths[3]), "the dialog settings are gone")
		expect(FileAccess.file_exists(migration_paths[4]), "the unreadable legacy file stays")
	)

	step("When the migration runs again", func():
		expect(State.migrate_settings(migration_paths[0], PackedStringArray([migration_paths[1], migration_paths[2], migration_paths[3]])) == OK, "the second migration succeeds")
	)


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


func _field_of_view():
	return main.get_node("%Viewport").get_node("ControlBar/FieldOfView")


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

	step("When the user sets the field of view to 0", func():
		_field_of_view().value = 0.0
	)
	step("Then the camera turns orthographic and the light uses orthogonal shadow mapping", func():
		expect(camera_rig().is_orthogonal, "the camera uses orthogonal projection")
		expect(_camera_index("orthographic") < 0, "the camera menu no longer holds an Orthographic item")
		expect(is_equal_approx(_field_of_view().value, 0.0), "the field of view shows 0")
		var light := viewport_scene().get_node("Light")
		expect(light.directional_shadow_mode == DirectionalLight3D.SHADOW_ORTHOGONAL, "the light uses orthogonal shadow mapping")
	)

	step("When the user sets the field of view to 45", func():
		_field_of_view().value = 45.0
	)
	step("Then the camera returns to perspective and the light returns to split shadow mapping", func():
		expect(not camera_rig().is_orthogonal, "the camera uses perspective projection")
		expect(is_equal_approx(camera_rig().fov, 45.0), "the camera uses a 45 degree field of view")
		var light := viewport_scene().get_node("Light")
		expect(light.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS, "the light uses split shadow mapping")
	)

	step("When the user disables shading in the environment row", func():
		viewport_scene().get_node("%Shaded").button_pressed = false
	)
	step("Then the viewport renders unshaded and the row button shows unpressed", func():
		expect(viewport_scene().get_node("VoxelRenderer").unshaded, "the voxel meshes draw unshaded")
		expect(not viewport_scene().get_node("%Shaded").button_pressed, "the Shaded button shows unpressed")
	)
