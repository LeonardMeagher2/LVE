class_name EditorStatusBar
extends HBoxContainer

## The application status bar.
##
## It shows the current color, the model size, the frame, and the zoom. It also
## shows the application version and the latest release link. A context provider
## can replace the text for one workspace. It hosts the job status widget.

# The widget script is preloaded as a type alias. A new class_name is not in the
# global class cache until the editor regenerates it.
const JobStatusWidget = preload("res://ui/JobStatus/job_status.gd")
# The update checker uses the same preload pattern.
const UpdateCheckerScript = preload("res://ui/StatusBar/UpdateChecker.gd")
## The fallback releases page, used before a release check completes.
const RELEASES_URL := "https://github.com/LeonardMeagher2/LVE/releases"
## The dim status text color.
const TEXT_COLOR := Color(1, 1, 1, 0.3372549)
## The brighter color of a version link that is behind the latest release.
const UPDATE_COLOR := Color(1, 1, 1, 0.7)

@onready var _left: Label = $StatusLeft
@onready var _right: Label = $StatusRight
@onready var _activity: JobStatusWidget = $Activity
@onready var _version: LinkButton = $Version
@onready var _checker: UpdateCheckerScript = $UpdateChecker

var _editor_camera: EditorCameraRig
var _context: Callable
var _current_version := ""


func _ready() -> void:
	State.color_changed.connect(_refresh_status.unbind(1))
	State.frame_changed.connect(_refresh_status)
	State.frames_changed.connect(_refresh_status)
	State.document_changed.connect(_refresh_status)
	State.cells_changed.connect(_refresh_status.unbind(2))
	State.chunks_changed.connect(_refresh_status.unbind(2))
	if owner and owner.has_node("%Viewport"):
		_editor_camera = owner.get_node("%Viewport").get_node("%CameraRig")
		_editor_camera.zoom_changed.connect(_refresh_status.unbind(1))
	_current_version = str(ProjectSettings.get_setting("application/config/version", ""))
	_version.text = "v%s" % _current_version
	_version.uri = RELEASES_URL
	_version.visible = not _current_version.is_empty()
	_checker.latest_release.connect(show_latest)
	_checker.start.call_deferred()
	_refresh_status()


func _refresh_status() -> void:
	if _context.is_valid():
		var status: Dictionary = _context.call()
		_left.text = status.left
		_right.text = status.right
		return
	var bounds_size := State.document.bounds().size
	var zoom_percent := roundi(_editor_camera.zoom_percent()) if _editor_camera else 100
	_left.text = "#%s" % State.current_color.to_html(false)
	_right.text = "%d×%d×%d   Frame %d/%d   %d%%" % [
		roundi(bounds_size.x), roundi(bounds_size.y), roundi(bounds_size.z),
		State.current_frame + 1, State.document.frames.size(), zoom_percent,
	]


## Points the version link at the latest release and marks a newer one.
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
	get_node("/root/Main").set_ui_scale(%UIScale.get_item_id(index) / 100.0)


## Sets a context provider that returns the left and right status text. An
## invalid callable restores the editor status.
func set_context(provider: Callable) -> void:
	_context = provider
	# The job widget owns the cancel button. It cancels through State, so the
	# button and Escape share one cancel path.
	_refresh_status()
