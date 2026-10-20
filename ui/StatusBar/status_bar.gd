class_name EditorStatusBar
extends HBoxContainer

# The widget script is preloaded as a type alias. A new class_name is not in the
# global class cache until the editor regenerates it.
const JobStatusWidget = preload("res://ui/JobStatus/job_status.gd")

@onready var _left: Label = $StatusLeft
@onready var _right: Label = $StatusRight
@onready var _activity: JobStatusWidget = $Activity

var _editor_camera: EditorCameraRig
var _context: Callable


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


func _on_ui_scale_item_selected(index: int) -> void:
	get_node("/root/Main").set_ui_scale(%UIScale.get_item_id(index) / 100.0)


func set_context(provider: Callable) -> void:
	_context = provider
	# The job widget owns the cancel button. It cancels through State, so the
	# button and Escape share one cancel path.
	_refresh_status()
