extends HBoxContainer


signal quit_confirmed()
signal recovery_accepted(entries: Array)
signal recovery_discarded(entries: Array)
signal document_discarded(document: VoxelDocument)

@export var single_document := false
var settings_path := ""

var current_save_path: String:
	get:
		return State.document.edit_save_path
	set(value):
		State.document.edit_save_path = value
var _save_format := OptionButton.new()
var _pending_close_index := -1
var _close_after_save_document: VoxelDocument
var _quit_active := false
var _quit_requested := false
var _quit_indices: Array[int] = []
var _quit_position := 0
var _quit_after_save := false
var _recovery_entries: Array = []
var _recovery_checkboxes: Array[CheckBox] = []
var _last_dir := ""
var _native_save := false


func _ready() -> void:
	%FileDialog.access = FileDialog.ACCESS_FILESYSTEM
	%FileDialog.file_selected.connect(_on_file_selected)
	%FileDialog.canceled.connect(_on_file_dialog_canceled)
	%FileDialog.visibility_changed.connect(_on_file_dialog_visibility_changed)
	var window := get_window()
	if not window.files_dropped.is_connected(_on_files_dropped):
		window.files_dropped.connect(_on_files_dropped)
	_restore_file_dialog()
	_save_format.add_item("LVE document (.lve)")
	_save_format.add_item("LVE document with PNG preview (.lve.png)")
	_save_format.item_selected.connect(_on_save_format_selected)
	_save_format.hide()
	%FileDialog.get_vbox().add_child(_save_format)
	%DocumentTabs.close_requested.connect(_on_tab_close_requested)
	if single_document:
		%DocumentTabs.hide()
		var tab_separator := get_node_or_null("Sep2")
		if tab_separator is CanvasItem:
			tab_separator.hide()
	%CloseTabDialog.add_button("Discard", true, "discard")
	%CloseTabDialog.confirmed.connect(_on_close_tab_save)
	%CloseTabDialog.custom_action.connect(_on_close_tab_action)
	%CloseTabDialog.canceled.connect(_on_close_tab_cancel)
	%RecoveryDialog.add_button("Discard all", true, "discard")
	%RecoveryDialog.confirmed.connect(_on_recovery_confirmed)
	%RecoveryDialog.custom_action.connect(_on_recovery_action)
	%RecoveryDialog.canceled.connect(_on_recovery_canceled)
	State.document_changed.connect(_sync_model_settings)
	State.model_settings_changed.connect(_sync_model_settings)
	State.activity_changed.connect(_sync_model_settings)
	_sync_model_settings()
	State.history_changed.connect(_sync_history_buttons)
	State.activity_changed.connect(_sync_history_buttons)
	State.edit_state_changed.connect(_sync_history_buttons)
	State.active_tab_changed.connect(_sync_history_buttons)
	State.active_tab_changed.connect(_sync_model_settings)
	State.activity_changed.connect(_retry_quit)
	_sync_history_buttons()


func _sync_history_buttons() -> void:
	var busy := State.edit_busy() or State.active_edit() != null
	%UndoBtn.disabled = busy or not State.undo_redo.has_undo()
	%RedoBtn.disabled = busy or not State.undo_redo.has_redo()


func _sync_model_settings() -> void:
	%ModelSettingsBtn.disabled = State.edit_busy()


func _on_model_settings_pressed() -> void:
	%DocumentSettingsModal.open(State.document.size, State.document.smooth_normals, State.document.ao_strength)


func save_doc(path: String) -> Error:
	if State.edit_busy():
		return ERR_BUSY
	var document := State.document
	State.capture_workspace(document)
	var encoded := document.encode_document()
	if encoded.is_empty():
		_show_file_error("The document exceeds the format limits or contains invalid data.")
		return ERR_INVALID_DATA
	var preview: Image
	if path.get_extension().to_lower() == "png":
		var operation := State.begin_operation("Rendering preview", -1, true, self)
		preview = await VoxelImageRenderer.render_document_preview(document)
		State.finish_operation(operation)
		if State.document != document:
			return ERR_BUSY
		if preview == null:
			_show_file_error("The PNG preview requires a display.")
			return ERR_UNAVAILABLE
	var err := document.save_file(path, preview, encoded)
	if err != OK:
		_show_file_error("Cannot save the document: %s" % error_string(err))
		return err
	State.record_saved(document, path)
	return OK


func _remember_session() -> void:
	if State.is_app_session():
		State.remember_session()


func _show_file_error(message: String) -> void:
	%FileError.dialog_text = message
	%FileError.popup_centered()


func _on_files_dropped(files: PackedStringArray) -> void:
	for path in files:
		await _on_file_opened(path)


func _on_file_selected(path: String) -> void:
	if %FileDialog.file_mode == FileDialog.FILE_MODE_OPEN_FILE:
		await _on_file_opened(path)
		return
	var close_document := _close_after_save_document
	_close_after_save_document = null
	var error := await save_doc(path)
	if _quit_after_save:
		_quit_after_save = false
		if error == OK:
			_advance_quit()
		else:
			_cancel_quit()
		return
	if error == OK and close_document != null:
		var close_index := State.tabs.find(close_document)
		if close_index >= 0:
			State.close_tab(close_index)
			_remember_session()


func request_quit() -> void:
	if _quit_active:
		return
	if State.edit_busy():
		_quit_requested = true
		return
	_quit_requested = false
	var edited: Array[int] = []
	for index in range(State.tabs.size()):
		if State.tabs[index].edit_dirty:
			edited.append(index)
	if edited.is_empty():
		_remember_session()
		quit_confirmed.emit()
		return
	_quit_active = true
	_quit_indices = edited
	_quit_position = 0
	_show_quit_dialog()


func _retry_quit() -> void:
	if _quit_requested and not _quit_active and not State.edit_busy():
		request_quit()


func _show_quit_dialog() -> void:
	while _quit_position < _quit_indices.size():
		var index := _quit_indices[_quit_position]
		if index < State.tabs.size() and State.tabs[index].edit_dirty:
			_pending_close_index = index
			var document := State.tabs[index]
			%CloseTabDialog.dialog_text = "Save the changes to %s?" % document.get_file_name()
			%CloseTabDialog.popup_centered()
			return
		_quit_position += 1
	_finish_quit()


func _advance_quit() -> void:
	_pending_close_index = -1
	_quit_position += 1
	_show_quit_dialog()


func _finish_quit() -> void:
	_quit_active = false
	_quit_requested = false
	_quit_indices.clear()
	_quit_position = 0
	_pending_close_index = -1
	_quit_after_save = false
	_remember_session()
	quit_confirmed.emit()


func _cancel_quit() -> void:
	_quit_active = false
	_quit_requested = false
	_quit_indices.clear()
	_quit_position = 0
	_pending_close_index = -1
	_quit_after_save = false


func _save_quit_document() -> void:
	var index := _pending_close_index
	if index < 0 or index >= State.tabs.size():
		_cancel_quit()
		return
	if index != State.active_tab and not State.activate_tab(index):
		_cancel_quit()
		return
	var document := State.document
	if document.edit_save_path.is_empty():
		_quit_after_save = true
		if not _on_save_as_btn_pressed():
			_cancel_quit()
		return
	var error := await save_doc(document.edit_save_path)
	if error != OK:
		_cancel_quit()
		return
	_advance_quit()


func _on_tab_close_requested(index: int) -> void:
	if State.edit_busy() or index < 0 or index >= State.tabs.size():
		return
	var document := State.tabs[index]
	if not document.edit_dirty:
		State.close_tab(index)
		_remember_session()
		return
	_pending_close_index = index
	%CloseTabDialog.dialog_text = "Save the changes to %s?" % document.get_file_name()
	%CloseTabDialog.popup_centered()


func _on_close_tab_save() -> void:
	%CloseTabDialog.hide()
	if _quit_active:
		await _save_quit_document()
		return
	var index := _pending_close_index
	_pending_close_index = -1
	if index < 0 or index >= State.tabs.size():
		return
	if index != State.active_tab and not State.activate_tab(index):
		return
	var document := State.document
	if document.edit_save_path.is_empty():
		_close_after_save_document = document
		if not _on_save_as_btn_pressed():
			_close_after_save_document = null
		return
	var error := await save_doc(document.edit_save_path)
	if error == OK:
		State.close_tab(index)
		_remember_session()


func _on_close_tab_action(action: StringName) -> void:
	if action != &"discard":
		return
	%CloseTabDialog.hide()
	if _quit_active:
		var quit_index := _pending_close_index
		if quit_index >= 0 and quit_index < State.tabs.size():
			document_discarded.emit(State.tabs[quit_index])
		_advance_quit()
		return
	var index := _pending_close_index
	_pending_close_index = -1
	if index >= 0 and index < State.tabs.size():
		document_discarded.emit(State.tabs[index])
		State.close_tab(index)
		_remember_session()


func _on_close_tab_cancel() -> void:
	%CloseTabDialog.hide()
	if _quit_active:
		_cancel_quit()
		return
	_pending_close_index = -1


func _on_file_dialog_canceled() -> void:
	_close_after_save_document = null
	_pending_close_index = -1
	if _quit_after_save:
		_quit_after_save = false
		_cancel_quit()


func show_recovery(entries: Array) -> void:
	_recovery_entries = []
	for value in entries:
		if value is Dictionary:
			_recovery_entries.append(value)
	if _recovery_entries.is_empty():
		return
	_clear_recovery_options()
	for entry in _recovery_entries:
		var name := str(entry.get("name", ""))
		if name.is_empty():
			name = "Untitled"
		var path := str(entry.get("path", ""))
		var checkbox := CheckBox.new()
		checkbox.text = name if not path.is_empty() else name + " (unsaved)"
		checkbox.tooltip_text = path if not path.is_empty() else str(entry.get("file", ""))
		checkbox.button_pressed = true
		checkbox.clip_text = true
		checkbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		checkbox.toggled.connect(_on_recovery_toggled)
		%RecoveryOptions.add_child(checkbox)
		_recovery_checkboxes.append(checkbox)
	_update_recovery_buttons()
	%RecoveryDialog.popup_centered()


func _on_recovery_confirmed() -> void:
	var selected: Array = []
	for index in range(_recovery_checkboxes.size()):
		if _recovery_checkboxes[index].button_pressed:
			selected.append(_recovery_entries[index])
	if selected.is_empty():
		return
	%RecoveryDialog.hide()
	_recovery_entries = []
	_clear_recovery_options()
	recovery_accepted.emit(selected)


func _on_recovery_action(action: StringName) -> void:
	if action != &"discard":
		return
	%RecoveryDialog.hide()
	var entries := _recovery_entries
	_recovery_entries = []
	_clear_recovery_options()
	recovery_discarded.emit(entries)


func _on_recovery_canceled() -> void:
	%RecoveryDialog.hide()
	_recovery_entries = []
	_clear_recovery_options()


func _on_recovery_toggled(_pressed: bool) -> void:
	_update_recovery_buttons()


func _update_recovery_buttons() -> void:
	var any := false
	for checkbox in _recovery_checkboxes:
		if checkbox.button_pressed:
			any = true
			break
	%RecoveryDialog.get_ok_button().disabled = not any


func _clear_recovery_options() -> void:
	for checkbox in _recovery_checkboxes:
		if not is_instance_valid(checkbox):
			continue
		%RecoveryOptions.remove_child(checkbox)
		checkbox.queue_free()
	_recovery_checkboxes.clear()


func _settings_file() -> String:
	return State.settings_path if settings_path.is_empty() else settings_path


func _restore_file_dialog() -> void:
	var config := ConfigFile.new()
	if config.load(_settings_file()) != OK:
		return
	var favorites: Variant = config.get_value("files", "favorites", PackedStringArray())
	if favorites is PackedStringArray:
		FileDialog.set_favorite_list(favorites)
	var recents: Variant = config.get_value("files", "recent", PackedStringArray())
	if recents is PackedStringArray:
		FileDialog.set_recent_list(recents)
	var last_dir: Variant = config.get_value("files", "last_dir", "")
	if last_dir is String and DirAccess.dir_exists_absolute(last_dir):
		_last_dir = last_dir


func _save_file_dialog() -> void:
	if settings_path.is_empty() and not State.is_app_session():
		return
	var dialog: FileDialog = %FileDialog
	var current := dialog.current_dir
	if not current.is_empty() and DirAccess.dir_exists_absolute(current):
		_last_dir = current
	var config := ConfigFile.new()
	var error := config.load(_settings_file())
	if error != OK and error != ERR_FILE_NOT_FOUND:
		push_warning("Cannot read the user settings: %s" % error_string(error))
		return
	config.set_value("files", "favorites", FileDialog.get_favorite_list())
	config.set_value("files", "recent", FileDialog.get_recent_list())
	config.set_value("files", "last_dir", _last_dir)
	error = config.save(_settings_file())
	if error != OK:
		push_warning("Cannot save the user settings: %s" % error_string(error))


func _on_file_dialog_visibility_changed() -> void:
	if not %FileDialog.visible:
		_save_file_dialog()


func _show_file_dialog() -> void:
	if not _last_dir.is_empty() and DirAccess.dir_exists_absolute(_last_dir):
		%FileDialog.current_dir = _last_dir
	%FileDialog.popup_centered()


func _show_native_dialog(save: bool) -> void:
	_native_save = save
	var title := "Save the document" if save else "Open a document"
	var mode := DisplayServer.FILE_DIALOG_MODE_SAVE_FILE if save else DisplayServer.FILE_DIALOG_MODE_OPEN_FILE
	var filters := PackedStringArray(["*.lve"]) if save else PackedStringArray(["*.lve", "*.png"])
	DisplayServer.file_dialog_show(title, "", "", false, mode, filters, _on_native_dialog_closed)


func _on_native_dialog_closed(status: bool, paths: PackedStringArray, _filter_index: int) -> void:
	var save := _native_save
	_native_save = false
	if not status or paths.is_empty():
		return
	if save:
		await save_doc(paths[0])
		return
	await _on_file_opened(paths[0])

func _on_new_btn_pressed() -> void:
	if State.edit_busy():
		return
	if single_document:
		State.document = State.new_document()
	else:
		State.open_tab(State.new_document())
	State.select_palette_entry(0)
	_remember_session()

func _on_open_btn_pressed() -> void:
	if State.edit_busy():
		return
	if OS.has_feature("mobile"):
		_show_native_dialog(false)
		return
	%FileDialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_save_format.hide()
	%FileDialog.clear_filters()
	%FileDialog.add_filter("*.lve ; LVE document")
	%FileDialog.add_filter(State.get_image_file_filter())
	_show_file_dialog()

func open_document(path: String, saved: bool = true, replace: bool = false) -> bool:
	var document := VoxelDocument.load_file(path)
	if document == null:
		return false
	if replace or single_document or _can_reuse_tab():
		State.document = document
	else:
		State.open_tab(document)
	if saved:
		State.record_opened(document, path)
	return true


func _can_reuse_tab() -> bool:
	var document := State.document
	return document.edit_save_path.is_empty() and not document.edit_dirty \
		and document.frames.size() == 1 and document.frames[0].count() == 0

func _on_file_opened(path: String) -> void:
	if State.edit_busy():
		return
	var extension := path.get_extension().to_lower()
	if extension in ["lve", "png"]:
		if open_document(path):
			return
		if extension == "lve":
			_show_file_error("Cannot open the document. The file is invalid or its version is unsupported.")
			return
	if path.get_extension().to_lower() in State.IMAGE_EXTENSIONS:
		var placeholder: VoxelDocument = null
		if not _can_reuse_tab():
			if single_document:
				State.document = State.new_document()
			else:
				placeholder = State.new_document()
				State.open_tab(placeholder)
		var importer := get_node_or_null("/root/ImageImportPlugin")
		if importer == null:
			_close_placeholder(placeholder)
			_show_file_error("The image importer is not available.")
			return
		var error: Error = await importer.import_image(path)
		if error == OK:
			current_save_path = ""
		else:
			_close_placeholder(placeholder)
			if error != ERR_BUSY:
				_show_file_error("Cannot import the image: %s" % error_string(error))
		return
	_show_file_error("The file type is unsupported.")


func _close_placeholder(placeholder: VoxelDocument) -> void:
	if placeholder == null:
		return
	var index := State.tabs.find(placeholder)
	if index >= 0:
		State.close_tab(index)


func _on_save_btn_pressed() -> void:
	if current_save_path.is_empty():
		_on_save_as_btn_pressed()
		return
	await save_doc(current_save_path)

func _on_save_as_btn_pressed() -> bool:
	if State.edit_busy():
		return false
	if OS.has_feature("mobile"):
		_show_native_dialog(true)
		return true
	%FileDialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_format.show()
	var format_index := 1 if current_save_path.get_extension().to_lower() == "png" else 0
	_save_format.select(format_index)
	%FileDialog.current_file = State.document.get_file_name()
	_on_save_format_selected(format_index)
	_show_file_dialog()
	return true


func _on_save_format_selected(index: int) -> void:
	var base_name := document_basename(%FileDialog.current_file)
	var suffix := ".lve.png" if index == 1 else ".lve"
	%FileDialog.clear_filters()
	%FileDialog.add_filter("*" + suffix + " ; LVE document")
	%FileDialog.current_file = base_name + suffix


static func document_basename(file_name: String) -> String:
	if file_name.to_lower().ends_with(".lve.png"):
		return file_name.left(-8)
	return file_name.get_basename()


func _on_undo_btn_pressed() -> void:
	if not State.edit_busy():
		State.undo()


func _on_redo_btn_pressed() -> void:
	if not State.edit_busy():
		State.redo()
