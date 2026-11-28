extends RefCounted


signal document_changed()
signal document_deactivating()
signal document_created()
signal document_saved(document: VoxelDocument)
signal workspace_capture_requested()
signal frames_changed()
signal frame_changed()
signal layers_changed()
signal active_layer_changed()
signal tag_changed()
signal is_playing_toggled(toggled_on: bool)
signal tabs_changed()
signal active_tab_changed()
signal session_remember_requested()

var playback := AnimationPlayback.new()
var tabs: Array[VoxelDocument] = []
var active_tab := 0

var palette_provider := Callable()
var switch_blocked := Callable()
var on_deactivated := Callable()
var on_installed := Callable()
var on_adopted := Callable()

var document: VoxelDocument:
	get:
		return _active_document
	set(value):
		set_document(value)

var _active_document: VoxelDocument
var _adopting := false


func _init() -> void:
	playback.frame_changed.connect(frame_changed.emit)
	playback.is_playing_toggled.connect(is_playing_toggled.emit)
	playback.tag_changed.connect(tag_changed.emit)
	_active_document = VoxelDocument.new()
	_active_document.add_tag("Default", 0, _active_document.frame_count() - 1)
	tabs.append(_active_document)
	playback.document = _active_document


func new_document() -> VoxelDocument:
	var created := VoxelDocument.new()
	created.reset_workspace = true
	if palette_provider.is_valid():
		created.palette = palette_provider.call()
	return created


func set_document(value: VoxelDocument) -> void:
	var created := not (value is VoxelDocument)
	var next: VoxelDocument = value if not created else new_document()
	if next == _active_document:
		return
	if tabs.is_empty():
		tabs.append(next)
		active_tab = 0
	else:
		tabs[active_tab] = next
	_adopt_document(next)
	if created:
		document_created.emit()
	tabs_changed.emit()


func add_tab(value: VoxelDocument) -> int:
	var next: VoxelDocument = value if value is VoxelDocument else new_document()
	var existing := tabs.find(next)
	if existing >= 0:
		return existing
	tabs.append(next)
	tabs_changed.emit()
	return tabs.size() - 1


func open_tab(value: VoxelDocument) -> int:
	var index := add_tab(value)
	activate_tab(index)
	return index


func capture_workspace(captured: VoxelDocument) -> void:
	if captured == null or captured == _active_document:
		workspace_capture_requested.emit()


func record_saved(saved: VoxelDocument, path: String) -> void:
	saved.file_path = path
	saved.edit_save_path = path
	saved.edit_dirty = false
	tabs_changed.emit()
	session_remember_requested.emit()
	document_saved.emit(saved)


func record_opened(opened: VoxelDocument, path: String) -> void:
	opened.edit_save_path = path
	session_remember_requested.emit()


func set_tabs(documents: Array[VoxelDocument], index: int = 0) -> void:
	if documents.is_empty():
		documents.append(new_document())
	tabs.clear()
	tabs.append_array(documents)
	active_tab = clampi(index, 0, documents.size() - 1)
	_adopt_document(tabs[active_tab])
	tabs_changed.emit()
	active_tab_changed.emit()


func activate_tab(index: int) -> bool:
	if index < 0 or index >= tabs.size() or index == active_tab:
		return false
	if _is_switch_blocked():
		return false
	_adopt_document(tabs[index])
	active_tab = index
	active_tab_changed.emit()
	return true


func close_tab(index: int) -> bool:
	if index < 0 or index >= tabs.size():
		return false
	if _is_switch_blocked():
		return false
	var was_active := index == active_tab
	var closed := tabs[index]
	tabs.remove_at(index)
	if was_active:
		if tabs.is_empty():
			tabs.append(new_document())
		var next := mini(index, tabs.size() - 1)
		_adopt_document(tabs[next])
		active_tab = next
	elif index < active_tab:
		active_tab -= 1
	closed.edit_history.clear_history()
	closed.edit_history.free()
	closed.edit_history = null
	tabs_changed.emit()
	if was_active:
		active_tab_changed.emit()
	return true


func is_adopting() -> bool:
	return _adopting


func update(delta: float) -> void:
	playback.update(delta)


func _is_switch_blocked() -> bool:
	return switch_blocked.is_valid() and bool(switch_blocked.call())


func _adopt_document(value: VoxelDocument) -> void:
	document_deactivating.emit()
	if on_deactivated.is_valid():
		on_deactivated.call()
	_adopting = true
	_active_document = value
	if on_installed.is_valid():
		on_installed.call()
	if _active_document.tags.is_empty():
		_active_document.add_tag("Default", 0, _active_document.frame_count() - 1)
	_active_document.edit_frame = clampi(_active_document.edit_frame, 0, _active_document.frame_count() - 1)
	_active_document.edit_layer = clampi(_active_document.edit_layer, 0, _active_document.layers.size() - 1)
	_active_document.edit_tag = clampi(_active_document.edit_tag, -1, _active_document.tags.size() - 1)
	playback.document = _active_document
	playback.restore_playback()
	document_changed.emit()
	frames_changed.emit()
	frame_changed.emit()
	layers_changed.emit()
	active_layer_changed.emit()
	tag_changed.emit()
	_adopting = false
	if on_adopted.is_valid():
		on_adopted.call()
