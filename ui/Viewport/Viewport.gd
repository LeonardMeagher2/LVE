extends Node3D

## The editor viewport scene.
##
## It owns the camera, the light, and the grid. It handles the view drags and
## the light drag. The lighting settings can follow the document.

## Emitted after the lighting settings change.
signal lighting_changed()

const SLICE_MATTE_SCRIPT := preload("res://ui/Viewport/SliceMatte.gd")

## Whether the lighting settings load from and save to the document.
@export var document_lighting := true

## The view drag mode.
enum ViewMode {
	## No view drag.
	NONE,
	## Pan the view.
	PAN,
	## Orbit the view.
	ROTATE,
	## Drag the light.
	LIGHT,
}

## The active view mode.
var view_mode:ViewMode = ViewMode.NONE
var _drag_mode:ViewMode = ViewMode.NONE
var _light_dragging := false
var _light_start_basis := Basis.IDENTITY
var _light_start_view_basis := Basis.IDENTITY
var _light_center := Vector3.ZERO
var _light_orbit_radius := 4.0
var _light_trackball_center := Vector2.ZERO
var _light_trackball_radius := 48.0
var _light_trackball_basis := Basis.IDENTITY
var _light_trackball_start := Vector3.BACK
var _light_trackball_rotation := Quaternion.IDENTITY
var _default_lighting := {}
var _loading_document_lighting := false
var _view_light_basis := Basis.IDENTITY
var _lighting_document: VoxelDocument
var _camera_shadow_projection := Camera3D.PROJECTION_PERSPECTIVE
const LIGHT_HANDLE_RADIUS := 12.0

func _ready() -> void:
	%CameraMenu.get_popup().index_pressed.connect(_on_camera_index_pressed)
	%CameraRig.zoom_changed.connect(%ZoomSlider.set_value_no_signal)
	%CameraRig.view_changed.connect(_on_camera_view_changed)
	$WorldEnvironment.environment = $WorldEnvironment.environment.duplicate()
	var material: StandardMaterial3D = %LightHandle.material_override.duplicate()
	material.albedo_color = $Light.light_color
	material.no_depth_test = true
	%LightHandle.material_override = material
	%LightDirection.get_node("Shaft").material_override = material
	%LightDirection.get_node("Tip").material_override = material
	set_process(false)
	_default_lighting = get_lighting_settings()
	_sync_lighting_controls(_default_lighting)
	_sync_shading_controls()
	_lighting_document = State.document
	if document_lighting:
		lighting_changed.connect(_save_document_lighting)
		State.document_changed.connect(_restore_document_lighting)
		_restore_document_lighting()
	State.slice_changed.connect(_on_slice_changed)
	State.floor_plane_changed.connect(_on_slice_changed)
	var slice_matte: MeshInstance3D = SLICE_MATTE_SCRIPT.new()
	slice_matte.name = "SliceMatte"
	add_child(slice_matte)
	_on_slice_changed()


# Shows only the slice slab while the slice is on. The renderer keeps its mesh
# cache; the slice is part of the surface key, so a layer move rebuilds only the
# slice rows.
func _on_slice_changed() -> void:
	var renderer: VoxelRenderer = $VoxelRenderer
	renderer.set_slice(
		State.floor_axis if State.slice_enabled else -1,
		State.slice_first(),
		State.slice_count() if State.slice_enabled else 1,
	)


func _save_document_lighting() -> void:
	if not document_lighting or _loading_document_lighting or State.document != _lighting_document:
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
	var light_color: Color = saved.get("color", _default_lighting.color)
	var ambient_color: Color = saved.get("ambient_color", _default_lighting.ambient_color)
	settings.energy = light_color.a
	settings.ambient_energy = ambient_color.a
	light_color.a = 1.0
	ambient_color.a = 1.0
	settings.color = light_color
	settings.ambient_color = ambient_color
	# The editor light lock is a session option.
	settings.view_locked = false
	settings.view_basis = Basis.IDENTITY
	_loading_document_lighting = true
	set_lighting_settings(settings)
	_loading_document_lighting = false
	_lighting_document = State.document

func _on_camera_view_changed() -> void:
	if %LockView.button_pressed:
		$Light.basis = %CameraRig.basis * _view_light_basis
		_update_light_handle()
		_save_document_lighting()
	if %CameraRig.projection == _camera_shadow_projection:
		return
	_camera_shadow_projection = %CameraRig.projection
	VoxelImageRenderer.apply_directional_shadow($Light, %CameraRig)


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
	elif popup.is_item_checkable(index):
		popup.set_item_checked(index, not popup.is_item_checked(index))
	
	match text:
		"orthographic":
			%CameraRig.is_orthogonal = popup.is_item_checked(index)
		"wireframe":
			%Viewport.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if popup.is_item_checked(index) else Viewport.DEBUG_DRAW_DISABLED
		_:
			%CameraRig.set_view(text)


## Returns the lighting settings of this viewport. The keys match the export
## lighting dictionary in `docs/DOCUMENT_FORMAT.md`.
func get_lighting_settings() -> Dictionary:
	var environment: Environment = $WorldEnvironment.environment
	return {"basis": $Light.basis, "color": $Light.light_color, "energy": $Light.light_energy, "ambient_color": environment.ambient_light_color, "ambient_energy": environment.ambient_light_energy, "shadows": $Light.shadow_enabled, "shaded": not $VoxelRenderer.unshaded, "view_locked": %LockView.button_pressed, "view_basis": _view_light_basis}


## Applies one lighting settings dictionary and emits [signal lighting_changed].
func set_lighting_settings(settings: Dictionary) -> void:
	VoxelImageRenderer.apply_lighting($Light, $WorldEnvironment.environment, settings)
	$VoxelRenderer.unshaded = not settings.get("shaded", true)
	%Viewport.debug_draw = settings.get("debug_draw", %Viewport.debug_draw)
	var popup: PopupMenu = %CameraMenu.get_popup()
	for index in popup.item_count:
		if popup.get_item_text(index).to_lower() == "wireframe":
			popup.set_item_checked(index, %Viewport.debug_draw == Viewport.DEBUG_DRAW_WIREFRAME)
	_sync_lighting_controls(settings)
	_sync_shading_controls()
	_update_light_handle()
	lighting_changed.emit()


func _sync_lighting_controls(settings: Dictionary) -> void:
	var light_color: Color = settings.color
	var ambient_color: Color = settings.ambient_color
	light_color.a = 1.0
	ambient_color.a = 1.0
	%LightColor.color = light_color
	%AmbientColor.color = ambient_color
	var locked: bool = settings.get("view_locked", false)
	%LockView.set_pressed_no_signal(locked)
	_view_light_basis = settings.get("view_basis", Basis.IDENTITY)
	if locked and not settings.has("view_basis"):
		_view_light_basis = %CameraRig.basis.inverse() * settings.basis


func _sync_shading_controls() -> void:
	%Shadows.set_pressed_no_signal($Light.shadow_enabled)
	var shaded: bool = not $VoxelRenderer.unshaded
	%Shaded.set_pressed_no_signal(shaded)
	if not shaded and %LightToggle.button_pressed:
		%LightToggle.set_pressed_no_signal(false)
		_set_light_widget(false)
	var controls: Array[BaseButton] = [%LightToggle, %LockView, %LightColor, %AmbientColor, %Shadows, %Reset]
	for control in controls:
		control.disabled = not shaded


func _on_environment_toggled(pressed: bool) -> void:
	%EnvironmentBar.visible = pressed
	if not pressed:
		%LightToggle.set_pressed_no_signal(false)
		_set_light_widget(false)


func _on_light_color_changed(color: Color) -> void:
	var settings := get_lighting_settings()
	settings.color = Color(color.r, color.g, color.b, 1.0)
	set_lighting_settings(settings)


func _on_ambient_color_changed(color: Color) -> void:
	var settings := get_lighting_settings()
	settings.ambient_color = Color(color.r, color.g, color.b, 1.0)
	set_lighting_settings(settings)


func _on_lock_view_toggled(pressed: bool) -> void:
	if pressed:
		_view_light_basis = %CameraRig.basis.inverse() * $Light.basis
	lighting_changed.emit()


func _on_shadows_toggled(pressed: bool) -> void:
	$Light.shadow_enabled = pressed
	_sync_shading_controls()
	lighting_changed.emit()


func _on_shaded_toggled(pressed: bool) -> void:
	$VoxelRenderer.unshaded = not pressed
	_sync_shading_controls()
	lighting_changed.emit()


func _on_reset_lighting_pressed() -> void:
	set_lighting_settings(_default_lighting)


func _set_light_widget(pressed: bool) -> void:
	%LightHandle.visible = pressed
	%LightDirection.visible = pressed
	_light_dragging = false
	set_process(pressed)
	if pressed:
		view_mode = ViewMode.LIGHT
		_update_light_handle()
	elif view_mode == ViewMode.LIGHT:
		view_mode = ViewMode.NONE


func _on_light_toggle_toggled(pressed: bool) -> void:
	_set_light_widget(pressed)


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
	_light_start_view_basis = _view_light_basis
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
		_view_light_basis = _light_start_view_basis
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
		if %LockView.button_pressed:
			_view_light_basis = %CameraRig.basis.inverse() * $Light.basis
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


func _show_view_mode(mode: ViewMode) -> void:
	%ControlBar.get_node("PanToggle").set_pressed_no_signal(mode == ViewMode.PAN)
	%ControlBar.get_node("RotateToggle").set_pressed_no_signal(mode == ViewMode.ROTATE)


func _restore_view_toggles() -> void:
	%ControlBar.get_node("PanToggle").set_pressed_no_signal(view_mode == ViewMode.PAN)
	%ControlBar.get_node("RotateToggle").set_pressed_no_signal(view_mode == ViewMode.ROTATE)


func _view_drag_mode(mb: InputEventMouseButton) -> ViewMode:
	if not mb.pressed:
		return ViewMode.NONE
	if mb.alt_pressed:
		return ViewMode.ROTATE
	if mb.shift_pressed:
		return ViewMode.PAN
	if view_mode == ViewMode.PAN or view_mode == ViewMode.ROTATE:
		return view_mode
	return ViewMode.NONE


func _unhandled_key_input(event: InputEvent) -> void:
	for binding in [
		[&"view_top", "top"],
		[&"view_bottom", "bottom"],
		[&"view_front", "front"],
		[&"view_back", "back"],
		[&"view_left", "left"],
		[&"view_right", "right"],
		[&"view_isometric", "isometric"],
	]:
		if event.is_action_pressed(binding[0], false, true):
			%CameraRig.set_view(binding[1])
			get_viewport().set_input_as_handled()
			return


func _input(event: InputEvent) -> void:
	if _handle_light_input(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		
		if mb.button_index == MOUSE_BUTTON_LEFT:
			var mode := _view_drag_mode(mb)
			if mode != ViewMode.NONE or _drag_mode != ViewMode.NONE:
				_drag_mode = mode
				if mode == ViewMode.NONE:
					_restore_view_toggles()
				else:
					_show_view_mode(mode)
				get_viewport().set_input_as_handled()
				return
		
		match mb.button_index:
			MOUSE_BUTTON_RIGHT:
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_MIDDLE:
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_UP:
				# An X11 wheel can arrive as a press and a release, so only the
				# press zooms. Both events are consumed.
				if mb.pressed:
					%ZoomSlider.value *= 1.0 / 0.85
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					%ZoomSlider.value *= 0.85
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var mask := mm.button_mask
		var active := _drag_mode
		if active == ViewMode.NONE and view_mode in [ViewMode.PAN, ViewMode.ROTATE]:
			active = view_mode
		if active != ViewMode.NONE and mask & MOUSE_BUTTON_MASK_LEFT:
			if active == ViewMode.PAN:
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
