extends VBoxContainer

@onready var camera_menu:MenuButton = %CameraMenu

func _ready() -> void:
	camera_menu.get_popup().index_pressed.connect(_on_camera_index_pressed)

func _on_camera_index_pressed(index:int) -> void:
	var text = camera_menu.get_popup().get_item_text(index).to_lower()
	
	match text:
		"orthographic":
			var is_orthogonal = not camera_menu.get_popup().is_item_checked(index)
			%CameraRig.is_orthogonal = is_orthogonal
			camera_menu.get_popup().set_item_checked(index, is_orthogonal)
		"unshaded":
			var is_unshaded = not camera_menu.get_popup().is_item_checked(index)
			%Viewport.debug_draw = Viewport.DEBUG_DRAW_UNSHADED if is_unshaded else Viewport.DEBUG_DRAW_DISABLED
			camera_menu.get_popup().set_item_checked(index, is_unshaded)
		_:
			%CameraRig.set_view(text)


func _on_pan_toggle_toggled(toggled_on: bool) -> void:
	%CameraRig.view_mode = %CameraRig.ViewMode.PAN if toggled_on else %CameraRig.ViewMode.NONE


func _on_rotate_toggle_toggled(toggled_on: bool) -> void:
	%CameraRig.view_mode = %CameraRig.ViewMode.ROTATE if toggled_on else %CameraRig.ViewMode.NONE


func _on_grid_toggle_toggled(toggled_on: bool) -> void:
	%Grid.visible = toggled_on


func _on_center_btn_pressed() -> void:
	%CameraRig.center_active()
