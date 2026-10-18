extends HBoxContainer

var current_save_path:String = ""
var _save_format := OptionButton.new()


func _ready() -> void:
	%FileDialog.access = FileDialog.ACCESS_FILESYSTEM
	%FileDialog.file_selected.connect(_on_file_selected)
	_save_format.add_item("LVE document (.lve)")
	_save_format.add_item("LVE document with PNG preview (.lve.png)")
	_save_format.item_selected.connect(_on_save_format_selected)
	_save_format.hide()
	%FileDialog.get_vbox().add_child(_save_format)
	%ModelSettingsBtn.get_popup().id_pressed.connect(_on_model_setting_selected)
	%ModelSettingsBtn.about_to_popup.connect(_sync_model_settings)
	State.document_changed.connect(_sync_model_settings)
	State.model_settings_changed.connect(_sync_model_settings)
	State.activity_changed.connect(_sync_model_settings)
	_sync_model_settings()
	State.history_changed.connect(_sync_history_buttons)
	State.activity_changed.connect(_sync_history_buttons)
	_sync_history_buttons()


func _sync_history_buttons() -> void:
	var busy := State.edit_busy()
	%UndoBtn.disabled = busy or not State.undo_redo.has_undo()
	%RedoBtn.disabled = busy or not State.undo_redo.has_redo()


func _sync_model_settings() -> void:
	var popup: PopupMenu = %ModelSettingsBtn.get_popup()
	popup.set_item_checked(0, State.document.smooth_normals)
	popup.set_item_disabled(0, State.edit_busy())
	%ModelSettingsBtn.disabled = State.edit_busy()


func _on_model_setting_selected(id: int) -> void:
	if id == 0:
		State.set_smooth_normals(not State.document.smooth_normals)
	_sync_model_settings()


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
		var operation := State.begin_operation("Rendering document preview", -1, true, self)
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
	if State.is_app_session():
		State.remember_document(path)
	return OK


func _show_file_error(message: String) -> void:
	%FileError.dialog_text = message
	%FileError.popup_centered()


func _on_file_selected(path: String) -> void:
	if %FileDialog.file_mode == FileDialog.FILE_MODE_OPEN_FILE:
		await _on_file_opened(path)
	else:
		await save_doc(path)

func _on_new_btn_pressed() -> void:
	if State.edit_busy():
		return
	current_save_path = ""
	State.document = null
	if State.is_app_session():
		State.forget_document()

func _on_open_btn_pressed() -> void:
	if State.edit_busy():
		return
	%FileDialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_save_format.hide()
	%FileDialog.clear_filters()
	%FileDialog.add_filter("*.lve ; LVE document")
	%FileDialog.add_filter(State.get_image_file_filter())
	%FileDialog.popup_centered()

func open_document(path: String, saved: bool = true) -> bool:
	var document := VoxelDocument.load_file(path)
	if document == null:
		return false
	State.document = document
	if saved:
		current_save_path = path
		if State.is_app_session():
			State.remember_document(path)
	return true

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
	%FileDialog.popup_centered()


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
