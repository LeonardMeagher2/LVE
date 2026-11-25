class_name EditorStatusBar
extends HBoxContainer


const JobStatusWidget = preload("res://ui/JobStatus/JobStatus.gd")
const UpdateCheckerScript = preload("res://ui/StatusBar/UpdateChecker.gd")
const RELEASES_URL := "https://github.com/LeonardMeagher2/LVE/releases"
const TEXT_COLOR := Color(1, 1, 1, 0.55)
const UPDATE_COLOR := Color(1, 1, 1, 0.7)

@onready var _left: Label = $StatusLeft
@onready var _right: Label = $StatusRight
@onready var _notice: Label = %Notice
@onready var _notice_timer: Timer = $NoticeTimer
@onready var _mcp: Button = $MCP
@onready var _activity: JobStatusWidget = $Activity
@onready var _version: LinkButton = $Version
@onready var _checker: UpdateCheckerScript = $UpdateChecker

var _editor_camera: EditorCameraRig
var _main: Node
var _context: Callable
var _current_version := ""


func _ready() -> void:
	State.color_changed.connect(_refresh_status.unbind(1))
	State.frame_changed.connect(_refresh_status)
	State.frames_changed.connect(_refresh_status)
	State.document_changed.connect(_refresh_status)
	State.cells_changed.connect(_refresh_status.unbind(2))
	State.chunks_changed.connect(_refresh_status.unbind(2))
	_current_version = str(ProjectSettings.get_setting("application/config/version", ""))
	_version.text = "v%s" % _current_version
	_version.uri = RELEASES_URL
	_version.visible = not _current_version.is_empty()
	_checker.latest_release.connect(show_latest)
	_checker.start.call_deferred()
	_notice_timer.timeout.connect(_on_notice_timeout)
	_mcp.pressed.connect(_on_mcp_pressed)
	_mcp.visible = false
	if State.context != null and is_instance_valid(State.context.main):
		set_main(State.context.main)
	_refresh_status()


func set_main(main: Node) -> void:
	if _main == main:
		return
	if is_instance_valid(_main) and _main.is_connected("mcp_changed", _on_mcp_changed):
		_main.disconnect("mcp_changed", _on_mcp_changed)
	_main = main
	if _main == null or not _main.has_signal("mcp_changed"):
		_mcp.visible = false
		return
	if not _main.is_connected("mcp_changed", _on_mcp_changed):
		_main.connect("mcp_changed", _on_mcp_changed)
	_mcp.visible = true
	_sync_mcp()


func set_camera(camera: EditorCameraRig) -> void:
	if _editor_camera == camera:
		return
	if _editor_camera != null and _editor_camera.zoom_changed.is_connected(_on_zoom_changed):
		_editor_camera.zoom_changed.disconnect(_on_zoom_changed)
	_editor_camera = camera
	if _editor_camera != null and not _editor_camera.zoom_changed.is_connected(_on_zoom_changed):
		_editor_camera.zoom_changed.connect(_on_zoom_changed)
	_refresh_status()


func _on_zoom_changed(_percent: float) -> void:
	_refresh_status()


func _refresh_status() -> void:
	if _context.is_valid():
		var status: Dictionary = _context.call()
		_left.text = status.left
		_right.text = status.right
		return
	var bounds_size := State.document.bounds().size
	var zoom_percent := roundi(_editor_camera.zoom_percent()) if _editor_camera else 100
	_left.text = "#%s   %d×%d×%d   #%d/%d   %d%%" % [
		State.current_color.to_html(false),
		roundi(bounds_size.x), roundi(bounds_size.y), roundi(bounds_size.z),
		State.current_frame + 1, State.document.frames.size(), zoom_percent,
	]
	_right.text = ""


func _sync_mcp() -> void:
	if _main == null:
		return
	var enabled := bool(_main.call("is_mcp_enabled"))
	var color := Color(1, 1, 1, 0.9) if enabled else TEXT_COLOR
	_mcp.add_theme_color_override("icon_normal_color", color)
	_mcp.add_theme_color_override("icon_hover_color", color)
	_mcp.add_theme_color_override("icon_pressed_color", color)
	_mcp.add_theme_color_override("icon_focus_color", color)
	var url := str(_main.call("mcp_url"))
	var place := " in line mode" if url.is_empty() else " at %s" % url
	if enabled:
		_mcp.tooltip_text = "MCP server on%s. Click to stop." % place
	else:
		_mcp.tooltip_text = "MCP server off. Click to start."


func _on_mcp_changed(_enabled: bool, _port: int) -> void:
	_sync_mcp()


func _on_mcp_pressed() -> void:
	if _main == null:
		return
	var enabling := not bool(_main.call("is_mcp_enabled"))
	var result: Variant = _main.call("set_mcp_enabled", enabling, true)
	var error: Error = result if result is int else ERR_UNAVAILABLE
	if error == OK and enabling:
		_copy_mcp_setup()
	_sync_mcp()
	if error == OK:
		return
	%MCPError.dialog_text = "Cannot start the MCP server on %s:%d. %s. Another program may use this port." % [
		str(_main.call("mcp_bind_address")),
		int(_main.get("mcp_port")),
		error_string(error),
	]
	%MCPError.popup_centered()


func _copy_mcp_setup() -> void:
	var prompt := str(_main.call("mcp_setup_prompt"))
	if prompt.is_empty():
		return
	DisplayServer.clipboard_set(prompt)
	_show_notice("Setup prompt copied to the clipboard")


func _show_notice(text: String) -> void:
	_notice.text = text
	_notice.visible = true
	_notice_timer.start()


func _on_notice_timeout() -> void:
	_notice.visible = false


func show_latest(version: String, url: String, newer: bool) -> void:
	if _current_version.is_empty():
		return
	var latest := version if version.begins_with("v") else "v" + version
	_version.uri = url
	_version.tooltip_text = "Open the %s release" % latest
	if newer:
		_version.text = "v%s → %s" % [_current_version, latest]
		_version.add_theme_color_override("font_color", UPDATE_COLOR)
	else:
		_version.text = "v%s" % _current_version
		_version.add_theme_color_override("font_color", TEXT_COLOR)


func _on_ui_scale_item_selected(index: int) -> void:
	if is_instance_valid(_main):
		_main.call("set_ui_scale", %UIScale.get_item_id(index) / 100.0)


func set_context(provider: Callable) -> void:
	_context = provider
	_refresh_status()
