class_name ControlBar
extends HBoxContainer

signal zoom_requested(percent: float)
signal grid_toggled(visible: bool)
signal center_requested
signal view_requested(name: String)
signal projection_requested(orthogonal: bool)
signal unshaded_requested(on: bool)

const VIEWS := {
	"top": "Top",
	"bottom": "Bottom",
	"front": "Front",
	"back": "Back",
	"left": "Left",
	"right": "Right",
	"isometric": "Isometric",
}

@onready var _slider: HSlider = $ZoomSlider
@onready var _grid: Button = $GridToggle
@onready var _center_btn: Button = $CenterBtn
@onready var _camera_menu: MenuButton = $CameraMenu
@onready var _pan: Button = $PanToggle
@onready var _rotate: Button = $RotateToggle

var _syncing := false
var _ortho := false
var _unshaded := false


func _ready() -> void:
	_center_btn.pressed.connect(center_requested.emit)
	_pan.toggled.connect(_on_pan_toggled)
	_rotate.toggled.connect(_on_rotate_toggled)
	State.view_mode_changed.connect(_on_view_mode_changed)
	_build_view_menu()


func set_zoom(percent: float) -> void:
	_syncing = true
	_slider.value = percent
	_syncing = false


func set_grid_visible(v: bool) -> void:
	_grid.button_pressed = v


func set_projection(orthogonal: bool) -> void:
	_ortho = orthogonal
	_apply_checks()


func set_unshaded(on: bool) -> void:
	_unshaded = on
	_apply_checks()


func _build_view_menu() -> void:
	var popup := _camera_menu.get_popup()
	for v: String in VIEWS:
		popup.add_item(VIEWS[v])
		popup.set_item_metadata(popup.item_count - 1, v)
	popup.add_separator()
	popup.add_check_item("Orthographic")
	popup.set_item_metadata(popup.item_count - 1, "orthographic")
	popup.add_check_item("Unshaded")
	popup.set_item_metadata(popup.item_count - 1, "unshaded")
	popup.index_pressed.connect(_on_view_selected)


func _on_view_selected(index: int) -> void:
	var v := str(_camera_menu.get_popup().get_item_metadata(index))
	match v:
		"orthographic":
			_ortho = not _ortho
			_apply_checks()
			projection_requested.emit(_ortho)
		"unshaded":
			_unshaded = not _unshaded
			_apply_checks()
			unshaded_requested.emit(_unshaded)
		_:
			if VIEWS.has(v):
				view_requested.emit(v)


func _apply_checks() -> void:
	var popup := _camera_menu.get_popup()
	for i in popup.item_count:
		match popup.get_item_metadata(i):
			"orthographic":
				popup.set_item_checked(i, _ortho)
			"unshaded":
				popup.set_item_checked(i, _unshaded)


func _on_pan_toggled(on: bool) -> void:
	if on:
		State.view_mode = State.ViewMode.PAN
	elif State.view_mode == State.ViewMode.PAN:
		State.view_mode = State.ViewMode.NONE


func _on_rotate_toggled(on: bool) -> void:
	if on:
		State.view_mode = State.ViewMode.ROTATE
	elif State.view_mode == State.ViewMode.ROTATE:
		State.view_mode = State.ViewMode.NONE


func _on_view_mode_changed(mode) -> void:
	_sync_buttons.call_deferred(mode)


func _sync_buttons(mode) -> void:
	_pan.set_pressed_no_signal(mode == State.ViewMode.PAN)
	_rotate.set_pressed_no_signal(mode == State.ViewMode.ROTATE)


func _on_zoom_slider_changed(v: float) -> void:
	if _syncing:
		return
	zoom_requested.emit(v)


func _on_zoom_one_pressed() -> void:
	zoom_requested.emit(100.0)


func _on_grid_toggled(v: bool) -> void:
	grid_toggled.emit(v)
