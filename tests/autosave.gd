extends "res://tests/test.gd"


const DIR := "user://autosave_test"
const MANIFEST := "user://autosave_test/manifest.json"
const AutosaveScript := preload("res://Globals/Autosave/Autosave.gd")


class CountingDocument extends VoxelDocument:
	var encodes := 0
	var encodable := true
	var fail_writes := false

	func encode_document() -> PackedByteArray:
		encodes += 1
		return super.encode_document() if encodable else PackedByteArray()

	func save_file(path: String, preview: Image = null, encoded := PackedByteArray()) -> Error:
		if fail_writes:
			return ERR_FILE_CANT_WRITE
		return super.save_file(path, preview, encoded)


var autosave
var _recovery_seen: Array = []


func _ready() -> void:
	test("autosave writes and deletes a recovery copy", _save_delete, "autosave_save")
	test("recovery lists and loads an autosave file", _recover, "autosave_recover")
	test("discard removes a recovery copy", _discard, "autosave_discard")
	test("a failed recovery copy keeps the dirty flag", _retry_failure, "autosave_retry")
	test("an invalid document does not retry", _invalid_no_retry, "autosave_invalid")
	test("a retry skips an invalid document beside a failed copy", _mixed_retry, "autosave_invalid_mixed")
	test("an edit retries only its own document", _invalid_edit_scope, "autosave_invalid_scope")
	test("a view change keeps a permanent failure skipped", _invalid_view_scope, "autosave_invalid_view")
	test("one timer tick writes one recovery copy", _one_per_tick, "autosave_one_per_tick")
	test("a failed copy backs off before it retries", _retry_backoff, "autosave_backoff")


func before_test() -> void:
	State.stop()
	State.tabs.clear()
	var document := VoxelDocument.new()
	State.tabs.append(document)
	State.active_tab = 0
	State.document = document
	State.undo_redo.clear_history()
	_clear_dir()
	autosave = AutosaveScript.new()
	autosave.recovery_dir = DIR
	autosave.manifest_path = MANIFEST
	add_child(autosave)
	_recovery_seen = []


func after_test() -> void:
	if autosave != null:
		autosave.queue_free()
		autosave = null
	_clear_dir()
	State.set_tabs([State.new_document()], 0)
	await get_tree().process_frame


func _clear_dir() -> void:
	var dir := DirAccess.open(DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			dir.remove(name)
		name = dir.get_next()
	dir.list_dir_end()


func _save_delete() -> void:
	var document := State.document
	var original := DIR.path_join("original.lve")
	var recovery := DIR.path_join("~original.lve")
	step("Given an edited document with a save path", func():
		document.edit_save_path = original
		document.file_path = original
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		document.edit_dirty = true
	)
	autosave.save_now()
	step("Then the recovery copy sits next to the original", func():
		expect(FileAccess.file_exists(recovery), "the recovery file exists next to the original")
		var loaded := VoxelDocument.load_file(recovery)
		expect(loaded != null and loaded.active_layer().frames[0].has(Vector3i.ZERO), "the recovery file holds the cell")
		expect(document.edit_dirty, "the autosave copy leaves the unsaved mark")
		var entries: Array = autosave.recovery_entries()
		expect(entries.size() == 1, "the manager tracks one copy")
		if entries.size() == 1:
			expect(str(entries[0].get("file", "")) == recovery, "the entry names the copy")
	)
	step("When the document is saved", func():
		State.record_saved(document, DIR.path_join("saved.lve"))
	)
	step("Then the recovery copy is deleted", func():
		expect(not FileAccess.file_exists(recovery), "the recovery file is gone")
		expect(autosave.recovery_entries().is_empty(), "the manager drops the entry")
	)


func _recover() -> void:
	var document := State.document
	var original := DIR.path_join("original.lve")
	step("Given an edited document and a recovery copy", func():
		document.edit_save_path = original
		document.file_path = original
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		document.edit_dirty = true
	)
	autosave.save_now()
	var entries: Array = autosave.recovery_entries().duplicate()
	autosave.recovery_available.connect(_on_test_recovery)
	step("When the app checks for recovery files", func():
		autosave.check_recovery()
	)
	step("Then the copy is offered and loads as a dirty tab", func():
		expect(_recovery_seen.size() == 1, "the recovery prompt has one entry")
		autosave.recover(entries)
		var recovered := State.document
		expect(recovered.edit_dirty, "the recovered document is dirty")
		expect(recovered.active_layer().frames[0].has(Vector3i.ZERO), "the recovered document holds the cell")
		expect(recovered.edit_save_path == original, "the recovered document keeps the original path")
	)


func _discard() -> void:
	var document := State.document
	var original := DIR.path_join("original.lve")
	var recovery := DIR.path_join("~original.lve")
	step("Given an edited document and a recovery copy", func():
		document.edit_save_path = original
		document.file_path = original
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		document.edit_dirty = true
	)
	autosave.save_now()
	var entries: Array = autosave.recovery_entries().duplicate()
	step("When the user discards the recovery copy", func():
		autosave.discard_entries(entries)
	)
	step("Then the file and entry are gone", func():
		expect(not FileAccess.file_exists(recovery), "the recovery file is gone")
		expect(autosave.recovery_entries().is_empty(), "the manager drops the entry")
		expect(autosave.list_recovery().is_empty(), "the startup list is empty")
	)


func _retry_failure() -> void:
	var blocked := DIR.path_join("blocked")
	step("Given a recovery folder that is an ordinary file", func():
		var file := FileAccess.open(blocked, FileAccess.WRITE)
		expect(file != null, "the blocker file is created")
		if file != null:
			file.close()
		autosave.recovery_dir = blocked
		autosave.manifest_path = blocked.path_join("manifest.json")
		State.document.edit_save_path = ""
		State.document.file_path = ""
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.document.edit_dirty = true
		autosave._dirty = true
	)
	step("When autosave runs", func():
		autosave.save_now()
	)
	step("Then the copy failure keeps the dirty flag for a retry", func():
		expect(autosave._dirty, "a failed copy keeps the dirty flag")
		expect(autosave.recovery_entries().is_empty(), "no entry is recorded")
		expect(State.document.edit_dirty, "the document stays unsaved")
	)


func _invalid_no_retry() -> void:
	var document := CountingDocument.new()
	step("Given an edited document that cannot encode", func():
		State.tabs.clear()
		State.tabs.append(document)
		State.active_tab = 0
		State.document = document
		document.file_path = ""
		document.edit_save_path = ""
		document.encodable = false
		document.edit_dirty = true
		autosave._dirty = true
	)
	step("When autosave runs", func():
		autosave.save_now()
	)
	step("Then the dirty mark stays and no retry is scheduled", func():
		expect(document.edit_dirty, "the document stays unsaved")
		expect(not autosave._dirty, "a permanent failure is not retried")
		expect(autosave._timer.is_stopped(), "no retry timer runs")
		expect(autosave.recovery_entries().is_empty(), "no entry is recorded")
	)


func _mixed_retry() -> void:
	var invalid := CountingDocument.new()
	var blocked := DIR.path_join("blocked_mixed")
	step("Given an invalid document and a document whose copy cannot write", func():
		var file := FileAccess.open(blocked, FileAccess.WRITE)
		expect(file != null, "the blocker file is created")
		if file != null:
			file.close()
		autosave.recovery_dir = blocked
		autosave.manifest_path = blocked.path_join("manifest.json")
		State.tabs.clear()
		State.tabs.append(invalid)
		State.active_tab = 0
		State.document = invalid
		invalid.encodable = false
		invalid.edit_dirty = true
		var failing := VoxelDocument.new()
		failing.edit_dirty = true
		State.tabs.append(failing)
		autosave._dirty = true
	)
	step("When autosave runs twice", func():
		autosave.save_now()
		expect(invalid.encodes == 1, "the invalid document encodes once")
		expect(autosave._dirty, "the write failure keeps the retry")
		autosave.save_now()
	)
	step("Then the retry skips the invalid document", func():
		expect(invalid.encodes == 1, "the invalid document is not encoded again")
		expect(autosave._dirty, "the write failure still keeps the retry")
		expect(autosave._invalid_ids.has(invalid.get_instance_id()), "the manager remembers the invalid document")
	)


func _invalid_edit_scope() -> void:
	var edited := CountingDocument.new()
	var untouched := CountingDocument.new()
	step("Given two documents that cannot encode", func():
		State.tabs.clear()
		edited.encodable = false
		edited.edit_dirty = true
		untouched.encodable = false
		untouched.edit_dirty = true
		State.tabs.append(edited)
		State.tabs.append(untouched)
		State.active_tab = 0
		State.document = edited
		autosave._dirty = true
	)
	step("When autosave runs and then the first document is edited", func():
		autosave.save_now()
		expect(edited.encodes == 1, "the first document encodes once")
		expect(untouched.encodes == 1, "the second document encodes once")
		autosave._mark_dirty()
		autosave.save_now()
	)
	step("Then only the edited document is tried again", func():
		expect(edited.encodes == 2, "the edited document is retried")
		expect(untouched.encodes == 1, "the untouched document is not retried")
	)


func _invalid_view_scope() -> void:
	var document := CountingDocument.new()
	var other := State.new_document()
	step("Given an invalid document that the manager skips", func():
		State.tabs.clear()
		State.tabs.append(document)
		State.tabs.append(other)
		State.active_tab = 0
		State.document = document
		document.encodable = false
		document.edit_dirty = true
		autosave._dirty = true
		autosave.save_now()
		expect(autosave._invalid_ids.has(document.get_instance_id()), "the manager skips the document")
	)
	step("When the current frame changes", func():
		State.frame_changed.emit()
	)
	step("Then the skip stays", func():
		expect(autosave._invalid_ids.has(document.get_instance_id()), "a frame switch keeps the skip")
	)
	step("When the tab list changes", func():
		State.tabs_changed.emit()
	)
	step("Then the skip still stays", func():
		expect(autosave._invalid_ids.has(document.get_instance_id()), "a tab change keeps the skip")
	)
	step("When the user activates another tab and returns", func():
		expect(State.activate_tab(1), "the other tab becomes active")
		expect(State.activate_tab(0), "the invalid tab becomes active again")
	)
	step("Then the skip survives the activation", func():
		expect(autosave._invalid_ids.has(document.get_instance_id()), "a tab activation keeps the skip")
	)
	step("When the document content changes", func():
		autosave._mark_dirty()
	)
	step("Then the skip clears", func():
		expect(not autosave._invalid_ids.has(document.get_instance_id()), "an edit clears the skip")
	)


func _one_per_tick() -> void:
	var documents: Array[CountingDocument] = []
	step("Given three edited documents", func():
		State.tabs.clear()
		for index in 3:
			var document := CountingDocument.new()
			document.edit_save_path = DIR.path_join("one_%d.lve" % index)
			document.file_path = document.edit_save_path
			document.edit_dirty = true
			documents.append(document)
			State.tabs.append(document)
		State.active_tab = 0
		State.document = documents[0]
		autosave._pending_documents.clear()
		for document in documents:
			autosave._remember_pending(document)
	)
	step("When one timer tick runs", func():
		autosave._save_one()
	)
	step("Then only one copy is written", func():
		expect(autosave.recovery_entries().size() == 1, "the tick writes one copy")
		var encodes := 0
		for document in documents:
			encodes += document.encodes
		expect(encodes == 1, "the tick encodes one document")
	)
	step("When the next tick runs", func():
		autosave._save_one()
	)
	step("Then the second copy is written", func():
		expect(autosave.recovery_entries().size() == 2, "the next tick writes the next copy")
	)


func _retry_backoff() -> void:
	var document := CountingDocument.new()
	step("Given a document whose copy cannot be written", func():
		State.tabs.clear()
		State.tabs.append(document)
		State.active_tab = 0
		State.document = document
		document.edit_save_path = DIR.path_join("backoff.lve")
		document.file_path = document.edit_save_path
		document.edit_dirty = true
		document.fail_writes = true
		autosave._pending_documents.clear()
		autosave._remember_pending(document)
	)
	step("When the copy fails twice", func():
		autosave._save_one()
		expect(is_equal_approx(autosave._retry_delay, 4.0), "the first failure doubles the delay")
		expect(is_equal_approx(autosave._timer.wait_time, 4.0), "the timer uses the new delay")
		autosave._save_one()
		expect(is_equal_approx(autosave._retry_delay, 8.0), "the second failure doubles again")
	)
	step("When a later copy succeeds", func():
		document.fail_writes = false
		autosave._save_one()
	)
	step("Then the delay returns to the base delay", func():
		expect(is_equal_approx(autosave._retry_delay, AutosaveScript.SAVE_DELAY_SEC), "a success resets the delay")
		expect(autosave.recovery_entries().size() == 1, "the copy is written")
	)


func _on_test_recovery(entries: Array) -> void:
	_recovery_seen = entries
