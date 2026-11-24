extends Control


signal mcp_changed(enabled: bool, port: int)

const SPLASH_DOCUMENT := "res://splash.lve"
const VERSION_SECTION := "application"
const VERSION_KEY := "version"
const MCP_SERVER_SCRIPT := preload("res://Globals/MCP/MCPServer.gd")
const MCP_BRIDGE_SCRIPT := preload("res://Globals/MCP/MCPBridge.gd")
const AUTOSAVE_SCRIPT := preload("res://Globals/Autosave/Autosave.gd")
const MCP_PORT := 17373
const ANDROID_BASE_DPI := 160.0
const MOBILE_SCALE_FACTOR := 0.85
var settings_path := ""
var mcp_port := MCP_PORT
@export var restore_saved_agent := true
@export var quit_on_confirmed := true
@export var autosave_enabled := true
var _ui_scale := 0.0
var _scale_check_elapsed := 0.0
var _title_document: VoxelDocument
var _mcp: Node = null
var _mcp_http_mode := true
var autosave = null


func _enter_tree() -> void:
	add_to_group("main")
	get_tree().auto_accept_quit = false
	mcp_port = _mcp_port_setting()
	_mcp_http_mode = not _has_user_arg("--mcp-line")
	State.document_changed.connect(_on_document_changed)
	State.tabs_changed.connect(_update_window_title)
	_on_document_changed()


func _exit_tree() -> void:
	remove_from_group("main")
	State.set_context(null)
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
	var context := EditorContext.new()
	context.main = self
	context.menu_bar = %MenuBar as Control
	context.tab_container = %TabContainer as TabContainer
	context.editor_tab = %Editor as Control
	context.tool_bar = %ToolBar as Control
	context.option_bar = %OptionBar as Control
	context.viewport = %Viewport as Control
	context.viewport_scene = %Viewport.get_node("%ViewportScene") as Node3D
	context.control_bar = %Viewport.get_node("%ControlBar") as Control
	context.workspace = %EditorWorkspace
	State.set_context(context)
	State.reset_plugins()
	Input.use_accumulated_input = false
	var settings := _read_interface_settings()
	var saved_scale := float(settings.get_value("interface", "scale", 0.0))
	_ui_scale = 0.0 if saved_scale == 0.0 else clampf(saved_scale, 1.0, 3.0)
	get_window().dpi_changed.connect(_apply_ui_scale)
	_apply_ui_scale()
	if DisplayServer.get_name() != "headless" and not OS.has_feature("mobile"):
		var window := get_window()
		var available := DisplayServer.screen_get_usable_rect(window.current_screen).size
		window.size = Vector2i(Vector2(window.size) * window.content_scale_factor).min(Vector2i(Vector2(available) * 0.9))
		window.move_to_center()
	%TabContainer.tab_changed.connect(_on_tab_changed)
	%StatusBar.set_main(self)
	%StatusBar.set_camera(%Viewport.call("camera"))
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


func _settings_file() -> String:
	return State.settings_path if settings_path.is_empty() else settings_path


func _current_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", ""))


func _stored_version() -> String:
	return str(_read_interface_settings().get_value(VERSION_SECTION, VERSION_KEY, ""))


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


func set_ui_scale(value: float, save: bool = true) -> void:
	_ui_scale = 0.0 if value == 0.0 else clampf(value, 1.0, 3.0)
	_apply_ui_scale()
	if save:
		_write_setting("interface", "scale", _ui_scale)


func _read_interface_settings() -> ConfigFile:
	var settings := ConfigFile.new()
	settings.load(_settings_file())
	return settings


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
	if OS.has_feature("mobile"):
		return clampf(DisplayServer.screen_get_dpi(DisplayServer.SCREEN_OF_MAIN_WINDOW) / ANDROID_BASE_DPI * MOBILE_SCALE_FACTOR, 1.5, 4.0)
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
	%Viewport.call("set_rendering_active", current == %Editor)
	if current != %Editor:
		State.stop()


func _has_user_arg(argument: String) -> bool:
	return OS.get_cmdline_user_args().has(argument)


func _mcp_port_setting() -> int:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--mcp-port="):
			var value := argument.substr("--mcp-port=".length())
			if value.is_valid_int():
				return clampi(value.to_int(), 1, 65535)
	return MCP_PORT


func set_mcp_enabled(value: bool, persist := false) -> Error:
	if value == is_mcp_enabled():
		if persist:
			_write_setting("agent", "mcp_enabled", value)
		return OK
	if value:
		if _mcp == null:
			_mcp = MCP_SERVER_SCRIPT.new()
			_mcp.call("set_main", self)
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


func is_mcp_enabled() -> bool:
	return _mcp != null and int(_mcp.call("local_port")) > 0


func mcp_local_port() -> int:
	return int(_mcp.call("local_port")) if _mcp != null else 0


func mcp_bind_address() -> String:
	return str(_mcp.call("bind_address")) if _mcp != null else ""


func mcp_url() -> String:
	if not _mcp_http_mode:
		return ""
	var port := mcp_port
	if is_mcp_enabled():
		port = int(_mcp.call("local_port"))
	if port <= 0:
		return ""
	return "http://127.0.0.1:%d/mcp" % port


func _start_mcp() -> void:
	set_mcp_enabled(true, false)


func _run_bridge() -> void:
	var bridge: RefCounted = MCP_BRIDGE_SCRIPT.new()
	var code_value: Variant = bridge.call("run", mcp_port)
	var code: int = int(code_value) if code_value is int else 1
	get_tree().quit(code)
