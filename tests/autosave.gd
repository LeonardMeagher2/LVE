extends "res://tests/test.gd"

## Checks the recovery copy beside the original and the startup listing.

const DIR := "user://autosave_test"
const MANIFEST := "user://autosave_test/manifest.json"
const AutosaveScript := preload("res://Globals/Autosave/Autosave.gd")

var autosave
var _recovery_seen: Array = []


func _ready() -> void:
	test("autosave writes and deletes a recovery copy", _save_delete, "autosave_save")
	test("recovery lists and loads an autosave file", _recover, "autosave_recover")
	test("discard removes a recovery copy", _discard, "autosave_discard")


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
		expect(loaded != null and loaded.frames[0].has(Vector3i.ZERO), "the recovery file holds the cell")
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
		expect(recovered.frames[0].has(Vector3i.ZERO), "the recovered document holds the cell")
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


func _on_test_recovery(entries: Array) -> void:
	_recovery_seen = entries
