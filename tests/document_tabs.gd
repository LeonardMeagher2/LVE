extends "res://tests/test.gd"


const TABS_SCENE := preload("res://ui/MenuBar/DocumentTabs.tscn")
const SAMPLE_DOCUMENT := "res://splash.lve"
const SESSION_PATH := "user://document_tabs_test.cfg"
const CORRUPT_PATH := "user://document_tabs_corrupt.cfg"

var tabs: TabBar
var _first: VoxelDocument
var _second: VoxelDocument
var _quit_seen := false
var _busy_operation := 0
var _recovery_entries_seen: Array = []


func _ready() -> void:
	test("each tab keeps its own document state", _state, "tab_state")
	test("the tab strip follows the open documents", _strip, "tab_strip")
	test("open reuses an empty tab and adds another for a second document", _open, "tab_open")
	test("the session stores the open tab paths", _session, "tab_session")
	test("a corrupt settings file is not overwritten by a session save", _corrupt_session, "corrupt_session")
	test("the runtime editor state is not serialized", _serialize, "tab_serialize")
	test("quitting asks to save each edited document", _quit, "quit_confirmation")
	test("a close request waits for a foreground operation", _quit_busy, "quit_busy")
	test("a settings write leaves no temporary file", _settings_atomic, "settings_atomic")
	test("a cancelled quit clears a pending close target", _close_target, "quit_close_target")
	test("the recovery prompt lists unsaved documents", _recovery_dialog, "recovery_dialog")


func before_test() -> void:
	State.stop()
	State.tabs.clear()
	var document := VoxelDocument.new()
	State.tabs.append(document)
	State.active_tab = 0
	State.document = document
	_quit_seen = false
	_recovery_entries_seen = []
	if is_instance_valid(main):
		var menu := main.get_node_or_null("%MenuBar")
		if menu != null:
			var dialog := menu.get_node_or_null("%CloseTabDialog")
			if dialog != null:
				dialog.hide()
			var recovery_dialog := menu.get_node_or_null("%RecoveryDialog")
			if recovery_dialog != null:
				recovery_dialog.hide()
			menu.call("_cancel_quit")


func after_test() -> void:
	if is_instance_valid(tabs):
		tabs.queue_free()
		tabs = null
	var directory := DirAccess.open("user://")
	if directory:
		directory.remove(SESSION_PATH.get_file())
		directory.remove(SESSION_PATH.get_file() + ".tmp")
		directory.remove(CORRUPT_PATH.get_file())
		directory.remove("quit_save_test.lve")


func _state() -> void:
	step("Given two documents in separate tabs", func():
		_first = VoxelDocument.new()
		_second = VoxelDocument.new()
		State.document = _first
		State.open_tab(_second)
	)
	step("Then both documents are open and the new one is active", func():
		expect(State.tabs.size() == 2, "both documents are open")
		expect(State.document == _second, "the opened document is active")
	)
	step("When the first tab gets its own frame, selection, size, and history", func():
		State.activate_tab(0)
		State.document.add_frame()
		State.current_frame = 1
		State.selection.add(Vector3i.ONE)
		State.set_size(Vector3i(4, 4, 4))
		State.activate_tab(1)
	)
	step("Then the second tab keeps its own state", func():
		expect(State.current_frame == 0, "the second document keeps frame zero")
		expect(State.selection.is_empty(), "the second document keeps its own selection")
		expect(not State.undo_redo.has_undo(), "the second document has no history")
		expect(State.document.size == Vector3i.ZERO, "the second document keeps its own size")
	)
	step("Then the first tab restores its state", func():
		State.activate_tab(0)
		expect(State.current_frame == 1, "the first document keeps its frame")
		expect(State.selection.count() == 1, "the first document keeps its selection")
		expect(State.undo_redo.has_undo(), "the first document keeps its history")
		expect(State.document.size == Vector3i(4, 4, 4), "the first document keeps its size")
	)


func _strip() -> void:
	step("Given the tab strip and two documents", func():
		State.open_tab(VoxelDocument.new())
		tabs = TABS_SCENE.instantiate()
		main.add_child(tabs)
	)
	await get_tree().process_frame
	step("Then the strip shows both documents", func():
		expect(tabs.tab_count == State.tabs.size(), "the strip matches the open documents")
		expect(tabs.current_tab == State.active_tab, "the strip marks the active document")
	)
	step("When the active document changes", func():
		State.activate_tab(0)
	)
	await get_tree().process_frame
	step("Then the strip follows", func():
		expect(tabs.current_tab == 0, "the strip follows the active tab")
	)
	step("When the strip selects the other tab", func():
		tabs.current_tab = 1
	)
	await get_tree().process_frame
	step("Then the state follows", func():
		expect(State.active_tab == 1, "selecting a tab activates its document")
	)
	step("When a long document name is edited", func():
		State.tabs[0].file_path = "user://a_very_long_document_name_for_the_tab_test.lve"
		State.tabs[0].edit_dirty = true
		State.tabs_changed.emit()
	)
	await get_tree().process_frame
	step("Then the unsaved marker starts the title", func():
		expect(tabs.get_tab_title(0).begins_with("* "), "the marker is not clipped")
	)


func _open() -> void:
	step("Given one empty tab", func():
		expect(State.tabs.size() == 1, "the app starts with one tab")
	)
	step("When a document opens", func():
		var menu := main.get_node("%MenuBar")
		expect(menu.open_document(SAMPLE_DOCUMENT), "the document opens")
	)
	step("Then the empty tab holds the document", func():
		expect(State.tabs.size() == 1, "open reuses the empty tab")
		expect(State.document.edit_save_path == SAMPLE_DOCUMENT, "the tab keeps the save path")
	)
	step("When another document opens", func():
		var menu := main.get_node("%MenuBar")
		expect(menu.open_document(SAMPLE_DOCUMENT), "the second document opens")
	)
	step("Then a new tab holds it", func():
		expect(State.tabs.size() == 2, "open adds a tab when the active tab is in use")
		expect(State.active_tab == 1, "the new tab is active")
	)


func _session() -> void:
	step("Given two tabs with save paths", func():
		var first := VoxelDocument.new()
		first.edit_save_path = "user://first.lve"
		var second := VoxelDocument.new()
		second.edit_save_path = "user://second.lve"
		var documents: Array[VoxelDocument] = [first, second]
		State.set_tabs(documents, 1)
		var settings := ConfigFile.new()
		settings.set_value("interface", "scale", 1.25)
		settings.set_value("agent", "mcp_enabled", true)
		settings.save(SESSION_PATH)
		State.remember_session(SESSION_PATH)
	)
	step("Then the session stores the paths and the active tab", func():
		expect(State.last_tabs(SESSION_PATH) == PackedStringArray(["user://first.lve", "user://second.lve"]), "the paths are stored")
		expect(State.last_tab_index(SESSION_PATH) == 1, "the active tab is stored")
		expect(State.last_document_path(SESSION_PATH) == "user://second.lve", "the active document is the last document")
	)
	step("Then the other settings survive", func():
		var settings := ConfigFile.new()
		expect(settings.load(SESSION_PATH) == OK, "the settings file loads")
		expect(is_equal_approx(float(settings.get_value("interface", "scale", 0.0)), 1.25), "the interface setting survives")
		expect(bool(settings.get_value("agent", "mcp_enabled", false)), "the agent setting survives")
	)
	step("Then a test scene is not the app session", func():
		expect(not State.is_app_session(), "a test scene cannot write the real session")
	)


func _corrupt_session() -> void:
	var original := "[broken\nkey=1\n"
	step("Given a corrupt settings file", func():
		var file := FileAccess.open(CORRUPT_PATH, FileAccess.WRITE)
		expect(file != null, "the corrupt fixture opens")
		if file != null:
			file.store_string(original)
			file.close()
		var probe := ConfigFile.new()
		expect(probe.load(CORRUPT_PATH) != OK, "the corrupt fixture is unreadable")
	)
	step("When the session is saved", func():
		var first := VoxelDocument.new()
		first.edit_save_path = "user://first.lve"
		var documents: Array[VoxelDocument] = [first]
		State.set_tabs(documents, 0)
		State.remember_session(CORRUPT_PATH)
	)
	step("Then the corrupt file keeps its bytes", func():
		expect(FileAccess.get_file_as_string(CORRUPT_PATH) == original, "the corrupt file is not overwritten")
	)


func _serialize() -> void:
	step("Given a document with runtime editor state", func():
		var document := VoxelDocument.new()
		document.add_frame()
		document.add_tag("Walk", 0, 1)
		document.edit_frame = 1
		document.edit_tag = 0
		document.edit_playing = true
		document.edit_dirty = true
		document.edit_save_path = "user://tabs_test.lve"
		document.edit_selection.add(Vector3i.ONE)
		var data := document.encode_document()
		expect(not data.is_empty(), "the document encodes")
		var loaded := VoxelDocument.decode_document(data)
		expect(loaded != null, "the document decodes")
		expect(loaded.edit_frame == 1, "the frame is stored")
		expect(loaded.edit_tag == 0, "the active tag is stored")
		expect(loaded.edit_playing, "the playback state is stored")
		expect(not loaded.edit_dirty, "the dirty flag is not stored")
		expect(loaded.edit_save_path.is_empty(), "the save path is not stored")
		expect(loaded.edit_selection.is_empty(), "the selection is not stored")
	)


func _quit() -> void:
	var menu := main.get_node("%MenuBar")
	if not menu.quit_confirmed.is_connected(_on_test_quit):
		menu.quit_confirmed.connect(_on_test_quit)
	step("Then the tree waits for the quit flow", func():
		expect(not get_tree().auto_accept_quit, "the tree does not accept the close request")
	)
	step("Given two edited documents", func():
		_first = State.tabs[0]
		_first.file_path = "user://first.lve"
		_first.edit_dirty = true
		_second = VoxelDocument.new()
		_second.file_path = "user://second.lve"
		_second.edit_dirty = true
		State.open_tab(_second)
		State.activate_tab(0)
	)
	step("When the window asks to close", func():
		main.get_window().close_requested.emit()
	)
	step("Then the first edited document is prompted", func():
		var dialog: ConfirmationDialog = menu.get_node("%CloseTabDialog")
		expect(dialog.visible, "the save prompt opens")
		expect(dialog.dialog_text.contains("first.lve"), "the prompt names the first document")
	)
	step("When the user discards the first document", func():
		menu.get_node("%CloseTabDialog").custom_action.emit(&"discard")
	)
	step("Then the second edited document is prompted", func():
		var dialog: ConfirmationDialog = menu.get_node("%CloseTabDialog")
		expect(dialog.visible, "the next prompt opens")
		expect(dialog.dialog_text.contains("second.lve"), "the prompt names the second document")
	)
	step("When the user discards the second document", func():
		menu.get_node("%CloseTabDialog").custom_action.emit(&"discard")
	)
	step("Then the quit is confirmed", func():
		expect(_quit_seen, "the quit signal fires")
		expect(not menu.get_node("%CloseTabDialog").visible, "the prompt closes")
	)
	step("When the user cancels a later quit", func():
		_first.edit_dirty = true
		_second.edit_dirty = true
		_quit_seen = false
		menu.request_quit()
		menu.get_node("%CloseTabDialog").canceled.emit()
	)
	step("Then the app stays open", func():
		expect(not _quit_seen, "the quit is cancelled")
		expect(not menu.get_node("%CloseTabDialog").visible, "the prompt closes")
	)
	step("When only the second document is edited", func():
		_first.edit_dirty = false
		_second.edit_dirty = true
		_quit_seen = false
		menu.request_quit()
	)
	step("Then the prompt skips the clean document", func():
		var dialog: ConfirmationDialog = menu.get_node("%CloseTabDialog")
		expect(dialog.visible, "the prompt opens")
		expect(dialog.dialog_text.contains("second.lve"), "the prompt names the edited document")
		menu.get_node("%CloseTabDialog").custom_action.emit(&"discard")
		expect(_quit_seen, "the quit signal fires after the last document")
	)


func _settings_atomic() -> void:
	step("Given an existing settings file", func():
		var config := ConfigFile.new()
		config.set_value("interface", "scale", 1.5)
		expect(config.save(SESSION_PATH) == OK, "the fixture saves")
	)
	step("When the last document is remembered", func():
		State.remember_document("user://atomic.lve", SESSION_PATH)
	)
	step("Then the setting is stored and no temporary file remains", func():
		var config := ConfigFile.new()
		expect(config.load(SESSION_PATH) == OK, "the settings file loads")
		expect(str(config.get_value("files", "last_document", "")) == "user://atomic.lve", "the path is stored")
		expect(not FileAccess.file_exists(SESSION_PATH + ".tmp"), "no temporary file remains")
	)


func _quit_busy() -> void:
	var menu := main.get_node("%MenuBar")
	if not menu.quit_confirmed.is_connected(_on_test_quit):
		menu.quit_confirmed.connect(_on_test_quit)
	var owner := Node.new()
	add_child(owner)
	step("Given a foreground operation and no edited document", func():
		State.document.edit_dirty = false
		_quit_seen = false
		_busy_operation = State.begin_operation("Test close wait", -1, true, owner)
	)
	step("When the window asks to close", func():
		main.get_window().close_requested.emit()
	)
	step("Then the request waits for the operation", func():
		expect(not _quit_seen, "the quit does not fire while the operation runs")
		expect(menu._quit_requested, "the close request is kept")
	)
	step("When the operation ends", func():
		State.finish_operation(_busy_operation)
	)
	step("Then the quit fires", func():
		expect(_quit_seen, "the kept close request resumes")
	)
	owner.queue_free()


func _on_test_quit() -> void:
	_quit_seen = true


func _close_target() -> void:
	var menu := main.get_node("%MenuBar")
	step("Given a pending close Save As and a quit that interrupts it", func():
		menu._close_after_save_document = State.document
		menu._pending_close_index = 0
		menu._quit_active = true
		menu._quit_after_save = true
	)
	step("When the shared file dialog is cancelled", func():
		menu._on_file_dialog_canceled()
	)
	step("Then no close target or quit wait survives", func():
		expect(menu._close_after_save_document == null, "the close target is cleared")
		expect(menu._pending_close_index == -1, "the pending close index is cleared")
		expect(not menu._quit_active, "the quit is cancelled")
		expect(not menu._quit_after_save, "the quit save wait is cleared")
	)


func _recovery_dialog() -> void:
	var menu := main.get_node("%MenuBar")
	menu.recovery_accepted.connect(_on_test_recovery_accepted)
	var entries := [
		{"name": "first.lve", "file": "user://first.lve", "path": "user://first.lve"},
		{"name": "second.lve", "file": "user://second.lve", "path": "user://second.lve"},
	]
	step("When recovery files are offered", func():
		menu.show_recovery(entries)
	)
	step("Then the prompt lists one checkbox per document", func():
		var dialog: ConfirmationDialog = menu.get_node("%RecoveryDialog")
		var options: VBoxContainer = menu.get_node("%RecoveryOptions")
		expect(dialog.visible, "the recovery prompt opens")
		expect(options.get_child_count() == 2, "the prompt has two checkboxes")
		if options.get_child_count() == 2:
			var first := options.get_child(0) as CheckBox
			var second := options.get_child(1) as CheckBox
			expect(first.button_pressed, "the first checkbox starts checked")
			expect(second.button_pressed, "the second checkbox starts checked")
			expect(first.text.contains("first.lve"), "the first checkbox names the file")
			expect(second.text.contains("second.lve"), "the second checkbox names the file")
	)
	step("When the user clears the second document", func():
		var options: VBoxContainer = menu.get_node("%RecoveryOptions")
		var second := options.get_child(1) as CheckBox
		second.button_pressed = false
	)
	step("When the user recovers", func():
		menu.get_node("%RecoveryDialog").confirmed.emit()
	)
	step("Then only the checked entry is accepted", func():
		expect(_recovery_entries_seen.size() == 1, "the recovery signal carries one entry")
		if _recovery_entries_seen.size() == 1:
			expect(str(_recovery_entries_seen[0].get("name", "")) == "first.lve", "the checked entry is accepted")
		expect(not menu.get_node("%RecoveryDialog").visible, "the prompt closes")
	)


func _on_test_recovery_accepted(entries: Array) -> void:
	_recovery_entries_seen = entries
