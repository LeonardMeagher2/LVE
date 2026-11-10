extends "res://tests/test.gd"

## Checks the per-document tab state, the tab strip, and the runtime fields that
## must stay out of the file format.

const TABS_SCENE := preload("res://ui/MenuBar/document_tabs.tscn")
const SAMPLE_DOCUMENT := "res://Flamingo.lve"
const SESSION_PATH := "user://document_tabs_test.cfg"

var tabs: TabBar
var _first: VoxelDocument
var _second: VoxelDocument


func _ready() -> void:
	test("each tab keeps its own document state", _state, "tab_state")
	test("the tab strip follows the open documents", _strip, "tab_strip")
	test("open reuses an empty tab and adds another for a second document", _open, "tab_open")
	test("the session stores the open tab paths", _session, "tab_session")
	test("the runtime editor state is not serialized", _serialize, "tab_serialize")


func _setup_test() -> void:
	State.stop()
	State.tabs.clear()
	var document := VoxelDocument.new()
	State.tabs.append(document)
	State.active_tab = 0
	State.document = document


func _cleanup_test() -> void:
	if is_instance_valid(tabs):
		tabs.queue_free()
		tabs = null
	var directory := DirAccess.open("user://")
	if directory:
		directory.remove(SESSION_PATH.get_file())


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
