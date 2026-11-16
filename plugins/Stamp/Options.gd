extends HBoxContainer

## The stamp option bar.
##
## It chooses the stamp source. A file source opens the frame panel. A selection
## source uses the current voxel selection.

## Emitted when the user picks an LVE file.
signal file_chosen(path: String)
## Emitted when the user chooses the current voxel selection.
signal selection_requested()
## Emitted when the center-on-cursor option changes.
signal center_changed(on: bool)
## Emitted when the user clears the stamp source.
signal clear_requested()

var _busy := false
var _clear_enabled := false

@onready var _file_button: Button = $File
@onready var _selection_button: Button = $UseSelection
@onready var _clear_button: Button = $Clear
@onready var _source_label: Label = $Source
@onready var _error_label: Label = $Error
@onready var _file_dialog: FileDialog = $FileDialog


func _ready() -> void:
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.clear_filters()
	_file_dialog.add_filter("*.lve ; LVE document")
	_file_dialog.add_filter("*.lve.png ; LVE document with preview")
	_file_dialog.file_selected.connect(_on_file_selected)
	State.selection_changed.connect(_sync_selection)
	State.frame_changed.connect(_sync_selection)
	State.document_changed.connect(_sync_selection)
	State.activity_changed.connect(_sync_selection)
	_sync_selection()
	_sync_clear()


func _exit_tree() -> void:
	if is_instance_valid(_file_dialog) and _file_dialog.visible:
		_file_dialog.hide()


## Sets the source description that the option bar shows.
func set_source(text: String) -> void:
	_source_label.text = text


## Shows or clears the source error.
func set_error(text: String) -> void:
	_error_label.text = text
	_error_label.visible = not text.is_empty()


## Disables the source controls while a stamp prepares.
func set_busy(busy: bool) -> void:
	_busy = busy
	_file_button.disabled = busy
	_sync_selection()
	_sync_clear()


## Sets the center-on-cursor button without emitting a signal.
func set_center(on: bool) -> void:
	$Center.set_pressed_no_signal(on)


## Enables the clear button while a source exists.
func set_clear_enabled(enabled: bool) -> void:
	_clear_enabled = enabled
	_sync_clear()


func _sync_clear() -> void:
	_clear_button.disabled = _busy or not _clear_enabled


func _on_file_pressed() -> void:
	_file_dialog.popup_centered_ratio(0.6)


func _on_file_selected(path: String) -> void:
	file_chosen.emit(path)


func _on_use_selection_pressed() -> void:
	selection_requested.emit()


func _on_center_toggled(on: bool) -> void:
	center_changed.emit(on)


func _on_clear_pressed() -> void:
	clear_requested.emit()


func _sync_selection() -> void:
	var frame := State.get_current_voxel_frame()
	_selection_button.disabled = _busy or State.edit_busy() or frame == null or frame.count() == 0 or State.selection.is_empty()
