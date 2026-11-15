extends Control

## The application main scene.
##
## It restores the last document, tracks the window title, and applies the UI
## scale. It also disables the inactive tab, so only the current tab processes.

## The MCP server started or stopped.
signal mcp_changed(enabled: bool, port: int)

## The splash document that opens when no document exists or a version is new.
const SPLASH_DOCUMENT := "res://splash.lve"
## The settings section and key that hold the last used application version.
const VERSION_SECTION := "application"
const VERSION_KEY := "version"
## The MCP server and bridge scripts.
const MCP_SERVER_SCRIPT := preload("res://Globals/MCP/MCPServer.gd")
const MCP_BRIDGE_SCRIPT := preload("res://Globals/MCP/MCPBridge.gd")
const AUTOSAVE_SCRIPT := preload("res://Globals/Autosave/Autosave.gd")
## The default loopback MCP port.
const MCP_PORT := 17373
## The settings file override. Tests set a temporary file. An empty value uses
## [member State.settings_path].
var settings_path := ""
## The MCP port. Tests set zero to take a free port.
var mcp_port := MCP_PORT
## Tests turn this off, so a saved state cannot bind a port in the test process.
@export var restore_saved_agent := true
## Tests turn this off, so a quit signal cannot end the test process.
@export var quit_on_confirmed := true
## Tests turn this off, so recovery files are not written in the test process.
@export var autosave_enabled := true
var _ui_scale := 0.0
var _scale_check_elapsed := 0.0
var _title_document: VoxelDocument
var _mcp: Node = null
var _mcp_http_mode := true
var autosave = null


func _enter_tree() -> void:
	add_to_group("main")
	# The close request must wait for the save prompts. The SceneTree accepts a
	# close request by default, so the dialog appears and the app still quits.
	get_tree().auto_accept_quit = false
	# Seed the port before the status bar reads it in its own _ready.
	mcp_port = _mcp_port_setting()
	_mcp_http_mode = not _has_user_arg("--mcp-line")
	State.document_changed.connect(_on_document_changed)
	State.tabs_changed.connect(_update_window_title)
	_on_document_changed()


func _exit_tree() -> void:
	remove_from_group("main")
	State.document_changed.disconnect(_on_document_changed)
	State.tabs_changed.disconnect(_update_window_title)
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
	var title := State.document.get_file_name()
	if State.document.edit_dirty:
		title += " *"
	get_window().title = "%s - %s" % [title, VoxelDocument.APP_NAME]


func _on_window_close_requested() -> void:
	var menu := get_node_or_null("%MenuBar")
	if menu != null and menu.has_method("request_quit"):
		menu.call("request_quit")
	else:
		get_tree().quit()


func _on_quit_confirmed() -> void:
	if quit_on_confirmed:
		get_tree().quit()


func _on_recovery_available(entries: Array) -> void:
	var menu := get_node_or_null("%MenuBar")
	if menu != null:
		menu.call("show_recovery", entries)


func _on_recovery_accepted(entries: Array) -> void:
	if autosave != null:
		autosave.call("recover", entries)


func _on_recovery_discarded(entries: Array) -> void:
	if autosave != null:
		autosave.call("discard_entries", entries)


func _on_document_discarded(document: VoxelDocument) -> void:
	if autosave != null:
		autosave.call("discard_document", document)


func _ready() -> void:
	if _has_user_arg("--mcp-bridge"):
		_run_bridge()
		return
	State.reset_plugins()
	# Godot coalesces pointer motion to one event per render frame by default. A
	# long frame then turns a curved drag into a chord between two far samples,
	# and every tool paints that chord. Take each event instead, so a stroke
	# follows the pointer even when a frame runs long.
	Input.use_accumulated_input = false
	var settings := _read_interface_settings()
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
	var window := get_window()
	if not window.close_requested.is_connected(_on_window_close_requested):
		window.close_requested.connect(_on_window_close_requested)
	var menu := get_node_or_null("%MenuBar")
	if menu != null and menu.has_signal("quit_confirmed") and not menu.quit_confirmed.is_connected(_on_quit_confirmed):
		menu.quit_confirmed.connect(_on_quit_confirmed)
	if autosave_enabled:
		autosave = AUTOSAVE_SCRIPT.new()
		autosave.name = "Autosave"
		add_child(autosave)
		autosave.connect("recovery_available", _on_recovery_available)
		if menu != null:
			menu.connect("recovery_accepted", _on_recovery_accepted)
			menu.connect("recovery_discarded", _on_recovery_discarded)
			menu.connect("document_discarded", _on_document_discarded)
	var start_agent := _has_user_arg("--mcp")
	if not start_agent and restore_saved_agent and not _has_user_arg("--no-mcp"):
		start_agent = bool(settings.get_value("agent", "mcp_enabled", false))
	if start_agent:
		_start_mcp()
	_restore_startup_document.call_deferred()
	if autosave != null:
		autosave.call_deferred("check_recovery")


func _restore_startup_document(force: bool = false, session_path: String = "") -> void:
	if not force and not State.is_app_session():
		return
	if session_path.is_empty():
		session_path = _settings_file()
	var version := _current_version()
	var new_version := not version.is_empty() and _stored_version() != version
	var saved_active := State.last_tab_index(session_path)
	var paths := State.last_tabs(session_path)
	var documents: Array[VoxelDocument] = []
	var active := 0
	for index in paths.size():
		var path := paths[index]
		if not FileAccess.file_exists(path):
			continue
		var document := VoxelDocument.load_file(path)
		if document == null:
			continue
		document.edit_save_path = path
		if index == saved_active:
			active = documents.size()
		documents.append(document)
	if documents.is_empty():
		var last := State.last_document_path(session_path)
		var opened := false
		if not last.is_empty() and FileAccess.file_exists(last):
			opened = bool(%MenuBar.open_document(last, true, true))
		if not opened and FileAccess.file_exists(SPLASH_DOCUMENT):
			%MenuBar.open_document(SPLASH_DOCUMENT, false, true)
	else:
		State.set_tabs(documents, active)
	if new_version:
		_open_splash()
		_write_setting(VERSION_SECTION, VERSION_KEY, version)


## Returns the settings file. Tests can set a temporary override.
func _settings_file() -> String:
	return State.settings_path if settings_path.is_empty() else settings_path


## Returns the application version from the project settings.
func _current_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", ""))


## Returns the last version that stored settings, or an empty string.
func _stored_version() -> String:
	return str(_read_interface_settings().get_value(VERSION_SECTION, VERSION_KEY, ""))


## Makes the splash the first and active tab. It reuses an open splash tab.
func _open_splash() -> bool:
	for index in State.tabs.size():
		if State.tabs[index].file_path == SPLASH_DOCUMENT:
			if index == 0:
				State.activate_tab(index)
				return true
			var opened: Array[VoxelDocument] = [State.tabs[index]]
			for other in State.tabs.size():
				if other != index:
					opened.append(State.tabs[other])
			State.set_tabs(opened, 0)
			return true
	var splash := VoxelDocument.load_file(SPLASH_DOCUMENT)
	if splash == null:
		return false
	var documents: Array[VoxelDocument] = [splash]
	documents.append_array(State.tabs)
	State.set_tabs(documents, 0)
	return true


## Sets the UI scale. A zero value uses the automatic scale. When [param save]
## is true, it writes the value to the interface settings.
func set_ui_scale(value: float, save: bool = true) -> void:
	_ui_scale = 0.0 if value == 0.0 else clampf(value, 1.0, 3.0)
	_apply_ui_scale()
	if save:
		_write_setting("interface", "scale", _ui_scale)


## Reads the interface settings. A missing file gives default values.
func _read_interface_settings() -> ConfigFile:
	var settings := ConfigFile.new()
	settings.load(_settings_file())
	return settings


## Writes one setting and keeps the other sections. A settings file that
## cannot be read is not overwritten.
func _write_setting(section: String, key: String, value: Variant) -> void:
	var settings := ConfigFile.new()
	var error := settings.load(_settings_file())
	if error != OK and error != ERR_FILE_NOT_FOUND:
		push_warning("Cannot read the user settings: %s" % error_string(error))
		return
	settings.set_value(section, key, value)
	error = settings.save(_settings_file())
	if error != OK:
		push_warning("Cannot save the user settings: %s" % error_string(error))


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


## Returns [code]true[/code] when the user passed [param argument] after `--`.
func _has_user_arg(argument: String) -> bool:
	return OS.get_cmdline_user_args().has(argument)


## Returns the MCP port from `--mcp-port=N`, or the default port.
func _mcp_port_setting() -> int:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--mcp-port="):
			var value := argument.substr("--mcp-port=".length())
			if value.is_valid_int():
				return clampi(value.to_int(), 1, 65535)
	return MCP_PORT


## Starts or stops the in-app MCP server. The state is saved only when
## [param persist] is true. A failed start returns the listen error and keeps
## the server off.
func set_mcp_enabled(value: bool, persist := false) -> Error:
	if value == is_mcp_enabled():
		if persist:
			_write_setting("agent", "mcp_enabled", value)
		return OK
	if value:
		if _mcp == null:
			_mcp = MCP_SERVER_SCRIPT.new()
			add_child(_mcp)
		var error_value: Variant = _mcp.call("start", mcp_port, _mcp_http_mode)
		var error: Error = error_value if error_value is int else ERR_UNAVAILABLE
		if error != OK:
			return error
	else:
		_mcp.call("stop")
	if persist:
		_write_setting("agent", "mcp_enabled", value)
	mcp_changed.emit(is_mcp_enabled(), int(_mcp.call("local_port")))
	return OK


## Returns [code]true[/code] while the MCP server listens.
func is_mcp_enabled() -> bool:
	return _mcp != null and int(_mcp.call("local_port")) > 0


## Returns the port that the MCP server listens on, or zero when it is off.
func mcp_local_port() -> int:
	return int(_mcp.call("local_port")) if _mcp != null else 0


## Returns the HTTP endpoint, or an empty string in line mode or before a
## free-port start.
func mcp_url() -> String:
	if not _mcp_http_mode:
		return ""
	var port := mcp_port
	if is_mcp_enabled():
		port = int(_mcp.call("local_port"))
	if port <= 0:
		return ""
	return "http://127.0.0.1:%d/mcp" % port


## Starts the in-app MCP server for the command line flags.
func _start_mcp() -> void:
	set_mcp_enabled(true, false)


## Runs the stdio bridge until stdin closes, then quits.
func _run_bridge() -> void:
	var bridge: RefCounted = MCP_BRIDGE_SCRIPT.new()
	var code_value: Variant = bridge.call("run", mcp_port)
	var code: int = int(code_value) if code_value is int else 1
	get_tree().quit(code)
