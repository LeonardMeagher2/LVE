extends VoxelPlugin

const GLTF_EXPORT := preload("./GLTFExport.gd")
const VIEWS := ["3D preview", "Isometric", "Front", "Back", "Left", "Right", "Top", "Bottom"]
const ANGLES := [Vector2.ZERO, Vector2(-45, 45), Vector2.ZERO, Vector2(180, 0), Vector2(90, 0), Vector2(-90, 0), Vector2(0, 90), Vector2(0, -90)]
const PREVIEW_DELAY_MS := 200
const SPRITE_GAP := 1

@onready var _menu_item := preload("./MenuBarItem.tscn").instantiate()
@onready var _workspace := preload("./Workspace.tscn").instantiate()
@onready var _model: VBoxContainer = _workspace.get_node("%Model")
@onready var _controls: VBoxContainer = _workspace.get_node("%Sheet")
@onready var _sheet_settings: GridContainer = _controls.get_node("Settings")
@onready var _dialog: FileDialog = _menu_item.get_node("ExportDialog")
@onready var _sheet_dialog: FileDialog = _menu_item.get_node("SpriteSheetDialog")

var _gltf: RefCounted
var _exporting := false
var _cancel_requested := false
var _operation_id := 0
var _export_viewport: SubViewport
var _preview_viewport: SubViewport
var _preview_revision := 0
var _preview_due_ms := -1
var _preview_running := false
var _preview_image: Image
var _preview_operation_id := 0
var _model_dirty := true
var _model_camera_needs_center := true
var _model_viewport: SubViewport
var _model_renderer: VoxelRenderer
var _model_back_renderer: VoxelRenderer
var _model_pending_frame := -1
var _model_playback := AnimationPlayback.new()
var _model_camera: EditorCameraRig
var _model_scene
var _default_lighting := {}
var _default_camera := {}
var _settings_document: VoxelDocument
var _restoring_export_settings := false
var _pending_export_camera := {}
var _syncing_lighting := false
var _view_light_basis := Basis.IDENTITY
var _updating_view_light := false
var _selected_tag: AnimationTag
var _sheet_tag: AnimationTag
var _model_frames: Array[VoxelFrame] = []
var _model_step := 0
var _result_message := ""


func _ready() -> void:
	name = "ExportPlugin"
	_gltf = GLTF_EXPORT.new(self)
	_model_viewport = _model.get_node("Viewport/PanelContainer/SubViewportContainer/Viewport")
	_model_viewport.own_world_3d = true
	_model_viewport.get_node("ViewportScene").document_lighting = false
	_model_renderer = _model_viewport.get_node("ViewportScene/VoxelRenderer")
	_model_renderer.report_activity = false
	_model_renderer.source_frame = State.get_current_voxel_frame().copy_frame()
	_model_back_renderer = preload("res://ui/Viewport/VoxelRenderer.tscn").instantiate()
	_model_back_renderer.report_activity = false
	_model_back_renderer.source_frame = VoxelFrame.new()
	_model_back_renderer.visible = false
	_model_viewport.get_node("ViewportScene").add_child(_model_back_renderer)
	_model_playback.frame_changed.connect(_show_model_frame)
	_model_playback.is_playing_toggled.connect(_on_model_playing_changed)
	_model_camera = _model_viewport.get_node("ViewportScene/CameraRig")
	_model_camera.bounds_provider = _model_bounds
	var view_group: ButtonGroup = _model.get_node("Viewport/ControlBar/PanToggle").button_group.duplicate()
	for button in ["PanToggle", "RotateToggle", "LightToggle"]:
		_model.get_node("Viewport/ControlBar/" + button).button_group = view_group
	for view in VIEWS:
		_sheet_settings.get_node("ViewRow/View").add_item(view)
	_sheet_settings.get_node("ViewRow/View").select(1)
	add_menu_bar_item(_menu_item)
	add_tab(_workspace)
	_model_scene = _model_viewport.get_node("ViewportScene")
	_default_lighting = _model_scene.get_lighting_settings()
	_default_camera = _capture_export_camera()
	_model_scene.lighting_changed.connect(_on_model_lighting_changed)
	var lighting: HBoxContainer = _controls.get_node("LightingOptions")
	for path in ["LightColor", "AmbientColor"]:
		lighting.get_node(path).color_changed.connect(_on_sheet_lighting_changed.unbind(1))
	for path in ["Enabled", "Shadows"]:
		lighting.get_node(path).toggled.connect(_on_sheet_lighting_changed.unbind(1))
	lighting.get_node("LockView").toggled.connect(_on_light_view_lock_toggled)
	lighting.get_node("Reset").pressed.connect(_reset_lighting)
	_menu_item.get_node("ExportBtn").toggled.connect(_on_export_toggled)
	_workspace.visibility_changed.connect(_on_workspace_visibility_changed)
	_model.get_node("Export").pressed.connect(_choose_gltf_file)
	_dialog.file_selected.connect(_on_gltf_file_selected)
	_sheet_dialog.file_selected.connect(_on_sheet_file_selected)
	_controls.get_node("Export").pressed.connect(_choose_sheet_file)
	var sheet_preview: Control = _controls.get_node("Preview")
	var sheet_bar: HBoxContainer = _controls.get_node("ControlBar")
	sheet_bar.get_node("PanToggle").toggled.connect(sheet_preview.set_pan_mode)
	sheet_bar.get_node("PanToggle").button_pressed = true
	sheet_bar.get_node("ZoomSlider").value_changed.connect(sheet_preview.set_zoom_percent)
	sheet_preview.zoom_changed.connect(sheet_bar.get_node("ZoomSlider").set_value_no_signal)
	sheet_bar.get_node("ZoomOne").pressed.connect(sheet_preview.set_zoom_percent.bind(100.0))
	sheet_bar.get_node("CenterBtn").pressed.connect(sheet_preview.fit)
	_sheet_settings.get_node("FrameRow/Frames").item_selected.connect(_on_sheet_tag_selected)
	_sheet_settings.get_node("ViewRow/View").item_selected.connect(_sheet_settings_changed.unbind(1))
	_sheet_settings.get_node("ViewRow/Perspective").toggled.connect(_reset_sprite_size.unbind(1))
	_sheet_settings.get_node("ViewRow/Center").toggled.connect(_sheet_settings_changed.unbind(1))
	_sheet_settings.get_node("TurntableRow/Views").value_changed.connect(_sheet_settings_changed.unbind(1))
	_sheet_settings.get_node("SizeRow/Size").value_changed.connect(_sheet_settings_changed.unbind(1))
	_sheet_settings.get_node("SizeRow/Reset").pressed.connect(_reset_sprite_size)
	_sheet_settings.get_node("TurntableRow/Turntable").toggled.connect(_sheet_settings_changed.unbind(1))
	_sheet_settings.get_node("TurntableRow/Metadata").toggled.connect(_save_export_settings.unbind(1))
	_model.get_node("AnimationRow/Center").toggled.connect(_model_settings_changed.unbind(1))
	_model.get_node("AnimationRow/Tags").item_selected.connect(_on_model_tag_selected)
	_model.get_node("AnimationRow/Play").toggled.connect(_on_play_toggled)
	_model_camera.view_changed.connect(_on_preview_camera_changed)
	State.document_changed.connect(_on_document_changed)
	State.frames_changed.connect(_source_changed)
	State.frame_changed.connect(_source_changed)
	State.tag_changed.connect(_source_changed)
	State.cells_changed.connect(_source_changed.unbind(2))
	State.chunks_changed.connect(_source_changed.unbind(2))
	State.model_settings_changed.connect(_source_changed)
	State.activity_changed.connect(_sync)
	_model.get_node("Viewport/ControlBar/GridToggle").button_pressed = false
	_model.get_node("Viewport/ControlBar/RotateToggle").button_pressed = true
	_restore_export_settings()
	_sync()


func _capture_export_camera() -> Dictionary:
	return {"yaw": _model_camera._yaw, "pitch": _model_camera._pitch, "distance": _model_camera._dist, "initial_distance": _model_camera._init_dist, "target": _model_camera._target, "orthographic": _model_camera.is_orthogonal, "fov": _model_camera.fov}


func _save_export_settings() -> void:
	if _restoring_export_settings or State.document != _settings_document:
		return
	State.document.export_settings = {
		"view": _sheet_settings.get_node("ViewRow/View").selected,
		"sprite_ortho": not _sheet_settings.get_node("ViewRow/Perspective").button_pressed,
		"sprite_center": _sheet_settings.get_node("ViewRow/Center").button_pressed,
		"frame_size": _sheet_settings.get_node("SizeRow/Size").value,
		"turntable": _sheet_settings.get_node("TurntableRow/Turntable").button_pressed,
		"views": _sheet_settings.get_node("TurntableRow/Views").value,
		"metadata": _sheet_settings.get_node("TurntableRow/Metadata").button_pressed,
		"center": _model.get_node("AnimationRow/Center").button_pressed,
		"model_tag": State.document.tags.find(_selected_tag),
		"sheet_tag": State.document.tags.find(_sheet_tag),
		"lighting": _sheet_lighting(),
		"camera": _pending_export_camera.duplicate() if not _pending_export_camera.is_empty() else _capture_export_camera(),
	}


func _restore_export_settings() -> void:
	_restoring_export_settings = true
	_model_camera_needs_center = true
	_settings_document = State.document
	var saved := State.document.export_settings
	_selected_tag = State.document.get_tag(int(saved.get("model_tag", -1)))
	_sheet_tag = State.document.get_tag(int(saved.get("sheet_tag", -1)))
	_sync_tags()
	_sheet_settings.get_node("ViewRow/View").select(clampi(int(saved.get("view", 1)), 0, VIEWS.size() - 1))
	_sheet_settings.get_node("ViewRow/Perspective").set_pressed_no_signal(not saved.get("sprite_ortho", true))
	_sheet_settings.get_node("ViewRow/Center").set_pressed_no_signal(saved.get("sprite_center", true))
	_sheet_settings.get_node("SizeRow/Size").set_value_no_signal(saved.get("frame_size", 64))
	_sheet_settings.get_node("TurntableRow/Turntable").set_pressed_no_signal(saved.get("turntable", true))
	_sheet_settings.get_node("TurntableRow/Views").set_value_no_signal(saved.get("views", 8))
	_sheet_settings.get_node("TurntableRow/Metadata").set_pressed_no_signal(saved.get("metadata", true))
	_model.get_node("AnimationRow/Center").set_pressed_no_signal(saved.get("center", true))
	var lighting: Dictionary = saved.get("lighting", _default_lighting)
	var controls: HBoxContainer = _controls.get_node("LightingOptions")
	controls.get_node("Shadows").set_pressed_no_signal(lighting.shadows)
	controls.get_node("Enabled").set_pressed_no_signal(lighting.shaded)
	controls.get_node("LockView").set_pressed_no_signal(lighting.get("view_locked", false))
	_view_light_basis = lighting.get("view_basis", _model_camera.basis.inverse() * lighting.basis)
	_model_scene.set_lighting_settings(lighting)
	_pending_export_camera = saved.get("camera", {}).duplicate()
	_model_camera._yaw = _pending_export_camera.get("yaw", _default_camera.yaw)
	_model_camera._pitch = _pending_export_camera.get("pitch", _default_camera.pitch)
	_model_camera.fov = _pending_export_camera.get("fov", _default_camera.fov)
	_model_camera.is_orthogonal = _pending_export_camera.get("orthographic", _default_camera.orthographic)
	_restoring_export_settings = false


func _enter_tree() -> void:
	if is_instance_valid(_workspace):
		add_menu_bar_item(_menu_item)
		add_tab(_workspace)


func _exit_tree() -> void:
	_cancel_requested = true
	_preview_revision += 1
	if _gltf:
		_gltf.cancel()
	_finish_export()
	if is_instance_valid(_preview_viewport):
		_preview_viewport.free()
	_preview_viewport = null
	State.finish_operation(_preview_operation_id)
	_preview_operation_id = 0
	if is_instance_valid(_workspace) and _workspace.get_parent():
		remove_tab(_workspace)
	if is_instance_valid(_menu_item) and _menu_item.get_parent():
		_menu_item.get_parent().remove_child(_menu_item)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if is_instance_valid(_workspace):
			_workspace.free()
		if is_instance_valid(_menu_item):
			_menu_item.free()


func _on_export_toggled(pressed: bool) -> void:
	if State.edit_busy():
		_menu_item.get_node("ExportBtn").set_pressed_no_signal(_workspace.is_visible_in_tree())
		return
	if pressed:
		show_tab(_workspace)
	else:
		show_editor_tab()


func _on_workspace_visibility_changed() -> void:
	_preview_revision += 1
	_menu_item.get_node("ExportBtn").set_pressed_no_signal(_workspace.is_visible_in_tree())
	if _workspace.is_visible_in_tree():
		_set_status_context(_export_status, _cancel_export)
		_model_dirty = true
		_preview_due_ms = Time.get_ticks_msec() + PREVIEW_DELAY_MS
	else:
		_set_status_context(Callable())
		_preview_due_ms = -1
		_model_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _source_changed() -> void:
	_sync_tags()
	_model_dirty = true
	_sheet_settings_changed()


func _on_document_changed() -> void:
	_model_frames.clear()
	_model_playback.is_playing = false
	_model_playback.document = VoxelDocument.new()
	_model_renderer.source_frame = VoxelFrame.new()
	_model_back_renderer.source_frame = VoxelFrame.new()
	_model_pending_frame = -1
	_restore_export_settings()
	_source_changed()


func _reset_sprite_size() -> void:
	var span := _sprite_span(State.document.bounds(), _sheet_camera(_sheet_settings.get_node("ViewRow/View").selected, _view_count()))
	_sheet_settings.get_node("SizeRow/Size").set_value_no_signal(span)
	_sheet_settings_changed()


func _view_count() -> int:
	return int(_sheet_settings.get_node("TurntableRow/Views").value) if _sheet_settings.get_node("TurntableRow/Turntable").button_pressed else 1


static func _sprite_span(bounds: AABB, settings: Dictionary) -> int:
	var span: float = settings.size
	if settings.projection == Camera3D.PROJECTION_PERSPECTIVE:
		var transform: Transform3D = settings.transforms[0]
		var distance := (transform.origin - bounds.get_center()).dot(transform.basis.z)
		span = 2.0 * distance * tan(deg_to_rad(settings.fov) * 0.5)
	return maxi(1, ceili(span - 0.00001))


func _sync_tags() -> void:
	var selector: OptionButton = _model.get_node("AnimationRow/Tags")
	var index := State.document.tags.find(_selected_tag) if _selected_tag else -1
	_selected_tag = State.document.get_tag(index)
	var sheet_selector: OptionButton = _sheet_settings.get_node("FrameRow/Frames")
	var sheet_index := State.document.tags.find(_sheet_tag) if _sheet_tag else -1
	_sheet_tag = State.document.get_tag(sheet_index)
	for control in [selector, sheet_selector]:
		control.clear()
		control.add_item("All tags")
		for tag in State.document.tags:
			control.add_item(tag.name)
	selector.select(index + 1)
	sheet_selector.select(sheet_index + 1)


func _on_sheet_tag_selected(index: int) -> void:
	_sheet_tag = State.document.get_tag(index - 1)
	_sheet_settings_changed()


func _on_model_tag_selected(index: int) -> void:
	_selected_tag = State.document.get_tag(index - 1)
	_model_settings_changed()


func _model_settings_changed() -> void:
	_model_dirty = true
	_model_camera_needs_center = true
	_result_message = ""
	_save_export_settings()
	_sync()


func _model_range() -> Vector2i:
	return Vector2i(_selected_tag.from, _selected_tag.to) if _selected_tag and State.document.tags.has(_selected_tag) else Vector2i(0, State.get_frame_count() - 1)


func _sheet_settings_changed() -> void:
	if _restoring_export_settings:
		return
	_result_message = ""
	_preview_revision += 1
	_preview_due_ms = Time.get_ticks_msec() + PREVIEW_DELAY_MS
	_preview_image = null
	_controls.get_node("Preview").texture = null
	_save_export_settings()
	_sync()


func _sheet_lighting() -> Dictionary:
	var settings: Dictionary = _model_scene.get_lighting_settings()
	var controls: HBoxContainer = _controls.get_node("LightingOptions")
	var light_color: Color = controls.get_node("LightColor").color
	var ambient_color: Color = controls.get_node("AmbientColor").color
	settings.energy = light_color.a
	settings.ambient_energy = ambient_color.a
	light_color.a = 1.0
	ambient_color.a = 1.0
	settings.color = light_color
	settings.ambient_color = ambient_color
	settings.shadows = controls.get_node("Shadows").button_pressed
	settings.shaded = controls.get_node("Enabled").button_pressed
	settings.view_locked = controls.get_node("LockView").button_pressed
	settings.view_basis = _view_light_basis
	return settings


func _on_light_view_lock_toggled(locked: bool) -> void:
	if locked:
		var settings: Dictionary = _model_scene.get_lighting_settings()
		_view_light_basis = _model_camera.basis.inverse() * settings.basis
	_sheet_settings_changed()


func _on_sheet_lighting_changed() -> void:
	if _syncing_lighting:
		return
	_model_scene.set_lighting_settings(_sheet_lighting())


func _on_model_lighting_changed() -> void:
	if _updating_view_light:
		return
	var settings: Dictionary = _model_scene.get_lighting_settings()
	var controls: HBoxContainer = _controls.get_node("LightingOptions")
	if controls.get_node("LockView").button_pressed and not _restoring_export_settings:
		_view_light_basis = _model_camera.basis.inverse() * settings.basis
	_syncing_lighting = true
	var light_color: Color = settings.color
	var ambient_color: Color = settings.ambient_color
	light_color.a = clampf(settings.energy, 0.0, 1.0)
	ambient_color.a = clampf(settings.ambient_energy, 0.0, 1.0)
	controls.get_node("LightColor").color = light_color
	controls.get_node("AmbientColor").color = ambient_color
	_syncing_lighting = false
	_sheet_settings_changed()


func _reset_lighting() -> void:
	var controls: HBoxContainer = _controls.get_node("LightingOptions")
	controls.get_node("Shadows").set_pressed_no_signal(_default_lighting.shadows)
	controls.get_node("Enabled").set_pressed_no_signal(_default_lighting.shaded)
	controls.get_node("LockView").set_pressed_no_signal(false)
	_model_scene.set_lighting_settings(_default_lighting)


func _update_view_locked_light() -> void:
	if _controls.get_node("LightingOptions/LockView").button_pressed:
		var settings: Dictionary = _model_scene.get_lighting_settings()
		settings.basis = _model_camera.basis * _view_light_basis
		settings.debug_draw = _model_viewport.debug_draw
		_updating_view_light = true
		_model_scene.set_lighting_settings(settings)
		_updating_view_light = false


func _on_preview_camera_changed() -> void:
	if _restoring_export_settings or State.document != _settings_document:
		return
	_update_view_locked_light()
	_save_export_settings()
	_refresh_export_status()
	if _sheet_settings.get_node("ViewRow/View").selected == 0:
		_sheet_settings_changed()


func _selected_frames() -> Vector2i:
	if _sheet_tag and State.document.tags.has(_sheet_tag):
		return Vector2i(_sheet_tag.from, _sheet_tag.to)
	return Vector2i(0, State.get_frame_count() - 1)


func _model_transform() -> Transform3D:
	var center := State.document.bounds().get_center() if _model.get_node("AnimationRow/Center").button_pressed else Vector3.ZERO
	return Transform3D(Basis.IDENTITY, -center)


func _model_bounds() -> AABB:
	return _model_transform() * State.document.bounds()


func _refresh_model() -> void:
	_model_dirty = false
	var frame_range := _model_range()
	_model_frames.clear()
	for index in range(frame_range.x, frame_range.y + 1):
		_model_frames.append(State.get_voxel_frame(index).copy_frame())
	_model_renderer.transform = _model_transform()
	_model_back_renderer.transform = _model_renderer.transform
	var playing: bool = _model.get_node("AnimationRow/Play").button_pressed
	_model_playback.is_playing = false
	var preview_document := VoxelDocument.new()
	preview_document.frames.assign(_model_frames)
	preview_document.tags.clear()
	if _selected_tag:
		var tag: AnimationTag = _selected_tag.duplicate()
		tag.from -= frame_range.x
		tag.to -= frame_range.x
		preview_document.tags.append(tag)
	_model_playback.document = preview_document
	_model_playback.active_tag = 0 if _selected_tag else -1
	_model_playback.current_frame = clampi(State.current_frame - frame_range.x, 0, _model_frames.size() - 1)
	if playing:
		_model_playback.is_playing = true
	_show_model_frame()
	_restoring_export_settings = true
	if _model_camera_needs_center or not _pending_export_camera.is_empty():
		_model_camera.center_active()
	if not _pending_export_camera.is_empty():
		_model_camera._dist = maxf(0.01, float(_pending_export_camera.get("distance", _model_camera._dist)))
		_model_camera._init_dist = maxf(0.01, float(_pending_export_camera.get("initial_distance", _model_camera._init_dist)))
		_model_camera._target = _pending_export_camera.get("target", _model_camera._target)
		_model_camera._update()
		_model_camera.zoom_changed.emit(_model_camera.zoom_percent())
		_pending_export_camera = {}
	_model_camera_needs_center = false
	_restoring_export_settings = false
	_on_preview_camera_changed()
	_model_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS


func _show_model_frame() -> void:
	if _model_frames.is_empty() or _model_dirty:
		return
	_model_step = _model_playback.current_frame
	_model_pending_frame = _model_step
	_model_back_renderer.source_frame = _model_frames[_model_step]
	_refresh_export_status()


func _present_model_frame() -> void:
	if _model_pending_frame < 0 or not _model_back_renderer.is_settled():
		return
	_model_renderer.visible = false
	_model_back_renderer.visible = true
	var previous := _model_renderer
	_model_renderer = _model_back_renderer
	_model_back_renderer = previous
	_model_pending_frame = -1


func _on_play_toggled(pressed: bool) -> void:
	_model_playback.is_playing = pressed


func _on_model_playing_changed(playing: bool) -> void:
	_model.get_node("AnimationRow/Play").set_pressed_no_signal(playing)
	_model.get_node("AnimationRow/Play").icon = preload("res://icons/pause.svg") if playing else preload("res://icons/play.svg")


func _sync() -> void:
	var busy := State.edit_busy()
	var frame_range := _selected_frames()
	var count := frame_range.y - frame_range.x + 1
	var views := _view_count()
	var tile_size := int(_sheet_settings.get_node("SizeRow/Size").value)
	_sheet_settings.get_node("SizeRow/Size").tooltip_text = "Frame size: %d × %d px. Use Reset for the camera framing." % [tile_size, tile_size]
	var layout := sheet_layout(count * views, tile_size)
	_menu_item.get_node("ExportBtn").disabled = busy
	_model.get_node("Export").disabled = busy
	_controls.get_node("Export").disabled = busy or layout.size.x > Image.MAX_WIDTH or layout.size.y > Image.MAX_HEIGHT
	for path in ["FrameRow/Frames", "ViewRow/View", "ViewRow/Perspective", "ViewRow/Center"]:
		_sheet_settings.get_node(path).disabled = busy
	_sheet_settings.get_node("SizeRow/Size").editable = not busy
	_sheet_settings.get_node("TurntableRow/Metadata").disabled = busy
	_sheet_settings.get_node("SizeRow/Reset").disabled = busy
	_sheet_settings.get_node("TurntableRow/Turntable").disabled = busy
	_sheet_settings.get_node("TurntableRow/Views").editable = not busy and views > 1
	_model.get_node("AnimationRow/Center").disabled = busy
	_model.get_node("AnimationRow/Tags").disabled = busy
	_model.get_node("AnimationRow/Play").disabled = busy or _model_range().x == _model_range().y
	var lighting: HBoxContainer = _controls.get_node("LightingOptions")
	var lit: bool = lighting.get_node("Enabled").button_pressed
	for path in ["LightColor", "AmbientColor", "Shadows", "LockView", "Reset"]:
		lighting.get_node(path).disabled = busy or not lit
	lighting.get_node("Enabled").disabled = busy
	_refresh_export_status()


func _export_status() -> Dictionary:
	var frame_range := _selected_frames()
	var count := frame_range.y - frame_range.x + 1
	var layout := sheet_layout(count * _view_count(), int(_sheet_settings.get_node("SizeRow/Size").value))
	return {"left": _result_message if not _result_message.is_empty() else "%d × %d pixels · %d frames × %d views" % [layout.size.x, layout.size.y, count, _view_count()], "right": "Frame %d/%d   %d%%" % [_model_step + 1, maxi(1, _model_frames.size()), roundi(_model_camera.zoom_percent())]}


func _refresh_export_status() -> void:
	if _workspace.is_visible_in_tree():
		_set_status_context(_export_status, _cancel_export)


func _set_status_context(provider: Callable, cancel := Callable()) -> void:
	var main := get_node_or_null("/root/Main")
	if main:
		var status_bar: EditorStatusBar = main.get_node_or_null("%StatusBar")
		if status_bar:
			status_bar.set_context(provider, cancel)


func _process(delta: float) -> void:
	if not is_instance_valid(_workspace) or not _workspace.is_visible_in_tree():
		return
	if State.edit_busy():
		return
	if _model_dirty:
		_refresh_model()
	_present_model_frame()
	if _model_pending_frame < 0:
		_model_playback.update(delta)
	if not _preview_running and _preview_due_ms >= 0 and Time.get_ticks_msec() >= _preview_due_ms:
		_update_sheet_preview()


func _choose_gltf_file() -> void:
	_dialog.current_file = State.document.get_file_name().get_basename() + ".glb"
	_dialog.popup_centered()


func _choose_sheet_file() -> void:
	_sheet_dialog.current_file = State.document.get_file_name().get_basename() + "_sheet.png"
	_sheet_dialog.popup_centered()


func _on_gltf_file_selected(path: String) -> void:
	_report_result(await export_gltf(path), path)


func export_gltf(path: String) -> Error:
	var error: Error = await _gltf.export_gltf(path, _model.get_node("AnimationRow/Center").button_pressed, State.document.tags.find(_selected_tag) if _selected_tag else -1)
	_sync()
	_preview_due_ms = Time.get_ticks_msec() + PREVIEW_DELAY_MS
	return error


func _on_sheet_file_selected(path: String) -> void:
	var frame_range := _selected_frames()
	var resolution := int(_sheet_settings.get_node("SizeRow/Size").value)
	var tag_name: String = _sheet_tag.name if _sheet_tag else ""
	_report_result(await export_sprite_sheet(path, frame_range.x, frame_range.y, resolution, _sheet_settings.get_node("ViewRow/View").selected, _sheet_settings.get_node("TurntableRow/Metadata").button_pressed, _view_count(), tag_name), path)


func _report_result(error: Error, path: String) -> void:
	_result_message = "Saved %s" % path.get_file() if error == OK else ("Export cancelled" if error == ERR_BUSY or error == ERR_UNAVAILABLE else "Export failed: %s" % error_string(error))
	_refresh_export_status()


static func sheet_layout(frame_count: int, tile_size: int) -> Dictionary:
	var dimensions := Vector2i.ONE * tile_size
	var actual_columns := maxi(1, ceili(sqrt(float(frame_count))))
	var rows := ceili(frame_count / float(actual_columns))
	var size := Vector2i(actual_columns * dimensions.x + (actual_columns - 1) * SPRITE_GAP, rows * dimensions.y + (rows - 1) * SPRITE_GAP)
	var stride := dimensions + Vector2i.ONE * SPRITE_GAP
	var rects: Array[Rect2i] = []
	for index in frame_count:
		var position := Vector2i(index % actual_columns, floori(index / float(actual_columns))) * stride
		rects.append(Rect2i(position, dimensions))
	return {"size": size, "tile_size": dimensions, "rects": rects}


func _sheet_camera(view: int, views := 1) -> Dictionary:
	var orthographic: bool = not _sheet_settings.get_node("ViewRow/Perspective").button_pressed
	var bounds := State.document.bounds()
	var transform: Transform3D
	var size: float = _model_camera.size
	var near_plane: float = _model_camera.near
	if view == 0:
		var inverse := _model_transform().affine_inverse()
		transform = _model_camera.transform
		transform.origin = inverse * transform.origin
		if orthographic and _model_camera.projection != Camera3D.PROJECTION_ORTHOGONAL:
			var distance := (transform.origin - bounds.get_center()).dot(transform.basis.z)
			size = maxf(0.001, 2.0 * distance * tan(deg_to_rad(_model_camera.fov) * 0.5))
	else:
		var camera := Camera3D.new()
		add_child(camera)
		var angles: Vector2 = ANGLES[view]
		VoxelImageRenderer.frame_camera(camera, bounds, angles.x, angles.y, orthographic)
		transform = camera.transform
		near_plane = camera.near
		camera.free()
	var transforms: Array[Transform3D] = []
	for view_index in views:
		var turn := Basis(Vector3.UP, TAU * view_index / views)
		transforms.append(Transform3D(turn * transform.basis, bounds.get_center() + turn * (transform.origin - bounds.get_center())))
	if view > 0 and orthographic:
		size = 1.0
		for pose in transforms:
			size = maxf(size, pose.basis.x.abs().dot(bounds.size))
			size = maxf(size, pose.basis.y.abs().dot(bounds.size))
		size = ceili(size - 0.00001)
	return {"transforms": transforms, "projection": Camera3D.PROJECTION_ORTHOGONAL if orthographic else Camera3D.PROJECTION_PERSPECTIVE, "size": size, "fov": _model_camera.fov, "near": near_plane}


func _sheet_render_settings(view: int, views: int) -> Dictionary:
	var settings := _sheet_camera(view, views)
	var bounds := State.document.bounds()
	var model_transform := Transform3D(Basis.IDENTITY, -bounds.get_center() if _sheet_settings.get_node("ViewRow/Center").button_pressed else Vector3.ZERO)
	for index in settings.transforms.size():
		settings.transforms[index] = model_transform * settings.transforms[index]
	settings.model_transform = model_transform
	settings.lighting = _sheet_lighting()
	var render_bounds := model_transform * bounds
	var near_depth := INF
	var far_depth := -INF
	for pose: Transform3D in settings.transforms:
		var forward := -pose.basis.z
		near_depth = minf(near_depth, (render_bounds.get_support(-forward) - pose.origin).dot(forward))
		far_depth = maxf(far_depth, (render_bounds.get_support(forward) - pose.origin).dot(forward))
	# Use the same clipping planes for every frame and turntable view.
	settings.near = maxf(0.05, minf(settings.near, near_depth - 1.0))
	settings.far = maxf(settings.near + 1.0, far_depth + 1.0) * 2.0
	return settings


func _render_current(document: VoxelDocument, revision: int) -> bool:
	if not is_inside_tree() or State.document != document:
		return false
	if revision >= 0:
		return revision == _preview_revision and _workspace.is_visible_in_tree() and not State.edit_busy()
	return not _cancel_requested and State.has_operation(_operation_id)


func _render_sheet(frames: Array[VoxelFrame], settings: Dictionary, document: VoxelDocument, revision := -1) -> Image:
	var lighting_settings: Dictionary = settings.lighting
	var transforms: Array[Transform3D] = settings.transforms
	var layout: Dictionary = settings.layout
	var viewport: SubViewport = VoxelImageRenderer.VIEWPORT_SCENE.instantiate()
	viewport.size = layout.tile_size * 2
	if revision >= 0:
		_preview_viewport = viewport
	else:
		_export_viewport = viewport
	add_child(viewport)
	var environment_node: WorldEnvironment = viewport.get_node("Node3D/WorldEnvironment")
	environment_node.environment = environment_node.environment.duplicate()
	var light: DirectionalLight3D = viewport.get_node("Node3D/Light")
	VoxelImageRenderer.apply_lighting(light, environment_node.environment, lighting_settings)
	viewport.debug_draw = Viewport.DEBUG_DRAW_DISABLED if lighting_settings.shaded else Viewport.DEBUG_DRAW_UNSHADED
	var renderer: VoxelRenderer = viewport.get_node("%VoxelRenderer")
	renderer.transform = settings.model_transform
	var camera: Camera3D = viewport.get_node("Node3D/Camera3D")
	camera.transform = transforms[0]
	camera.projection = settings.projection
	camera.size = settings.size
	camera.fov = settings.fov
	camera.near = settings.near
	camera.far = settings.far
	VoxelImageRenderer.apply_directional_shadow(light, camera)
	var count: int = layout.rects.size()
	var sheet := Image.create(layout.size.x, layout.size.y, false, Image.FORMAT_RGBA8)
	sheet.fill(Color.TRANSPARENT)
	var index := 0
	for pose in transforms:
		if not _render_current(document, revision):
			break
		camera.transform = pose
		if lighting_settings.view_locked:
			light.basis = camera.basis * lighting_settings.view_basis
		for frame in frames:
			State.update_operation(_preview_operation_id if revision >= 0 else _operation_id, index, count, "Rendering sheet preview" if revision >= 0 else "Rendering sprite %d" % (index + 1))
			renderer.source_frame = frame
			while _render_current(document, revision) and not renderer.is_settled():
				await get_tree().process_frame
			if not _render_current(document, revision):
				break
			# Render the changed geometry and camera before capturing the shadowed image.
			viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			await RenderingServer.frame_post_draw
			if not _render_current(document, revision):
				break
			viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			await RenderingServer.frame_post_draw
			if not _render_current(document, revision):
				break
			var image := viewport.get_texture().get_image()
			image.convert(Image.FORMAT_RGBA8)
			var rect: Rect2i = layout.rects[index]
			image.resize(rect.size.x, rect.size.y, Image.INTERPOLATE_NEAREST)
			sheet.blit_rect(image, Rect2i(Vector2i.ZERO, rect.size), rect.position)
			index += 1
	if is_instance_valid(viewport):
		viewport.free()
	if revision >= 0:
		_preview_viewport = null
	else:
		_export_viewport = null
	return sheet if index == count else null


func _update_sheet_preview() -> void:
	_preview_due_ms = -1
	if DisplayServer.get_name() == "headless" or _controls.get_node("Export").disabled:
		return
	_preview_running = true
	var revision := _preview_revision
	var frame_range := _selected_frames()
	var frames: Array[VoxelFrame] = []
	for index in range(frame_range.x, frame_range.y + 1):
		frames.append(State.get_voxel_frame(index).copy_frame())
	var resolution := int(_sheet_settings.get_node("SizeRow/Size").value)
	var settings := _sheet_render_settings(_sheet_settings.get_node("ViewRow/View").selected, _view_count())
	settings.layout = sheet_layout(frames.size() * settings.transforms.size(), resolution)
	_preview_operation_id = State.begin_operation("Rendering sheet preview", frames.size() * settings.transforms.size(), false, self)
	var image := await _render_sheet(frames, settings, State.document, revision)
	_preview_running = false
	State.finish_operation(_preview_operation_id)
	_preview_operation_id = 0
	_preview_viewport = null
	if image and revision == _preview_revision:
		_preview_image = image
		_controls.get_node("Preview").texture = ImageTexture.create_from_image(image)


func export_sprite_sheet(path: String, first_frame := 0, last_frame := -1, tile_size := -1, view := 1, include_json := true, views := 1, tag_name := "") -> Error:
	if _exporting or State.edit_busy():
		return ERR_BUSY
	if DisplayServer.get_name() == "headless":
		return ERR_UNAVAILABLE
	last_frame = State.get_frame_count() - 1 if last_frame < 0 else last_frame
	if first_frame < 0 or last_frame < first_frame or last_frame >= State.get_frame_count() or view < 0 or view >= VIEWS.size() or views < 1:
		return ERR_INVALID_PARAMETER
	var settings := _sheet_render_settings(view, views)
	if tile_size < 0:
		tile_size = int(_sheet_settings.get_node("SizeRow/Size").value)
	if tile_size < 1:
		return ERR_INVALID_PARAMETER
	var frames: Array[VoxelFrame] = []
	for index in range(first_frame, last_frame + 1):
		frames.append(State.get_voxel_frame(index).copy_frame())
	var layout := sheet_layout(frames.size() * views, tile_size)
	if layout.size.x > Image.MAX_WIDTH or layout.size.y > Image.MAX_HEIGHT:
		return ERR_INVALID_PARAMETER
	settings.layout = layout
	if path.get_extension().to_lower() != "png":
		path += ".png"
	var metadata := sheet_metadata(path, first_frame, last_frame, layout, views, tag_name)
	var source_document := State.document
	State.stop()
	_exporting = true
	_cancel_requested = false
	_preview_revision += 1
	_operation_id = State.begin_operation("Exporting sprite sheet", frames.size() * views, true, self)
	var image := await _render_sheet(frames, settings, source_document)
	if image == null:
		_finish_export()
		return ERR_BUSY
	var error := image.save_png(path)
	if error == OK and include_json:
		var file := FileAccess.open(path.get_basename() + ".json", FileAccess.WRITE)
		if file:
			file.store_string(JSON.stringify(metadata, "\t"))
			error = file.get_error()
		else:
			error = FileAccess.get_open_error()
	_finish_export()
	return error


func sheet_metadata(path: String, first: int, last: int, layout: Dictionary, views := 1, tag_name := "") -> Dictionary:
	var count := last - first + 1
	var dimensions: Vector2i = layout.tile_size
	var label: String = tag_name if not tag_name.is_empty() else path.get_file().get_basename()
	var frames := []
	for index in count * views:
		var source_index := first + index % count
		var filename := "%s_%d" % [label, source_index]
		if views > 1:
			filename += "_%d" % floori(index / float(count))
		var rect: Rect2i = layout.rects[index]
		frames.append({"filename": filename, "frame": {"x": rect.position.x, "y": rect.position.y, "w": rect.size.x, "h": rect.size.y}, "rotated": false, "trimmed": false, "spriteSourceSize": {"x": 0, "y": 0, "w": dimensions.x, "h": dimensions.y}, "sourceSize": {"w": dimensions.x, "h": dimensions.y}, "duration": maxi(1, State.get_voxel_frame(source_index).delay_ms)})
	var tags := []
	for view_index in views:
		for tag in State.document.tags:
			if tag.to < first or tag.from > last:
				continue
			var tag_label := tag.name if views == 1 else "%s_%d" % [tag.name, view_index]
			tags.append({"name": tag_label, "from": maxi(tag.from, first) - first + view_index * count, "to": mini(tag.to, last) - first + view_index * count, "direction": ["forward", "reverse", "pingpong", "pingpong_reverse"][tag.loop_mode], "repeat": str(tag.repeats)})
	return {"frames": frames, "meta": {"app": VoxelDocument.APP_NAME, "image": path.get_file(), "format": "RGBA8888", "size": {"w": layout.size.x, "h": layout.size.y}, "scale": "1", "frameTags": tags}}


func _cancel_export() -> void:
	_cancel_requested = true
	_gltf.cancel()


func _finish_export() -> void:
	if is_instance_valid(_export_viewport):
		_export_viewport.free()
	_export_viewport = null
	_exporting = false
	State.finish_operation(_operation_id)
	_operation_id = 0
	if is_instance_valid(_workspace):
		_sync()
		_preview_due_ms = Time.get_ticks_msec() + PREVIEW_DELAY_MS
