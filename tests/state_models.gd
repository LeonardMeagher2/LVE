extends "res://tests/test.gd"


const OperationRegistry = preload("res://Globals/State/OperationRegistry.gd")
const SettingsStore = preload("res://Globals/State/SettingsStore.gd")
const DocumentSession = preload("res://Globals/State/DocumentSession.gd")
const SelectionState = preload("res://Globals/State/SelectionState.gd")
const MaterialState = preload("res://Globals/State/MaterialState.gd")
const EditSession = preload("res://Globals/State/EditSession.gd")
const EditingAids = preload("res://Globals/State/EditingAids.gd")


class WaitJob extends VoxelFrame.EditJob:
	var reached := 0

	func run() -> void:
		stage("Testing a job", 2)
		OS.delay_msec(30)
		reached = 1
		checkpoint(1)
		OS.delay_msec(30)
		reached = 2
		checkpoint(2)


var registry: OperationRegistry
var store: SettingsStore
var operation_id := 0
var owner_node: Node
var job: WaitJob
var first: VoxelDocument
var second: VoxelDocument
var third: VoxelDocument
var documents: Array[VoxelDocument]
var settings_path := ""
var callback_count := 0
var frames := 0
var session: DocumentSession
var selection_model: SelectionState
var selection_context_result: VoxelFrame.EditContext
var material_editing: MaterialState
var edit_session: EditSession
var aids: EditingAids
var transaction: VoxelEditTransaction
var signal_order: Array[String] = []
var selection_events := 0
var frame_events := 0
var tag_events := 0
var history_events := 0
var color_events := 0
var palette_events := 0
var edit_events := 0
var cells_events := 0
var floor_events := 0
var slice_events := 0
var symmetry_events := 0


func _ready() -> void:
	test("an operation starts, updates, and finishes", _operation_lifecycle, "operation_lifecycle")
	test("a foreground operation blocks an edit", _foreground_busy, "operation_foreground")
	test("a foreground operation does not block its owner", _owner_not_blocked, "operation_owner")
	test("a cancel request calls the owner callback once", _cancel, "operation_cancel")
	test("run_edit_job joins its worker", _join, "operation_job")
	test("the settings store writes through a temporary file", _settings_write, "settings_write")
	test("the settings store keeps a corrupt file", _settings_corrupt, "settings_corrupt")
	test("the settings store remembers the session paths", _settings_session, "settings_session")
	test("a document session adds, activates, and closes tabs", _session_tabs, "session_tabs")
	test("the document session keeps the adoption signal order", _session_adoption, "session_adoption")
	test("the State adoption signals keep their order", _state_adoption, "state_adoption")
	test("the document session plays frames and tags", _session_playback, "session_playback")
	test("the selection state clears and reports changes", _selection_clear, "selection_clear")
	test("the selection state derives the context and region", _selection_context, "selection_context")
	test("the material state changes and undoes the material and palette", _material_changes, "material_changes")
	test("the edit session begins, finishes, and cancels an edit", _edit_lifecycle, "edit_lifecycle")
	test("the editing aids keep the floor, the slice, and the symmetry", _aids_context, "aids_context")


func before_test() -> void:
	callback_count = 0
	frames = 0
	operation_id = 0
	owner_node = null
	job = null
	first = null
	second = null
	third = null
	documents = []
	session = null
	selection_model = null
	selection_context_result = null
	material_editing = null
	edit_session = null
	aids = null
	transaction = null
	signal_order = []
	selection_events = 0
	frame_events = 0
	tag_events = 0
	history_events = 0
	color_events = 0
	palette_events = 0
	edit_events = 0
	cells_events = 0
	floor_events = 0
	slice_events = 0
	symmetry_events = 0
	settings_path = "user://state_models_%s.cfg" % Time.get_ticks_usec()
	_remove_file(settings_path)
	registry = OperationRegistry.new()
	registry.tree = get_tree()
	store = SettingsStore.new()
	store.tree = get_tree()
	store.settings_path = settings_path


func after_test() -> void:
	while registry != null and registry.get_activity() != null:
		registry.finish_operation(registry.get_activity().id)
	_remove_file(settings_path)
	_remove_file(settings_path + ".tmp")


func _remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _on_cancel() -> void:
	callback_count += 1


func _on_frame_event() -> void:
	frame_events += 1


func _on_tag_event() -> void:
	tag_events += 1


func _on_selection_event() -> void:
	selection_events += 1


func _material_history(execute := true) -> void:
	session.document.edit_history.commit_action(execute)
	history_events += 1


func _apply_test_material(values: PackedFloat32Array) -> void:
	material_editing.apply_history_material(values)


func _restore_test_palette(snapshot: Dictionary) -> void:
	material_editing.restore_history_palette(snapshot)


func _restore_test_chunks(edited_frame: VoxelFrame, chunk_snapshot: Dictionary, selection_snapshot: Dictionary, selection_snapshot_masks := {}) -> void:
	edit_session.restore_history_chunks(edited_frame, chunk_snapshot, selection_snapshot, selection_snapshot_masks)


func _on_color_event(_color: Color) -> void:
	color_events += 1


func _on_palette_event() -> void:
	palette_events += 1


func _on_edit_event() -> void:
	edit_events += 1


func _on_cells_event(_layer_index: int, _frame_index: int, _affected: Array[Vector3i]) -> void:
	cells_events += 1


func _on_floor_event() -> void:
	floor_events += 1


func _on_slice_event() -> void:
	slice_events += 1


func _on_symmetry_event() -> void:
	symmetry_events += 1


func _on_frame() -> void:
	frames += 1


func _operation_lifecycle() -> void:
	step("Given an operation registry and one operation", func():
		operation_id = registry.begin_operation("Building", 10)
	)
	step("Then the operation is tracked", func():
		expect(registry.has_operation(operation_id), "the new operation is tracked")
		expect(registry.get_activity().label == "Building", "the label is the begin label")
		expect(not registry.get_activity().foreground, "a plain operation is in the background")
	)
	step("When the owner updates its progress", func():
		registry.update_operation(operation_id, 4, 10, "Merging", "four of ten")
	)
	step("Then the progress is stored", func():
		var operation := registry.get_activity()
		expect(operation.completed == 4, "the completed count updates")
		expect(operation.total == 10, "the total updates")
		expect(operation.phase == "Merging", "the phase is diagnostic")
		expect(operation.detail == "four of ten", "the detail is diagnostic")
	)
	step("When the operation finishes", func():
		registry.finish_operation(operation_id)
	)
	step("Then no operation remains", func():
		expect(not registry.has_operation(operation_id), "the finished operation leaves the list")
		expect(registry.get_activity() == null, "no activity remains")
		expect(registry.activity_elapsed_ms() == 0, "the activity clock resets")
	)


func _foreground_busy() -> void:
	step("Given a foreground operation", func():
		operation_id = registry.begin_operation("Scaling", 100, true, self)
	)
	step("Then another requester sees a busy edit", func():
		expect(registry.edit_busy(), "a foreground operation blocks an anonymous requester")
		expect(registry.edit_busy(main), "a foreground operation blocks another node")
	)
	step("When the foreground operation finishes", func():
		registry.finish_operation(operation_id)
		operation_id = registry.begin_operation("Building surfaces", -1, false, self)
	)
	step("Then a background operation does not block", func():
		expect(not registry.edit_busy(), "a background operation does not block an edit")
	)


func _owner_not_blocked() -> void:
	step("Given a foreground operation with an owner", func():
		owner_node = Node.new()
		operation_id = registry.begin_operation("Selecting", 10, true, owner_node)
	)
	step("Then the owner can still edit", func():
		expect(not registry.edit_busy(owner_node), "the owner is not blocked by its own operation")
		expect(registry.edit_busy(), "another requester is blocked")
	)
	step("When the owner is freed", func():
		owner_node.free()
		registry.update()
	)
	step("Then the stale operation is finished", func():
		expect(not registry.has_operation(operation_id), "the freed owner releases the operation")
	)


func _cancel() -> void:
	step("Given a cancellable foreground operation", func():
		operation_id = registry.begin_operation("Exporting", 10, true, self, _on_cancel)
	)
	step("Then the owner can cancel it once", func():
		expect(registry.get_activity().can_cancel(), "the registered callback makes the operation cancellable")
		expect(registry.cancel_operation(operation_id), "the first cancel request is accepted")
		expect(callback_count == 1, "the cancel callback runs once")
		expect(registry.get_activity().cancel_requested, "the cancellation stays pending")
		expect(not registry.cancel_operation(operation_id), "a second cancel request is refused")
		expect(callback_count == 1, "the refused request calls nothing")
		expect(registry.cancel_activity(), "a pending cancellation still owns Escape")
	)
	step("When the owner finishes the operation", func():
		registry.finish_operation(operation_id)
	)
	step("Then no operation remains", func():
		expect(registry.get_activity() == null, "the finished operation leaves the list")
	)


func _join() -> void:
	job = WaitJob.new()
	operation_id = registry.begin_operation("Testing a job", 2, true, self)
	await registry.run_edit_job(job, operation_id, "State models", _on_frame)
	step("Then the worker is joined before the call returns", func():
		expect(job.reached == 2, "the worker completed its work")
		expect(job.worker_task_id == -1, "the worker handle is retired")
		expect(frames > 0, "the call pumped at least one frame")
		expect(registry.get_activity().phase == "Testing a job", "the progress reached the operation")
		expect(registry.has_operation(operation_id), "the owner still finishes the operation")
	)
	step("When the owner finishes the operation", func():
		registry.finish_operation(operation_id)
	)
	step("Then no operation remains", func():
		expect(registry.get_activity() == null, "the finished operation leaves the list")
	)


func _settings_write() -> void:
	step("Given a settings store with a temporary file", func():
		store.remember_document("res://sample.lve")
	)
	step("Then the value is written through a temporary file", func():
		expect(FileAccess.file_exists(settings_path), "the settings file exists")
		expect(not FileAccess.file_exists(settings_path + ".tmp"), "no temporary file remains")
		expect(store.last_document_path() == "res://sample.lve", "the stored path is read back")
	)
	step("When the document path is forgotten", func():
		store.forget_document()
	)
	step("Then the file keeps no document path", func():
		expect(store.last_document_path() == "", "the forgotten path is empty")
		expect(FileAccess.file_exists(settings_path), "the settings file remains")
	)


func _settings_corrupt() -> void:
	step("Given a settings file with invalid text", func():
		var file := FileAccess.open(settings_path, FileAccess.WRITE)
		expect(file != null, "the corrupt fixture opens")
		if file != null:
			file.store_string("[broken\n")
			file.close()
		store.remember_document("res://replacement.lve")
	)
	step("Then the store keeps the corrupt bytes", func():
		expect(FileAccess.get_file_as_string(settings_path) == "[broken\n", "the corrupt file keeps its bytes")
		expect(store.last_document_path() == "", "the unreadable file gives no path")
		expect(not FileAccess.file_exists(settings_path + ".tmp"), "the refused write leaves no temporary file")
	)


func _settings_session() -> void:
	step("Given three tabs where one has no save path", func():
		first = VoxelDocument.new()
		second = VoxelDocument.new()
		third = VoxelDocument.new()
		first.edit_save_path = "res://first.lve"
		second.edit_save_path = "res://second.lve"
		documents = [first, second, third]
		store.remember_session(documents, 1)
	)
	step("Then only the saved paths and the active index are stored", func():
		expect(store.last_tabs() == PackedStringArray(["res://first.lve", "res://second.lve"]), "the pathless tab is skipped")
		expect(store.last_tab_index() == 1, "the active tab maps to the saved list")
		expect(store.last_document_path() == "res://second.lve", "the active path is remembered")
	)
	step("When the active tab has no path", func():
		store.remember_session(documents, 2)
	)
	step("Then the stored active index still fits", func():
		expect(store.last_tab_index() == 1, "a pathless active tab keeps the stored index")
		expect(store.last_document_path() == "res://second.lve", "the last document path stays")
	)
	step("Then a test scene is not the application session", func():
		expect(not store.is_app_session(), "the injected tree is not the app session")
	)


func _session_tabs() -> void:
	step("Given a session with three documents", func():
		session = DocumentSession.new()
		first = session.new_document()
		second = VoxelDocument.new()
		session.add_tab(first)
		session.add_tab(second)
	)
	step("Then every document is a tab", func():
		expect(session.tabs.size() == 3, "the startup tab and both documents are open")
		expect(session.document == session.tabs[0], "the startup document is active")
	)
	step("When the first added tab becomes active", func():
		expect(session.activate_tab(1), "the tab activates")
	)
	step("Then the active document follows", func():
		expect(session.active_tab == 1, "the active index moves")
		expect(session.document == first, "the active document is the tab document")
	)
	step("When the active tab closes", func():
		expect(session.close_tab(1), "the tab closes")
	)
	step("Then the next tab is active", func():
		expect(session.tabs.size() == 2, "one tab is removed")
		expect(session.active_tab == 1, "the tab at the same index is active")
		expect(session.document == second, "the next document is active")
	)
	step("When a tab before the active one closes", func():
		expect(session.close_tab(0), "the first tab closes")
	)
	step("Then the active index moves down", func():
		expect(session.tabs.size() == 1, "one tab remains")
		expect(session.active_tab == 0, "the active index moves down")
		expect(session.document == second, "the active document stays")
	)


func _session_adoption() -> void:
	step("Given a session with two documents and recorded signals", func():
		session = DocumentSession.new()
		session.add_tab(VoxelDocument.new())
		signal_order = []
		session.document_deactivating.connect(func(): signal_order.append("deactivating"))
		session.is_playing_toggled.connect(func(_playing): signal_order.append("playing"))
		session.document_changed.connect(func(): signal_order.append("document"))
		session.frames_changed.connect(func(): signal_order.append("frames"))
		session.frame_changed.connect(func(): signal_order.append("frame"))
		session.tag_changed.connect(func(): signal_order.append("tag"))
		session.tabs_changed.connect(func(): signal_order.append("tabs"))
		session.active_tab_changed.connect(func(): signal_order.append("active_tab"))
	)
	step("When the second tab becomes active", func():
		expect(session.activate_tab(1), "the tab activates")
	)
	step("Then the adoption signals keep their order", func():
		expect(signal_order == ["deactivating", "playing", "document", "frames", "frame", "tag", "active_tab"], "the session emits the adoption signals in order")
	)


func _state_adoption() -> void:
	step("Given two documents in State", func():
		var documents: Array[VoxelDocument] = [VoxelDocument.new(), VoxelDocument.new()]
		State.set_tabs(documents, 0)
	)
	step("When the tab set replaces the documents", func():
		signal_order = []
		State.document_deactivating.connect(func(): signal_order.append("deactivating"), CONNECT_ONE_SHOT)
		State.is_playing_toggled.connect(func(_playing): signal_order.append("playing"), CONNECT_ONE_SHOT)
		State.document_changed.connect(func(): signal_order.append("document"), CONNECT_ONE_SHOT)
		State.size_changed.connect(func(): signal_order.append("size"), CONNECT_ONE_SHOT)
		State.palette_changed.connect(func(): signal_order.append("palette"), CONNECT_ONE_SHOT)
		State.frames_changed.connect(func(): signal_order.append("frames"), CONNECT_ONE_SHOT)
		State.frame_changed.connect(func(): signal_order.append("frame"), CONNECT_ONE_SHOT)
		State.tag_changed.connect(func(): signal_order.append("tag"), CONNECT_ONE_SHOT)
		State.selection_changed.connect(func(): signal_order.append("selection"), CONNECT_ONE_SHOT)
		State.history_changed.connect(func(): signal_order.append("history"), CONNECT_ONE_SHOT)
		State.edit_state_changed.connect(func(): signal_order.append("edit_state"), CONNECT_ONE_SHOT)
		State.tabs_changed.connect(func(): signal_order.append("tabs"), CONNECT_ONE_SHOT)
		State.active_tab_changed.connect(func(): signal_order.append("active_tab"), CONNECT_ONE_SHOT)
		var documents: Array[VoxelDocument] = [VoxelDocument.new(), VoxelDocument.new()]
		State.set_tabs(documents, 1)
	)
	step("Then the State signals keep the adoption order", func():
		expect(signal_order == ["deactivating", "playing", "document", "size", "palette", "frames", "frame", "tag", "selection", "history", "edit_state", "tabs", "active_tab"], "the facade emits the adoption signals in order")
	)


func _session_playback() -> void:
	step("Given a document with two frames and a tag", func():
		session = DocumentSession.new()
		session.document.add_frame()
		session.document.add_tag("Walk", 0, 1)
		session.document.set_frame_delay(0, 10)
		session.document.set_frame_delay(1, 10)
		session.frame_changed.connect(_on_frame_event)
		session.tag_changed.connect(_on_tag_event)
	)
	step("When the frame and the tag change", func():
		session.playback.current_frame = 1
		session.playback.active_tag = 1
	)
	step("Then the playback state follows", func():
		expect(session.playback.current_frame == 1, "the frame moves")
		expect(session.playback.active_tag == 1, "the tag is active")
		expect(frame_events == 1, "the frame change is reported")
		expect(tag_events == 1, "the tag change is reported")
	)
	step("When the playback runs for one delay", func():
		session.playback.is_playing = true
		session.update(0.02)
	)
	step("Then the frame advanced", func():
		expect(session.playback.current_frame == 0, "the playback wrapped to the first frame")
	)


func _selection_clear() -> void:
	step("Given a selection model on a session", func():
		session = DocumentSession.new()
		selection_model = SelectionState.new()
		selection_model.session = session
		session.document.edit_selection.add(Vector3i(1, 2, 3))
		selection_model.selection_changed.connect(_on_selection_event)
	)
	step("Then the model reads the document selection", func():
		expect(selection_model.selection == session.document.edit_selection, "the model shares the document selection")
		expect(selection_model.selection.count() == 1, "the selected cell is present")
	)
	step("When the selection clears", func():
		selection_model.clear_selection()
	)
	step("Then the selection is empty and the signal fired once", func():
		expect(selection_model.selection.is_empty(), "the selection is empty")
		expect(selection_events == 1, "the change signal fired once")
	)
	step("When an external write reports a change", func():
		session.document.edit_selection.add(Vector3i.ONE)
		selection_model.notify_changed()
	)
	step("Then the change signal fired again", func():
		expect(selection_events == 2, "notify_changed emits the signal")
	)


func _selection_context() -> void:
	step("Given a drawing context with symmetry, a slice, and a size", func():
		session = DocumentSession.new()
		selection_model = SelectionState.new()
		selection_model.session = session
		var drawing := VoxelFrame.EditContext.new()
		drawing.axes = 1
		drawing.origin_twice = Vector3i(-1, -1, -1)
		drawing.slice_axis = 1
		drawing.slice_index = 2
		drawing.slice_count = 3
		drawing.bounded_axes = 1
		drawing.bounds_min = Vector3i.ZERO
		drawing.bounds_max = Vector3i(4, 4, 4)
		drawing.selection = {Vector3i(9, 9, 9): true}
		selection_context_result = selection_model.selection_context(drawing)
		expect(selection_context_result.axes == 1, "the symmetry is kept")
		expect(selection_context_result.slice_axis == 1, "the slice axis is kept")
		expect(selection_context_result.slice_index == 2, "the slice index is kept")
		expect(selection_context_result.selection.is_empty(), "the selection filter is removed")
		expect(selection_context_result.bounded_axes == 0, "the document size is removed")
		expect(drawing.selection.has(Vector3i(9, 9, 9)), "the drawing context keeps its selection")
	)
	step("Then the region expands without the selection filter", func():
		var region := VoxelSelection.new()
		region.add(Vector3i(2, 3, 4))
		var expanded := selection_model.selection_region(region, selection_context_result, session.document.frames[0])
		expect(expanded.count() == 2, "the X symmetry mirrors the region")
		expect(expanded.contains(Vector3i(2, 3, 4)), "the source cell stays")
		expect(expanded.contains(Vector3i(-3, 3, 4)), "the mirrored cell is added")
	)


func _material_changes() -> void:
	step("Given a material state on a session", func():
		session = DocumentSession.new()
		material_editing = MaterialState.new()
		material_editing.session = session
		material_editing.settings = store
		material_editing.operations = registry
		material_editing.commit_history = _material_history
		material_editing.history_apply = _apply_test_material
		material_editing.history_restore_palette = _restore_test_palette
		session.document.palette = material_editing.copy_default_palette()
		material_editing.select_palette_entry(0)
		material_editing.color_changed.connect(_on_color_event)
		material_editing.palette_changed.connect(_on_palette_event)
	)
	step("Then the first palette entry is the current material", func():
		expect(material_editing.current_palette_index == 0, "the first entry is selected")
		expect(material_editing.current_material == material_editing.get_palette()[0], "the material matches the first entry")
	)
	step("When the material changes", func():
		material_editing.set_material(VoxelFrame.material(Color(0.25, 0.5, 0.75)))
	)
	step("Then the new material is current and one history action exists", func():
		expect(VoxelFrame.material_color(material_editing.current_material) == Color(0.25, 0.5, 0.75), "the material is the new color")
		expect(material_editing.current_palette_index == -1, "the material matches no swatch")
		expect(color_events == 1, "the color change is reported")
		expect(history_events == 1, "the change records one history action")
	)
	step("When the change is undone", func():
		session.document.edit_history.undo()
	)
	step("Then the first material returns", func():
		expect(VoxelFrame.material_color(material_editing.current_material) == Color.BLACK, "the first palette material returns")
		expect(material_editing.current_palette_index == 0, "the swatch selection returns")
	)
	step("When the palette changes", func():
		var replacement: Array[PackedFloat32Array] = [VoxelFrame.material(Color.BLUE), VoxelFrame.material(Color.GREEN)]
		material_editing.set_palette(replacement)
	)
	step("Then the palette is replaced and one history action exists", func():
		var expected: Array[PackedFloat32Array] = [VoxelFrame.material(Color.BLUE), VoxelFrame.material(Color.GREEN)]
		expect(material_editing.get_palette() == expected, "the palette is replaced")
		expect(material_editing.current_palette_index == -1, "the old material matches no new swatch")
		expect(palette_events == 1, "the palette change is reported")
		expect(history_events == 2, "the palette change records one history action")
	)
	step("When the palette change is undone", func():
		session.document.edit_history.undo()
	)
	step("Then the built-in palette returns", func():
		expect(material_editing.get_palette() == material_editing.get_builtin_palette(), "the palette is restored")
		expect(material_editing.current_palette_index == 0, "the black swatch is selected again")
	)


func _edit_lifecycle() -> void:
	step("Given an edit session on a document", func():
		session = DocumentSession.new()
		selection_model = SelectionState.new()
		selection_model.session = session
		aids = EditingAids.new()
		aids.session = session
		aids.selection_state = selection_model
		edit_session = EditSession.new()
		edit_session.session = session
		edit_session.selection_state = selection_model
		edit_session.aids = aids
		edit_session.commit_history = _material_history
		edit_session.cells_changed = _on_cells_event
		edit_session.history_restore_chunks = _restore_test_chunks
		edit_session.edit_state_changed.connect(_on_edit_event)
		transaction = edit_session.begin_edit()
	)
	step("Then the edit is open", func():
		expect(transaction != null, "the edit opens")
		expect(edit_session.active_edit() == transaction, "the session holds the handle")
		expect(edit_session.begin_edit() == null, "a second edit is refused")
		expect(edit_events == 1, "the open is reported")
	)
	step("When the frame changes and the edit finishes", func():
		session.document.frames[0].set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		edit_session.finish_edit(transaction)
	)
	step("Then the change is one history action", func():
		expect(edit_session.active_edit() == null, "the edit closes")
		expect(history_events == 1, "the change records one history action")
		expect(session.document.edit_history.has_undo(), "the history holds the action")
		expect(edit_events == 2, "the close is reported")
	)
	step("When the action is undone", func():
		session.document.edit_history.undo()
	)
	step("Then the frame is empty again", func():
		expect(not session.document.frames[0].has(Vector3i.ZERO), "the undo removes the cell")
		expect(cells_events == 1, "the restore reports the cell change")
	)
	step("When a new edit changes the frame and cancels", func():
		transaction = edit_session.begin_edit()
		session.document.frames[0].set_cell(Vector3i.ONE, VoxelFrame.material(Color.BLUE))
		edit_session.cancel_edit(transaction)
	)
	step("Then the frame is restored without history", func():
		expect(not session.document.frames[0].has(Vector3i.ONE), "the cancel restores the frame")
		expect(edit_session.active_edit() == null, "the cancel closes the edit")
		expect(history_events == 1, "the cancel records no history")
		expect(cells_events == 2, "the cancel reports the cell change")
		expect(edit_events == 4, "the open and the cancel are reported")
	)


func _aids_context() -> void:
	step("Given an aids model on a session", func():
		session = DocumentSession.new()
		selection_model = SelectionState.new()
		selection_model.session = session
		aids = EditingAids.new()
		aids.session = session
		aids.selection_state = selection_model
		aids.floor_plane_changed.connect(_on_floor_event)
		aids.slice_changed.connect(_on_slice_event)
		aids.symmetry_changed.connect(_on_symmetry_event)
	)
	step("When the floor, the slice, and the symmetry change", func():
		aids.floor_axis = Vector3.Axis.AXIS_X
		aids.floor_index = 2
		aids.slice_layers = 3
		aids.symmetry_axes = 5
		aids.symmetry_origin = Vector3(0.3, 0.3, 0.3)
	)
	step("Then each aid reports its change", func():
		expect(aids.floor_axis == Vector3.Axis.AXIS_X, "the floor axis moves")
		expect(aids.floor_index == 2, "the floor index moves")
		expect(aids.slice_enabled, "the slice is enabled")
		expect(aids.slice_layers == 3, "the layer count is kept")
		expect(floor_events == 2, "the two floor changes are reported")
		expect(slice_events == 1, "the slice change is reported")
		expect(symmetry_events == 2, "the two symmetry changes are reported")
		expect(aids.symmetry_origin == Vector3(0.5, 0.5, 0.5), "the origin snaps to half units")
	)
	step("Then the live context carries the aids and the document", func():
		session.document.size = Vector3i(4, 4, 4)
		session.document.edit_selection.add(Vector3i(1, 1, 1))
		var context := aids.drawing_context(null)
		expect(context.axes == 5, "the context carries the symmetry")
		expect(context.origin_twice == Vector3i(1, 1, 1), "the origin is doubled")
		expect(context.slice_axis == Vector3.Axis.AXIS_X, "the slice axis is the floor axis")
		expect(context.slice_index == aids.slice_first(), "the slice starts at the first layer")
		expect(context.slice_count == aids.slice_count(), "the slice spans both sides")
		expect(context.bounded_axes == 7, "every sized axis is bounded")
		expect(context.bounds_min == Vector3i(-2, -2, -2), "the lower bound is kept")
		expect(context.bounds_max == Vector3i(2, 2, 2), "the upper bound is kept")
		expect(context.selection.has(Vector3i(1, 1, 1)), "the selection is captured")
	)
	step("Then a frozen context and a mirror use the aids", func():
		var frozen := VoxelFrame.EditContext.new()
		frozen.slice_axis = 2
		expect(aids.drawing_context(frozen) == frozen, "the frozen context is returned unchanged")
		var mirror := aids.symmetry_transform(1, Vector3(-0.5, -0.5, -0.5))
		expect((mirror * Vector3(1, 0, 0)).is_equal_approx(Vector3(-2, 0, 0)), "the X symmetry mirrors the point")
	)
