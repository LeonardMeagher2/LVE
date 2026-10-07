extends Node3D

signal lighting_changed()

@export var document_lighting := true

enum ViewMode {
	NONE,
	PAN,
	ROTATE,
	LIGHT,
}

var view_mode:ViewMode = ViewMode.NONE
var _light_dragging := false
var _light_start_basis := Basis.IDENTITY
var _light_center := Vector3.ZERO
var _light_orbit_radius := 4.0
var _light_trackball_center := Vector2.ZERO
var _light_trackball_radius := 48.0
var _light_trackball_basis := Basis.IDENTITY
var _light_trackball_start := Vector3.BACK
var _light_trackball_rotation := Quaternion.IDENTITY
var _default_lighting := {}
var _loading_document_lighting := false
const LIGHT_HANDLE_RADIUS := 12.0

func _ready() -> void:
	%CameraMenu.get_popup().index_pressed.connect(_on_camera_index_pressed)
	%CameraRig.zoom_changed.connect(%ZoomSlider.set_value_no_signal)
	$WorldEnvironment.environment = $WorldEnvironment.environment.duplicate()
	var material: StandardMaterial3D = %LightHandle.material_override.duplicate()
	material.albedo_color = $Light.light_color
	material.no_depth_test = true
	%LightHandle.material_override = material
	%LightDirection.get_node("Shaft").material_override = material
	%LightDirection.get_node("Tip").material_override = material
	set_process(false)
	_default_lighting = get_lighting_settings()
	if document_lighting:
		lighting_changed.connect(_save_document_lighting)
		State.document_changed.connect(_restore_document_lighting)
		_restore_document_lighting()


func _save_document_lighting() -> void:
	if _loading_document_lighting:
		return
	var settings := get_lighting_settings()
	var light_color: Color = settings.color
	var ambient_color: Color = settings.ambient_color
	light_color.a = settings.energy
	ambient_color.a = settings.ambient_energy
	State.document.lighting_settings = {"basis": settings.basis, "color": light_color, "ambient_color": ambient_color}


func _restore_document_lighting() -> void:
	_light_dragging = false
	var saved := State.document.lighting_settings
	var settings := get_lighting_settings()
	settings.basis = saved.get("basis", _default_lighting.basis)
	settings.debug_draw = %Viewport.debug_draw
	var light_color: Color = saved.get("color", _default_lighting.color)
	var ambient_color: Color = saved.get("ambient_color", _default_lighting.ambient_color)
	settings.energy = light_color.a
	settings.ambient_energy = ambient_color.a
	light_color.a = 1.0
	ambient_color.a = 1.0
	settings.color = light_color
	settings.ambient_color = ambient_color
	_loading_document_lighting = true
	set_lighting_settings(settings)
	_loading_document_lighting = false

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
		"shadows":
			$Light.shadow_enabled = not popup.is_item_checked(index)
			popup.set_item_checked(index, $Light.shadow_enabled)
		_:
			%CameraRig.set_view(text)


func get_lighting_settings() -> Dictionary:
	var environment: Environment = $WorldEnvironment.environment
	return {"basis": $Light.basis, "color": $Light.light_color, "energy": $Light.light_energy, "ambient_color": environment.ambient_light_color, "ambient_energy": environment.ambient_light_energy, "shadows": $Light.shadow_enabled, "shaded": %Viewport.debug_draw != Viewport.DEBUG_DRAW_UNSHADED}


func set_lighting_settings(settings: Dictionary) -> void:
	VoxelImageRenderer.apply_lighting($Light, $WorldEnvironment.environment, settings)
	%Viewport.debug_draw = settings.get("debug_draw", Viewport.DEBUG_DRAW_DISABLED if settings.shaded else Viewport.DEBUG_DRAW_UNSHADED)
	var popup: PopupMenu = %CameraMenu.get_popup()
	for index in popup.item_count:
		var text := popup.get_item_text(index).to_lower()
		if text == "unshaded":
			popup.set_item_checked(index, %Viewport.debug_draw == Viewport.DEBUG_DRAW_UNSHADED)
		elif text == "wireframe":
			popup.set_item_checked(index, %Viewport.debug_draw == Viewport.DEBUG_DRAW_WIREFRAME)
		elif text == "shadows":
			popup.set_item_checked(index, settings.shadows)
	_update_light_handle()
	lighting_changed.emit()


func _on_light_toggle_toggled(pressed: bool) -> void:
	%LightHandle.visible = pressed
	%LightDirection.visible = pressed
	_light_dragging = false
	set_process(pressed)
	if pressed:
		view_mode = ViewMode.LIGHT
		_update_light_handle()
	elif view_mode == ViewMode.LIGHT:
		view_mode = ViewMode.NONE


func _process(_delta: float) -> void:
	_update_light_handle()


func _update_light_handle() -> void:
	var material: StandardMaterial3D = %LightHandle.material_override
	material.albedo_color = $Light.light_color
	if not %LightHandle.visible:
		return
	var camera: EditorCameraRig = %CameraRig
	var bounds: AABB = camera.bounds_provider.call() if camera.bounds_provider.is_valid() else State.document.bounds()
	_light_center = bounds.get_center()
	_light_orbit_radius = maxf(4.0, bounds.size.length() * 0.6)
	%LightHandle.position = _light_center + $Light.basis.z.normalized() * _light_orbit_radius
	%LightDirection.position = %LightHandle.position
	%LightDirection.basis = $Light.basis
	var depth: float = -camera.to_local(%LightHandle.global_position).z
	if depth <= camera.near:
		return
	var screen_position := camera.unproject_position(%LightHandle.global_position)
	var first := camera.project_position(screen_position, depth)
	var second := camera.project_position(screen_position + Vector2(LIGHT_HANDLE_RADIUS, 0), depth)
	%LightHandle.scale = Vector3.ONE * maxf(0.01, first.distance_to(second) * 2.0)
	%LightDirection.scale = %LightHandle.scale


func _begin_light_drag(screen_position: Vector2, camera: Camera3D) -> void:
	_light_dragging = true
	_light_start_basis = $Light.basis
	_light_trackball_basis = camera.basis.orthonormalized()
	_light_trackball_center = camera.unproject_position(to_global(_light_center))
	var edge := camera.unproject_position(to_global(_light_center + _light_trackball_basis.x * _light_orbit_radius))
	_light_trackball_radius = maxf(48.0, edge.distance_to(_light_trackball_center))
	_light_trackball_start = _light_trackball_vector(screen_position)
	_light_trackball_rotation = Quaternion(_light_start_basis.orthonormalized())


func _light_trackball_vector(screen_position: Vector2) -> Vector3:
	var point := (screen_position - _light_trackball_center) / _light_trackball_radius
	point.y = -point.y
	var distance_squared := point.length_squared()
	# Blend the sphere into a hyperbolic surface for smooth motion outside its edge.
	var depth := sqrt(1.0 - distance_squared) if distance_squared <= 0.5 else 0.5 / sqrt(distance_squared)
	return (_light_trackball_basis * Vector3(point.x, point.y, depth)).normalized()


func _handle_light_input(event: InputEvent) -> bool:
	if _light_dragging and event.is_action_pressed("ui_cancel"):
		$Light.basis = _light_start_basis
		_light_dragging = false
		_update_light_handle()
		lighting_changed.emit()
		return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed and _light_dragging:
			_light_dragging = false
			return true
		if %LightHandle.visible:
			if not event.pressed:
				return true
			_update_light_handle()
			if not State.edit_busy():
				_begin_light_drag(event.position, %CameraRig)
			return true
	if event is InputEventMouseMotion and _light_dragging:
		if (event.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			_light_dragging = false
			return false
		var current := _light_trackball_vector(event.position)
		var drag_rotation := Quaternion(_light_trackball_start, current).normalized()
		$Light.quaternion = (drag_rotation * _light_trackball_rotation).normalized()
		_update_light_handle()
		lighting_changed.emit()
		return true
	if %LightHandle.visible and event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		return true
	return false


func _on_pan_toggle_toggled(toggled_on: bool) -> void:
	if toggled_on:
		view_mode = ViewMode.PAN
	elif view_mode == ViewMode.PAN:
		view_mode = ViewMode.NONE


func _on_rotate_toggle_toggled(toggled_on: bool) -> void:
	if toggled_on:
		view_mode = ViewMode.ROTATE
	elif view_mode == ViewMode.ROTATE:
		view_mode = ViewMode.NONE


func _on_grid_toggle_toggled(toggled_on: bool) -> void:
	%Grid.visible = toggled_on


func _on_center_btn_pressed() -> void:
	%CameraRig.center_active()


func _on_zoom_one_pressed() -> void:
	%CameraRig.set_zoom_percent(100)


func _on_zoom_slider_value_changed(value: float) -> void:
	%CameraRig.set_zoom_percent(value)


func _input(event: InputEvent) -> void:
	if _handle_light_input(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		
		if view_mode in [ViewMode.PAN, ViewMode.ROTATE] and mb.button_index == MOUSE_BUTTON_LEFT:
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
		if mask & MOUSE_BUTTON_MASK_LEFT and view_mode in [ViewMode.PAN, ViewMode.ROTATE]:
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
