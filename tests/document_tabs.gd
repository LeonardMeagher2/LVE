extends "res://tests/test.gd"

## Checks the per-document tab state, the tab strip, and the runtime fields that
## must stay out of the file format.

const TABS_SCENE := preload("res://ui/MenuBar/document_tabs.tscn")
const SAMPLE_DOCUMENT := "res://Flamingo.lve"
const SESSION_PATH := "user://document_tabs_test.cfg"

var tabs: TabBar
var _first: VoxelDocument
var _second: VoxelDocument
var _quit_seen := false
var _recovery_entries_seen: Array = []


func _ready() -> void:
	test("each tab keeps its own document state", _state, "tab_state")
	test("the tab strip follows the open documents", _strip, "tab_strip")
	test("open reuses an empty tab and adds another for a second document", _open, "tab_open")
	test("the session stores the open tab paths", _session, "tab_session")
	test("the runtime editor state is not serialized", _serialize, "tab_serialize")
	test("quitting asks to save each edited document", _quit, "quit_confirmation")
	test("the recovery prompt lists unsaved documents", _recovery_dialog, "recovery_dialog")


func _setup_test() -> void:
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


func _cleanup_test() -> void:
	if is_instance_valid(tabs):
		tabs.queue_free()
		tabs = null
	var directory := DirAccess.open("user://")
	if directory:
		directory.remove(SESSION_PATH.get_file())
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
		State.remember_session(SESSION_PATH)
	)
	step("Then the session stores the paths and the active tab", func():
		expect(State.last_tabs(SESSION_PATH) == PackedStringArray(["user://first.lve", "user://second.lve"]), "the paths are stored")
		expect(State.last_tab_index(SESSION_PATH) == 1, "the active tab is stored")
	)


func _serialize() -> void:
	step("Given a document with runtime editor state", func():
		var document := VoxelDocument.new()
		document.edit_frame = 2
		document.edit_dirty = true
		document.edit_save_path = "user://tabs_test.lve"
		document.edit_selection.add(Vector3i.ONE)
		var data := document.encode_document()
		expect(not data.is_empty(), "the document encodes")
		var loaded := VoxelDocument.decode_document(data)
		expect(loaded != null, "the document decodes")
		expect(loaded.edit_frame == 0, "the frame is not stored")
		expect(not loaded.edit_dirty, "the dirty flag is not stored")
		expect(loaded.edit_save_path.is_empty(), "the save path is not stored")
		expect(loaded.edit_selection.is_empty(), "the selection is not stored")
	)


func _quit() -> void:
	var menu := main.get_node("%MenuBar")
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


func _on_test_quit() -> void:
	_quit_seen = true


func _recovery_dialog() -> void:
	var menu := main.get_node("%MenuBar")
	menu.recovery_accepted.connect(_on_test_recovery_accepted)
	var entries := [{
		"name": "first.lve",
		"file": "user://first.lve",
		"path": "user://first.lve",
	}]
	step("When recovery files are offered", func():
		menu.show_recovery(entries)
	)
	step("Then the prompt lists them", func():
		var dialog: ConfirmationDialog = menu.get_node("%RecoveryDialog")
		expect(dialog.visible, "the recovery prompt opens")
		expect(dialog.dialog_text.contains("first.lve"), "the prompt names the file")
	)
	step("When the user recovers", func():
		menu.get_node("%RecoveryDialog").confirmed.emit()
	)
	step("Then the entries are accepted", func():
		expect(_recovery_entries_seen.size() == 1, "the recovery signal carries one entry")
		expect(not menu.get_node("%RecoveryDialog").visible, "the prompt closes")
	)


func _on_test_recovery_accepted(entries: Array) -> void:
	_recovery_entries_seen = entries
