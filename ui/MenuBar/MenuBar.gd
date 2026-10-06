extends HBoxContainer

var current_save_path:String = ""


func save_doc(path:String) -> void:
	if State.edit_busy():
		return
	current_save_path = path
	var err := ResourceSaver.save(State.document, path)
	if err != OK:
		push_error("Voxi: save failed: %s" % error_string(err))

func _on_new_btn_pressed() -> void:
	State.document = null

func _on_open_btn_pressed() -> void:
	if State.edit_busy():
		return
	%FileDialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	%FileDialog.clear_filters()
	%FileDialog.add_filter("*.tres ; Voxel animation")
	%FileDialog.add_filter(State.get_image_file_filter())
	%FileDialog.file_selected.connect(_on_file_opened, CONNECT_ONE_SHOT)
	%FileDialog.popup_centered()

func _on_file_opened(path: String) -> void:
	if path.get_extension().to_lower() in State.IMAGE_EXTENSIONS:
		var error: Error = await get_node("/root/ImageImportPlugin").import_image(path)
		if error == OK:
			current_save_path = ""
		if error != OK and error != ERR_BUSY:
			push_error("Voxi: image import failed: %s" % error_string(error))
		return
	var res: Resource = ResourceLoader.load(path)
	if res is VoxiDocument:
		State.document = res as VoxiDocument
		current_save_path = path
	else:
		push_warning("Voxi: not a VoxiDocument resource: " + path)


func _on_save_btn_pressed() -> void:
	if current_save_path.is_empty():
		_on_save_as_btn_pressed()
		return
	save_doc(current_save_path)

func _on_save_as_btn_pressed() -> void:
	%FileDialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	%FileDialog.clear_filters()
	%FileDialog.add_filter("*.tres ; Voxel animation")
	%FileDialog.file_selected.connect(save_doc, CONNECT_ONE_SHOT)
	%FileDialog.popup_centered()


func _on_undo_btn_pressed() -> void:
	if not State.edit_busy():
		State.undo_redo.undo()


func _on_redo_btn_pressed() -> void:
	if not State.edit_busy():
		State.undo_redo.redo()
