extends Node3D

enum ViewMode {
	NONE,
	PAN,
	ROTATE,
}

var view_mode:ViewMode = ViewMode.NONE

func _ready() -> void:
	%CameraMenu.get_popup().index_pressed.connect(_on_camera_index_pressed)
	%CameraRig.zoom_changed.connect(%ZoomSlider.set_value_no_signal)

func _on_camera_index_pressed(index:int) -> void:
	var popup:PopupMenu = %CameraMenu.get_popup()
	var text = popup.get_item_text(index).to_lower()
	if popup.is_item_radio_checkable(index):
		popup.set_item_checked(index, not popup.is_item_checked(index))
		for direction in [-1, 1]:
			var adjacent_index: int = index + direction
			while adjacent_index >= 0 and adjacent_index < popup.item_count and popup.is_item_radio_checkable(adjacent_index):
				popup.set_item_checked(adjacent_index, false)
				adjacent_index += direction
	
	match text:
		"orthographic":
			var is_orthogonal = not popup.is_item_checked(index)
			%CameraRig.is_orthogonal = is_orthogonal
			popup.set_item_checked(index, is_orthogonal)
		"unshaded":
			var is_unshaded = popup.is_item_checked(index)
			%Viewport.debug_draw = Viewport.DEBUG_DRAW_UNSHADED if is_unshaded else Viewport.DEBUG_DRAW_DISABLED
		"wireframe":
			var is_wireframe = popup.is_item_checked(index)
			%Viewport.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if is_wireframe else Viewport.DEBUG_DRAW_DISABLED
		_:
			%CameraRig.set_view(text)


func _on_pan_toggle_toggled(toggled_on: bool) -> void:
	view_mode = ViewMode.PAN if toggled_on else ViewMode.NONE


func _on_rotate_toggle_toggled(toggled_on: bool) -> void:
	view_mode = ViewMode.ROTATE if toggled_on else ViewMode.NONE


func _on_grid_toggle_toggled(toggled_on: bool) -> void:
	%Grid.visible = toggled_on


func _on_center_btn_pressed() -> void:
	%CameraRig.center_active()


func _on_zoom_one_pressed() -> void:
	%CameraRig.set_zoom_percent(100)


func _on_zoom_slider_value_changed(value: float) -> void:
	%CameraRig.set_zoom_percent(value)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		
		if view_mode != ViewMode.NONE and mb.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			return
		
		match mb.button_index:
			MOUSE_BUTTON_RIGHT:
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_MIDDLE:
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_UP:
				%ZoomSlider.value *= 1.0 / 0.85
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_DOWN:
				%ZoomSlider.value *= 0.85
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var mask := mm.button_mask
		if mask & MOUSE_BUTTON_MASK_LEFT and view_mode != ViewMode.NONE:
			if view_mode == ViewMode.PAN:
				%CameraRig.pan(mm.relative)
			else:
				%CameraRig.orbit(mm.relative)
			get_viewport().set_input_as_handled()
		elif mask & MOUSE_BUTTON_MASK_MIDDLE or (mask & MOUSE_BUTTON_MASK_RIGHT and mm.shift_pressed):
			%CameraRig.pan(mm.relative)
			get_viewport().set_input_as_handled()
		elif mask & MOUSE_BUTTON_MASK_RIGHT:
			%CameraRig.orbit(mm.relative)
			get_viewport().set_input_as_handled()
