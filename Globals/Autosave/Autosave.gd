class_name Autosave
extends Node

## Keeps a recovery copy of every edited document.
##
## The copy lives next to the original as `~{name}.lve`, so it is easy to find
## and open by hand. A small manifest in the user folder indexes the copies, so
## startup can find them even after a crash. A normal save or a discard deletes
## the copy. On startup the editor offers the remaining copies for recovery.

## Emitted once at startup when recovery files exist.
signal recovery_available(entries: Array)

## The recovery folder and its manifest. Tests point these at a temporary folder.
var recovery_dir := "user://recovery"
var manifest_path := "user://recovery/manifest.json"
## Tests turn this off when they do not exercise recovery.
var enabled := true

## The delay after the first edit before a copy is written.
const SAVE_DELAY_SEC := 2.0

var _timer: Timer
## Instance id -> {file, path, name, updated}.
var _entries := {}
var _dirty := false


func _ready() -> void:
	if not enabled:
		return
	DirAccess.make_dir_recursive_absolute(recovery_dir)
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = SAVE_DELAY_SEC
	_timer.timeout.connect(_on_timer_timeout)
	add_child(_timer)
	_connect_state()


func _exit_tree() -> void:
	_disconnect_state()


func _connect_state() -> void:
	if not State.cells_changed.is_connected(_on_cells_changed):
		State.cells_changed.connect(_on_cells_changed)
	if not State.chunks_changed.is_connected(_on_chunks_changed):
		State.chunks_changed.connect(_on_chunks_changed)
	if not State.frames_changed.is_connected(_mark_dirty):
		State.frames_changed.connect(_mark_dirty)
	if not State.frame_changed.is_connected(_mark_dirty):
		State.frame_changed.connect(_mark_dirty)
	if not State.palette_changed.is_connected(_mark_dirty):
		State.palette_changed.connect(_mark_dirty)
	if not State.tag_changed.is_connected(_mark_dirty):
		State.tag_changed.connect(_mark_dirty)
	if not State.size_changed.is_connected(_mark_dirty):
		State.size_changed.connect(_mark_dirty)
	if not State.model_settings_changed.is_connected(_mark_dirty):
		State.model_settings_changed.connect(_mark_dirty)
	if not State.document_saved.is_connected(_on_document_saved):
		State.document_saved.connect(_on_document_saved)
	if not State.tabs_changed.is_connected(_on_tabs_changed):
		State.tabs_changed.connect(_on_tabs_changed)


func _disconnect_state() -> void:
	if State.cells_changed.is_connected(_on_cells_changed):
		State.cells_changed.disconnect(_on_cells_changed)
	if State.chunks_changed.is_connected(_on_chunks_changed):
		State.chunks_changed.disconnect(_on_chunks_changed)
	if State.frames_changed.is_connected(_mark_dirty):
		State.frames_changed.disconnect(_mark_dirty)
	if State.frame_changed.is_connected(_mark_dirty):
		State.frame_changed.disconnect(_mark_dirty)
	if State.palette_changed.is_connected(_mark_dirty):
		State.palette_changed.disconnect(_mark_dirty)
	if State.tag_changed.is_connected(_mark_dirty):
		State.tag_changed.disconnect(_mark_dirty)
	if State.size_changed.is_connected(_mark_dirty):
		State.size_changed.disconnect(_mark_dirty)
	if State.model_settings_changed.is_connected(_mark_dirty):
		State.model_settings_changed.disconnect(_mark_dirty)
	if State.document_saved.is_connected(_on_document_saved):
		State.document_saved.disconnect(_on_document_saved)
	if State.tabs_changed.is_connected(_on_tabs_changed):
		State.tabs_changed.disconnect(_on_tabs_changed)


func _on_cells_changed(_frame: int, _affected: Array[Vector3i]) -> void:
	_mark_dirty()


func _on_chunks_changed(_frame: int, _affected: Array[Vector3i]) -> void:
	_mark_dirty()


func _on_tabs_changed() -> void:
	_mark_dirty()


func _mark_dirty() -> void:
	# Playback steps the frame every tick and emits `frame_changed`. No content
	# changed, so the copy must not be rewritten for each step.
	if not enabled or State.is_playing:
		return
	_dirty = true
	if _timer != null and _timer.is_stopped():
		_timer.start()


func _on_timer_timeout() -> void:
	if not enabled:
		return
	if State.edit_busy() or State.active_edit() != null:
		_timer.start()
		return
	save_now()


## Writes a recovery copy of every dirty document and removes stale copies.
func save_now() -> void:
	if not enabled:
		return
	_dirty = false
	DirAccess.make_dir_recursive_absolute(recovery_dir)
	var current_ids := {}
	for document in State.tabs:
		if document == null:
			continue
		var id := document.get_instance_id()
		current_ids[id] = true
		if document.edit_dirty:
			_save_document(document)
		else:
			_remove_entry(id)
	for id in _entries.keys():
		if not current_ids.has(id):
			_remove_entry(id)
	_write_manifest()


## Returns the recovery entries that are still on disk.
func list_recovery() -> Array:
	var entries := _read_manifest()
	var known := {}
	for entry in entries:
		known[str(entry.get("file", ""))] = true
	if State.is_app_session():
		for path in State.last_tabs(State.SESSION_PATH):
			var original := str(path)
			if original.is_empty():
				continue
			var recovery := _recovery_path_for_path(original)
			if recovery == original or not FileAccess.file_exists(recovery) or known.has(recovery):
				continue
			entries.append({
				"file": recovery,
				"path": original,
				"name": original.get_file(),
				"updated": 0,
			})
			known[recovery] = true
	for entry in _scan_recovery_dir():
		if not known.has(str(entry.get("file", ""))):
			entries.append(entry)
	return entries


## Emits [signal recovery_available] when a recovery copy exists.
func check_recovery() -> void:
	if not enabled:
		return
	var entries := list_recovery()
	if not entries.is_empty():
		recovery_available.emit(entries)


## Loads the selected recovery copies and opens them as dirty tabs.
func recover(entries: Array) -> void:
	if not enabled:
		return
	for value in entries:
		if not (value is Dictionary):
			continue
		var entry: Dictionary = value
		var file := str(entry.get("file", ""))
		if file.is_empty() or not FileAccess.file_exists(file):
			continue
		var document := VoxelDocument.load_file(file)
		if document == null:
			continue
		var original := str(entry.get("path", ""))
		document.file_path = original
		document.edit_save_path = original
		document.edit_dirty = true
		_open_recovered(document, original)
		_adopt(document, entry)
	_write_manifest()


## Deletes the selected recovery copies.
func discard_entries(entries: Array) -> void:
	for value in entries:
		if not (value is Dictionary):
			continue
		var entry: Dictionary = value
		var file := str(entry.get("file", ""))
		if not file.is_empty() and FileAccess.file_exists(file):
			DirAccess.remove_absolute(file)
		for id in _entries.keys():
			if str(_entries[id].get("file", "")) == file:
				_entries.erase(id)
	_write_manifest()


## Deletes the recovery copy of one document.
func discard_document(document: VoxelDocument) -> void:
	if document == null:
		return
	_remove_entry(document.get_instance_id())
	_write_manifest()


## Returns the current in-memory recovery entries. Tests use it.
func recovery_entries() -> Array:
	return _entries.values()


func _save_document(document: VoxelDocument) -> void:
	var id := document.get_instance_id()
	var encoded := document.encode_document()
	if encoded.is_empty():
		return
	var preferred := _recovery_path_for(document)
	var file := preferred
	var error := document.save_file(file, null, encoded)
	if error != OK:
		file = _fallback_path(document)
		error = document.save_file(file, null, encoded)
		if error != OK:
			return
	var entry: Dictionary
	if _entries.has(id):
		entry = _entries[id]
	else:
		entry = {"file": "", "path": "", "name": "", "updated": 0}
		_entries[id] = entry
	var old_file := str(entry.get("file", ""))
	if not old_file.is_empty() and old_file != file and FileAccess.file_exists(old_file):
		DirAccess.remove_absolute(old_file)
	entry["file"] = file
	entry["path"] = document.edit_save_path if not document.edit_save_path.is_empty() else document.file_path
	entry["name"] = document.get_file_name()
	entry["updated"] = int(Time.get_unix_time_from_system())


func _recovery_path_for(document: VoxelDocument) -> String:
	var original := document.edit_save_path if not document.edit_save_path.is_empty() else document.file_path
	if original.is_empty():
		return _fallback_path(document)
	return _recovery_path_for_path(original)


func _recovery_path_for_path(original: String) -> String:
	var base := original.get_base_dir()
	var file_name := original.get_file()
	if file_name.to_lower().ends_with(".lve.png"):
		file_name = file_name.left(-4)
	return base.path_join("~" + file_name)


func _fallback_path(document: VoxelDocument) -> String:
	return recovery_dir.path_join("~%s-%d.lve" % [document.get_file_name(), document.get_instance_id()])


func _remove_entry(id: int) -> void:
	if not _entries.has(id):
		return
	var entry: Dictionary = _entries[id]
	var file := str(entry.get("file", ""))
	if not file.is_empty() and FileAccess.file_exists(file):
		DirAccess.remove_absolute(file)
	_entries.erase(id)


func _on_document_saved(document: VoxelDocument) -> void:
	if document == null:
		return
	_remove_entry(document.get_instance_id())
	_write_manifest()


func _open_recovered(document: VoxelDocument, original: String) -> void:
	if not original.is_empty():
		for index in range(State.tabs.size()):
			var existing := State.tabs[index]
			if existing.edit_save_path == original or existing.file_path == original:
				if State.active_tab == index or State.activate_tab(index):
					State.document = document
					return
	State.open_tab(document)


func _adopt(document: VoxelDocument, entry: Dictionary) -> void:
	var file := str(entry.get("file", ""))
	for id in _entries.keys():
		if str(_entries[id].get("file", "")) == file:
			_entries.erase(id)
	_entries[document.get_instance_id()] = entry


func _read_manifest() -> Array:
	if not FileAccess.file_exists(manifest_path):
		return []
	var text := FileAccess.get_file_as_string(manifest_path)
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		return []
	var documents: Variant = data.get("documents", [])
	if not (documents is Array):
		return []
	var entries: Array = []
	for value in documents:
		if not (value is Dictionary):
			continue
		var entry: Dictionary = value
		var file := str(entry.get("file", ""))
		if file.is_empty() or not FileAccess.file_exists(file):
			continue
		entries.append({
			"file": file,
			"path": str(entry.get("path", "")),
			"name": str(entry.get("name", "")),
			"updated": int(entry.get("updated", 0)),
		})
	return entries


func _scan_recovery_dir() -> Array:
	var entries: Array = []
	var dir := DirAccess.open(recovery_dir)
	if dir == null:
		return entries
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.get_extension().to_lower() == "lve":
			entries.append({
				"file": recovery_dir.path_join(name),
				"path": "",
				"name": name,
				"updated": 0,
			})
		name = dir.get_next()
	dir.list_dir_end()
	return entries


func _write_manifest() -> void:
	if not enabled:
		return
	DirAccess.make_dir_recursive_absolute(recovery_dir)
	var documents: Array = []
	for entry in _entries.values():
		documents.append(entry)
	var text := JSON.stringify({"documents": documents})
	var temporary_path := manifest_path + ".tmp"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.flush()
	file.close()
	DirAccess.rename_absolute(temporary_path, manifest_path)
