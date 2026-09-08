extends HBoxContainer


func _ready() -> void:
	State.frames_changed.connect(_rebuild_dropdown)
	State.tag_changed.connect(_sync)
	State.edit_mode_changed.connect(_sync_edit)
	_rebuild_dropdown()
	_sync()
	_sync_edit()


func _rebuild_dropdown() -> void:
	%TagDropdown.clear()
	for tag in State.document.tags:
		%TagDropdown.add_item(tag.name)
	_sync()
	_sync_edit()


func _sync() -> void:
	%TagDropdown.selected = State.active_tag
	var has_tag := State.get_active_tag() != null
	if has_tag:
		%TagNameEdit.text = State.get_active_tag().name


func _sync_edit() -> void:
	var has_any_tags := not State.document.tags.is_empty()
	var editing := State.edit_mode and State.get_active_tag() != null
	visible = has_any_tags
	%TagDropdown.visible = not editing
	%TagNameEdit.visible = editing
	if editing:
		%TagNameEdit.text = State.get_active_tag().name


func _on_tag_selected(index: int) -> void:
	State.select_tag(index)


func _on_name_text_changed(new_text: String) -> void:
	var tag := State.get_active_tag()
	if tag == null:
		return
	tag.name = new_text
	%TagDropdown.set_item_text(State.active_tag, new_text)


func _on_add_pressed() -> void:
	State.add_tag("Tag")


func _on_remove_pressed() -> void:
	if State.active_tag >= 0:
		State.remove_tag()
