extends HBoxContainer

## The main menu bar.
##
## It opens, saves, and creates documents. It also shows the undo and redo
## buttons and the model settings.

## The user path of the file dialog settings.
const FILE_SETTINGS_PATH := "user://file_dialog.cfg"

## The file that stores the favorites and the last folder. Tests set a temporary
## path before the node enters the tree.
var file_settings_path := FILE_SETTINGS_PATH

## The save path of the active document, or an empty string for a new document.
var current_save_path: String:
	get:
		return State.document.edit_save_path
	set(value):
		State.document.edit_save_path = value
var _save_format := OptionButton.new()
# The tab that the close prompt is about, or -1.
var _pending_close_index := -1
# The tab to close after a successful Save As, or -1.
var _close_after_save := -1
# The last folder that the file dialog used.
var _last_dir := ""


func _ready() -> void:
	%FileDialog.access = FileDialog.ACCESS_FILESYSTEM
	%FileDialog.file_selected.connect(_on_file_selected)
	%FileDialog.canceled.connect(_on_file_dialog_canceled)
	%FileDialog.visibility_changed.connect(_on_file_dialog_visibility_changed)
	_restore_file_dialog()
	_save_format.add_item("LVE document (.lve)")
	_save_format.add_item("LVE document with PNG preview (.lve.png)")
	_save_format.item_selected.connect(_on_save_format_selected)
	_save_format.hide()
	%FileDialog.get_vbox().add_child(_save_format)
	%DocumentTabs.close_requested.connect(_on_tab_close_requested)
	%CloseTabDialog.add_button("Discard", true, "discard")
	%CloseTabDialog.confirmed.connect(_on_close_tab_save)
	%CloseTabDialog.custom_action.connect(_on_close_tab_action)
	%CloseTabDialog.canceled.connect(_on_close_tab_cancel)
	State.document_changed.connect(_sync_model_settings)
	State.model_settings_changed.connect(_sync_model_settings)
	State.activity_changed.connect(_sync_model_settings)
	_sync_model_settings()
	State.history_changed.connect(_sync_history_buttons)
	State.activity_changed.connect(_sync_history_buttons)
	State.edit_state_changed.connect(_sync_history_buttons)
	State.active_tab_changed.connect(_sync_history_buttons)
	State.active_tab_changed.connect(_sync_model_settings)
	_sync_history_buttons()


func _sync_history_buttons() -> void:
	# An open edit captured a start snapshot that a history change would
	# invalidate, so the controls stay disabled until the edit closes.
	var busy := State.edit_busy() or State.active_edit() != null
	%UndoBtn.disabled = busy or not State.undo_redo.has_undo()
	%RedoBtn.disabled = busy or not State.undo_redo.has_redo()


func _sync_model_settings() -> void:
	%ModelSettingsBtn.disabled = State.edit_busy()


func _on_model_settings_pressed() -> void:
	%DocumentSettingsModal.open(State.document.size, State.document.smooth_normals, State.document.ao_strength)


## Saves the document to one path and returns the error code. A PNG path also
## renders and stores a preview. The save path changes only on success.
func save_doc(path: String) -> Error:
	if State.edit_busy():
		return ERR_BUSY
	var document := State.document
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
	current_save_path = path
	document.file_path = path
	document.edit_dirty = false
	State.tabs_changed.emit()
	_remember_session()
	return OK


func _remember_session() -> void:
	if State.is_app_session():
		State.remember_session()


func _show_file_error(message: String) -> void:
	%FileError.dialog_text = message
	%FileError.popup_centered()


func _on_file_selected(path: String) -> void:
	if %FileDialog.file_mode == FileDialog.FILE_MODE_OPEN_FILE:
		await _on_file_opened(path)
		return
	var close_index := _close_after_save
	_close_after_save = -1
	var error := await save_doc(path)
	if error == OK and close_index >= 0 and close_index < State.tabs.size():
		State.close_tab(close_index)
		_remember_session()


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
	var index := _pending_close_index
	_pending_close_index = -1
	if index < 0 or index >= State.tabs.size():
		return
	if index != State.active_tab and not State.activate_tab(index):
		return
	var document := State.document
	if document.edit_save_path.is_empty():
		_close_after_save = index
		_on_save_as_btn_pressed()
		return
	var error := await save_doc(document.edit_save_path)
	if error == OK:
		State.close_tab(index)
		_remember_session()


func _on_close_tab_action(action: StringName) -> void:
	if action != &"discard":
		return
	var index := _pending_close_index
	_pending_close_index = -1
	if index >= 0 and index < State.tabs.size():
		State.close_tab(index)
		_remember_session()


func _on_close_tab_cancel() -> void:
	_pending_close_index = -1


func _on_file_dialog_canceled() -> void:
	_close_after_save = -1
	_pending_close_index = -1


# Restores the favorite folders and the last folder. The favorite list is
# shared by all FileDialog nodes, so set it before the dialog is shown.
func _restore_file_dialog() -> void:
	var config := ConfigFile.new()
	if config.load(file_settings_path) != OK:
		return
	var favorites: Variant = config.get_value("files", "favorites", PackedStringArray())
	if favorites is PackedStringArray:
		FileDialog.set_favorite_list(favorites)
	var last_dir: Variant = config.get_value("files", "last_dir", "")
	if last_dir is String and DirAccess.dir_exists_absolute(last_dir):
		_last_dir = last_dir


func _save_file_dialog() -> void:
	var dialog: FileDialog = %FileDialog
	var current := dialog.current_dir
	if not current.is_empty() and DirAccess.dir_exists_absolute(current):
		_last_dir = current
	var config := ConfigFile.new()
	config.load(file_settings_path)
	config.set_value("files", "favorites", FileDialog.get_favorite_list())
	config.set_value("files", "last_dir", _last_dir)
	config.save(file_settings_path)


func _on_file_dialog_visibility_changed() -> void:
	if not %FileDialog.visible:
		_save_file_dialog()


func _show_file_dialog() -> void:
	if not _last_dir.is_empty() and DirAccess.dir_exists_absolute(_last_dir):
		%FileDialog.current_dir = _last_dir
	%FileDialog.popup_centered()

func _on_new_btn_pressed() -> void:
	if State.edit_busy():
		return
	State.open_tab(VoxelDocument.new())
	_remember_session()

func _on_open_btn_pressed() -> void:
	if State.edit_busy():
		return
	%FileDialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_save_format.hide()
	%FileDialog.clear_filters()
	%FileDialog.add_filter("*.lve ; LVE document")
	%FileDialog.add_filter(State.get_image_file_filter())
	_show_file_dialog()

## Opens one document file and returns [code]true[/code] on success. When
## [param saved] is true, it records the path as the current save path. Open
## reuses an empty, clean tab. Otherwise it adds a tab. The startup restore
## passes [param replace] to reuse the initial tab without a check.
func open_document(path: String, saved: bool = true, replace: bool = false) -> bool:
	var document := VoxelDocument.load_file(path)
	if document == null:
		return false
	document.edit_save_path = path if saved else ""
	if replace or _can_reuse_tab():
		State.document = document
	else:
		State.open_tab(document)
	if saved:
		_remember_session()
	return true


# Returns true when the active tab holds an empty document that was never saved.
# Open reuses it instead of adding another empty tab.
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
		var error: Error = await get_node("/root/ImageImportPlugin").import_image(path)
		if error == OK:
			current_save_path = ""
		if error != OK and error != ERR_BUSY:
			_show_file_error("Cannot import the image: %s" % error_string(error))
		return
	_show_file_error("The file type is unsupported.")


func _on_save_btn_pressed() -> void:
	if current_save_path.is_empty():
		_on_save_as_btn_pressed()
		return
	await save_doc(current_save_path)

func _on_save_as_btn_pressed() -> void:
	if State.edit_busy():
		return
	%FileDialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_format.show()
	var format_index := 1 if current_save_path.get_extension().to_lower() == "png" else 0
	_save_format.select(format_index)
	%FileDialog.current_file = State.document.get_file_name()
	_on_save_format_selected(format_index)
	_show_file_dialog()


func _on_save_format_selected(index: int) -> void:
	var base_name := document_basename(%FileDialog.current_file)
	var suffix := ".lve.png" if index == 1 else ".lve"
	%FileDialog.clear_filters()
	%FileDialog.add_filter("*" + suffix + " ; LVE document")
	%FileDialog.current_file = base_name + suffix


## Returns the base file name of a document. It drops the `.lve` and
## `.lve.png` suffixes.
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
