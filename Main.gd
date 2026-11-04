extends Control

## The application main scene.
##
## It restores the last document, tracks the window title, and applies the UI
## scale. It also disables the inactive tab, so only the current tab processes.

## The user path of the saved interface settings.
const UI_SETTINGS_PATH := "user://interface.cfg"
## The document that opens when no last document exists.
const STARTUP_DOCUMENT := "res://Flamingo.lve"
var _ui_scale := 0.0
var _scale_check_elapsed := 0.0
var _title_document: VoxelDocument


func _enter_tree() -> void:
	State.document_changed.connect(_on_document_changed)
	_on_document_changed()


func _exit_tree() -> void:
	State.document_changed.disconnect(_on_document_changed)
	if _title_document:
		_title_document.file_path_changed.disconnect(_update_window_title)
	_title_document = null


func _on_document_changed() -> void:
	if _title_document:
		_title_document.file_path_changed.disconnect(_update_window_title)
	_title_document = State.document
	_title_document.file_path_changed.connect(_update_window_title)
	_update_window_title()


func _update_window_title() -> void:
	get_window().title = "%s - %s" % [State.document.get_file_name(), VoxelDocument.APP_NAME]


func _ready() -> void:
	# Godot coalesces pointer motion to one event per render frame by default. A
	# long frame then turns a curved drag into a chord between two far samples,
	# and every tool paints that chord. Take each event instead, so a stroke
	# follows the pointer even when a frame runs long.
	Input.use_accumulated_input = false
	var settings := ConfigFile.new()
	if settings.load(UI_SETTINGS_PATH) == OK:
		var saved_scale := float(settings.get_value("interface", "scale", 0.0))
		_ui_scale = 0.0 if saved_scale == 0.0 else clampf(saved_scale, 1.0, 3.0)
	get_window().dpi_changed.connect(_apply_ui_scale)
	_apply_ui_scale()
	if DisplayServer.get_name() != "headless":
		var window := get_window()
		var available := DisplayServer.screen_get_usable_rect(window.current_screen).size
		window.size = Vector2i(Vector2(window.size) * window.content_scale_factor).min(Vector2i(Vector2(available) * 0.9))
		window.move_to_center()
	%TabContainer.tab_changed.connect(_on_tab_changed)
	_on_tab_changed(%TabContainer.current_tab)
	_restore_startup_document.call_deferred()


func _restore_startup_document(force: bool = false, session_path: String = "") -> void:
	if not force and not State.is_app_session():
		return
	if session_path.is_empty():
		session_path = State.SESSION_PATH
	var last := State.last_document_path(session_path)
	if not last.is_empty() and FileAccess.file_exists(last) and %MenuBar.open_document(last, true):
		return
	if FileAccess.file_exists(STARTUP_DOCUMENT):
		%MenuBar.open_document(STARTUP_DOCUMENT, false)


## Sets the UI scale. A zero value uses the automatic scale. When [param save]
## is true, it writes the value to the interface settings.
func set_ui_scale(value: float, save: bool = true) -> void:
	_ui_scale = 0.0 if value == 0.0 else clampf(value, 1.0, 3.0)
	_apply_ui_scale()
	if save:
		var settings := ConfigFile.new()
		settings.set_value("interface", "scale", _ui_scale)
		settings.save(UI_SETTINGS_PATH)


func _automatic_ui_scale() -> float:
	if DisplayServer.get_name() == "headless":
		return 1.0
	var screen_scale := DisplayServer.screen_get_scale(DisplayServer.SCREEN_OF_MAIN_WINDOW)
	if OS.get_name() == "Windows" and screen_scale == 1.0:
		screen_scale = DisplayServer.screen_get_dpi(DisplayServer.SCREEN_OF_MAIN_WINDOW) / 96.0
	return clampf(screen_scale, 1.0, 3.0)


func _apply_ui_scale() -> void:
	get_window().content_scale_factor = _automatic_ui_scale() if _ui_scale == 0.0 else _ui_scale
	var selector: OptionButton = %StatusBar.get_node("%UIScale")
	for index in selector.item_count:
		if selector.get_item_id(index) == roundi(_ui_scale * 100.0):
			selector.select(index)
			break


func _process(delta: float) -> void:
	if _ui_scale != 0.0 or DisplayServer.get_name() == "headless":
		return
	_scale_check_elapsed += delta
	if _scale_check_elapsed < 0.5:
		return
	_scale_check_elapsed = 0.0
	if not is_equal_approx(get_window().content_scale_factor, _automatic_ui_scale()):
		_apply_ui_scale()


func _on_tab_changed(_index: int) -> void:
	var current: Control = %TabContainer.get_current_tab_control()
	for tab in %TabContainer.get_children():
		if tab is Control:
			tab.process_mode = Node.PROCESS_MODE_INHERIT if tab == current else Node.PROCESS_MODE_DISABLED
	var viewport: SubViewport = %Viewport.get_node("PanelContainer/SubViewportContainer/Viewport")
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if current == %Editor else SubViewport.UPDATE_DISABLED
	if current != %Editor:
		State.stop()
