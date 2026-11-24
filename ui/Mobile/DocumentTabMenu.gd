extends HBoxContainer


signal close_requested(index: int)

var _syncing := false


func _ready() -> void:
	%Tabs.item_selected.connect(_on_item_selected)
	%Close.pressed.connect(_on_close_pressed)
	State.tabs_changed.connect(_sync)
	State.active_tab_changed.connect(_sync)
	_sync()


func _sync() -> void:
	_syncing = true
	var tabs: OptionButton = %Tabs
	tabs.clear()
	for index in State.tabs.size():
		var document := State.tabs[index]
		tabs.add_item(_title(document), index)
		tabs.set_item_tooltip(index, _tooltip(document))
	if not State.tabs.is_empty():
		tabs.select(State.active_tab)
	%Close.disabled = State.tabs.is_empty()
	_syncing = false


func _title(document: VoxelDocument) -> String:
	var title := document.get_file_name()
	return "* " + title if document.edit_dirty else title


func _tooltip(document: VoxelDocument) -> String:
	return document.file_path if not document.file_path.is_empty() else "Not saved"


func _on_item_selected(index: int) -> void:
	if _syncing:
		return
	if not State.activate_tab(index):
		_sync()


func _on_close_pressed() -> void:
	close_requested.emit(State.active_tab)
