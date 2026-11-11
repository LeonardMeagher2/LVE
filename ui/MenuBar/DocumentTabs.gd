extends TabBar

## The document tab strip in the menu bar.
##
## It shows the open documents and switches the active one. A close request goes
## to the menu bar, which owns the save prompt.

## Emitted when the user asks to close one tab.
signal close_requested(index: int)

# Guards the programmatic current tab writes, so the view does not activate a
# document that it is only mirroring.
var _syncing := false


func _ready() -> void:
	State.tabs_changed.connect(_sync)
	State.active_tab_changed.connect(_sync)
	tab_changed.connect(_on_tab_changed)
	tab_close_pressed.connect(_on_tab_close_pressed)
	_sync()


func _sync() -> void:
	_syncing = true
	while tab_count > State.tabs.size():
		remove_tab(tab_count - 1)
	for index in State.tabs.size():
		var document := State.tabs[index]
		if index >= tab_count:
			add_tab()
		set_tab_title(index, _title(document))
		set_tab_tooltip(index, _tooltip(document))
	if not State.tabs.is_empty():
		current_tab = State.active_tab
	_syncing = false


func _title(document: VoxelDocument) -> String:
	var title := document.get_file_name()
	# Keep the unsaved marker at the start. A long name is clipped from the end
	# by the tab width, so a trailing marker would disappear.
	return "* " + title if document.edit_dirty else title


func _tooltip(document: VoxelDocument) -> String:
	return document.file_path if not document.file_path.is_empty() else "Not saved"


func _on_tab_changed(index: int) -> void:
	if _syncing:
		return
	if not State.activate_tab(index):
		_sync()


func _on_tab_close_pressed(index: int) -> void:
	close_requested.emit(index)
