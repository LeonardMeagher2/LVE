class_name EditorStatusBar
extends HBoxContainer

@onready var _left: Label = $StatusLeft
@onready var _right: Label = $StatusRight
@onready var _activity: HBoxContainer = $Activity
@onready var _activity_label: Label = $Activity/ActivityLabel
@onready var _activity_progress: ProgressBar = $Activity/ActivityProgress

const ACTIVITY_DELAY_MS := 200
var _editor_camera: EditorCameraRig
var _context: Callable
var _cancel: Callable


func _ready() -> void:
	State.color_changed.connect(_refresh_status.unbind(1))
	State.frame_changed.connect(_refresh_status)
	State.frames_changed.connect(_refresh_status)
	State.document_changed.connect(_refresh_status)
	State.activity_changed.connect(_refresh_activity)
	if owner and owner.has_node("%Viewport"):
		_editor_camera = owner.get_node("%Viewport").get_node("%CameraRig")
		_editor_camera.zoom_changed.connect(_refresh_status.unbind(1))
	_refresh_status()
	_refresh_activity()
	$Activity/Cancel.pressed.connect(func():
		if _cancel.is_valid():
			_cancel.call()
	)


func _process(_delta: float) -> void:
	if not _activity.visible and State.get_activity() != null:
		_refresh_activity()


func _refresh_status() -> void:
	if _context.is_valid():
		var status: Dictionary = _context.call()
		_left.text = status.left
		_right.text = status.right
		return
	var size := State.document.bounds().size
	var zoom_percent := roundi(_editor_camera.zoom_percent()) if _editor_camera else 100
	_left.text = "#%s" % State.current_color.to_html(false)
	_right.text = "%d×%d×%d   Frame %d/%d   %d%%" % [
		roundi(size.x), roundi(size.y), roundi(size.z),
		State.current_frame + 1, State.document.frames.size(), zoom_percent,
	]


func _refresh_activity() -> void:
	var operation := State.get_activity()
	_activity.visible = operation != null and State.activity_elapsed_ms() >= ACTIVITY_DELAY_MS
	if operation == null:
		return
	$Activity/Cancel.visible = operation.foreground and _cancel.is_valid() and operation.owner_ref != null and operation.owner_ref.get_ref() == _cancel.get_object()
	_activity_progress.indeterminate = operation.total <= 0
	if operation.total > 0:
		var percent := clampf(operation.completed * 100.0 / operation.total, 0.0, 100.0)
		_activity_progress.value = percent
		_activity_label.text = "%s… %d%%" % [operation.label, floori(percent)]
	else:
		_activity_label.text = "%s…" % operation.label
		if not operation.detail.is_empty():
			_activity_label.text += " " + operation.detail


func _on_ui_scale_item_selected(index: int) -> void:
	get_node("/root/Main").set_ui_scale(%UIScale.get_item_id(index) / 100.0)


func set_context(provider: Callable, cancel := Callable()) -> void:
	_context = provider
	_cancel = cancel
	_refresh_status()
	_refresh_activity()
