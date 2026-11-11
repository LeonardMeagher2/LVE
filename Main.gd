extends Control

## The application main scene.
##
## It restores the last document, tracks the window title, and applies the UI
## scale. It also disables the inactive tab, so only the current tab processes.

## The MCP server started or stopped.
signal mcp_changed(enabled: bool, port: int)

## The user path of the saved interface settings.
const UI_SETTINGS_PATH := "user://interface.cfg"
## The document that opens when no last document exists.
const STARTUP_DOCUMENT := "res://Flamingo.lve"
## The MCP server and bridge scripts.
const MCP_SERVER_SCRIPT := preload("res://Globals/MCP/MCPServer.gd")
const MCP_BRIDGE_SCRIPT := preload("res://Globals/MCP/MCPBridge.gd")
## The default loopback MCP port.
const MCP_PORT := 17373
## The interface settings file. Tests point it at a temporary file.
var interface_settings_path := UI_SETTINGS_PATH
## The MCP port. Tests set zero to take a free port.
var mcp_port := MCP_PORT
## Tests turn this off, so a saved state cannot bind a port in the test process.
var restore_saved_agent := true
## Tests turn this off, so a quit signal cannot end the test process.
var quit_on_confirmed := true
var _ui_scale := 0.0
var _scale_check_elapsed := 0.0
var _title_document: VoxelDocument
var _mcp: Node = null
var _mcp_http_mode := true


func _enter_tree() -> void:
	# Seed the port before the status bar reads it in its own _ready.
	mcp_port = _mcp_port_setting()
	_mcp_http_mode = not _has_user_arg("--mcp-line")
	State.document_changed.connect(_on_document_changed)
	State.tabs_changed.connect(_update_window_title)
	_on_document_changed()


func _exit_tree() -> void:
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


func _ready() -> void:
	if _has_user_arg("--mcp-bridge"):
		_run_bridge()
		return
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
	var start_agent := _has_user_arg("--mcp")
	if not start_agent and restore_saved_agent and not _has_user_arg("--no-mcp"):
		start_agent = bool(settings.get_value("agent", "mcp_enabled", false))
	if start_agent:
		_start_mcp()
	_restore_startup_document.call_deferred()


func _restore_startup_document(force: bool = false, session_path: String = "") -> void:
	if not force and not State.is_app_session():
		return
	if session_path.is_empty():
		session_path = State.SESSION_PATH
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
	if not documents.is_empty():
		State.set_tabs(documents, active)
		return
	var last := State.last_document_path(session_path)
	if not last.is_empty() and FileAccess.file_exists(last) and %MenuBar.open_document(last, true, true):
		return
	if FileAccess.file_exists(STARTUP_DOCUMENT):
		%MenuBar.open_document(STARTUP_DOCUMENT, false, true)


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
	settings.load(interface_settings_path)
	return settings


## Writes one interface setting and keeps the other sections.
func _write_setting(section: String, key: String, value: Variant) -> void:
	var settings := _read_interface_settings()
	settings.set_value(section, key, value)
	var error := settings.save(interface_settings_path)
	if error != OK:
		push_warning("Cannot save the interface settings: %s" % error_string(error))


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
