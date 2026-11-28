extends VoxelPlugin


const GLTF_EXPORT := preload("./GLTFExport.gd")
const GIF_ENCODER := preload("./GifEncoder.gd")
const NORMAL_SHADER := preload("./normal_export.gdshader")
const SPECULAR_SHADER := preload("./specular_export.gdshader")
const VIEWS := ["3D preview", "Isometric", "Front", "Back", "Left", "Right", "Top", "Bottom"]
const VIEW_KEYS := ["current", "isometric", "front", "back", "left", "right", "top", "bottom"]
const ANGLES := [Vector2.ZERO, Vector2(-45, 45), Vector2.ZERO, Vector2(180, 0), Vector2(90, 0), Vector2(-90, 0), Vector2(0, 90), Vector2(0, -90)]
const PREVIEW_DELAY_MS := 200
const SPRITE_GAP := 1
const SHEET_FIT_MARGIN := 1.02
const SUPERSAMPLE := 2

@onready var _menu_item := preload("./MenuBarItem.tscn").instantiate()
@onready var _workspace := preload("./Workspace.tscn").instantiate()
@onready var _model: VBoxContainer = _workspace.get_node("%Model")
@onready var _controls: VBoxContainer = _workspace.get_node("%Sheet")
@onready var _sheet_settings: GridContainer = _controls.get_node("Settings")
@onready var _export_button: Button = _controls.get_node("ExportRow/Export")
@onready var _gif_button: Button = _controls.get_node("ExportRow/Gif")
@onready var _light_button: Button = _controls.get_node("ControlBar/LightToggle")
@onready var _maps_button: Button = _controls.get_node("ControlBar/MapsToggle")
@onready var _specular_intensity = _controls.get_node("ControlBar/SpecularIntensity")
@onready var _dialog: FileDialog = _menu_item.get_node("ExportDialog")
@onready var _sheet_dialog: FileDialog = _menu_item.get_node("SpriteSheetDialog")
@onready var _gif_dialog: FileDialog = _menu_item.get_node("GifDialog")

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
var _preview_texture: ImageTexture
var _preview_canvas_texture: CanvasTexture
var _preview_normal_image: Image
var _preview_normal_texture: ImageTexture
var _preview_specular_image: Image
var _preview_specular_texture: ImageTexture
var _preview_maps_texture: ImageTexture
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
var _sheet_projection := Camera3D.PROJECTION_PERSPECTIVE
var _sheet_fov := 45.0
var _restoring_export_settings := false
var _pending_export_camera := {}
var _selected_tag: AnimationTag
var _sheet_tag: AnimationTag
var _model_frames: Array[VoxelFrame] = []
var _model_step := 0
var _result_message := ""
var _specular_default: ShaderMaterial
var _specular_materials: Dictionary = {}


func _ready() -> void:
	name = "ExportPlugin"
	_gltf = GLTF_EXPORT.new(self)
	_specular_default = ShaderMaterial.new()
	_specular_default.shader = SPECULAR_SHADER
	_specular_default.set_shader_parameter("has_orm", false)
	_model_viewport = _model.get_node("Viewport/PanelContainer/SubViewportContainer/Viewport")
	_model_viewport.own_world_3d = true
	_model_viewport.get_node("ViewportScene").document_lighting = false
	_model_viewport.get_node("ViewportScene").document_view = false
	_model_renderer = _model_viewport.get_node("ViewportScene/VoxelRenderer")
	_model_renderer.report_activity = false
	_model_renderer.source_frame = State.get_composite_voxel_frame(State.current_frame).copy_frame()
	_model_back_renderer = preload("res://ui/Viewport/VoxelRenderer.tscn").instantiate()
	_model_back_renderer.name = "VoxelRendererBack"
	_model_back_renderer.report_activity = false
	_model_back_renderer.source_frame = VoxelFrame.new()
	_model_back_renderer.visible = false
	_model_viewport.get_node("ViewportScene").add_child(_model_back_renderer)
	_model_playback.frame_changed.connect(_show_model_frame)
	_model_playback.is_playing_toggled.connect(_on_model_playing_changed)
	_model_camera = _model_viewport.get_node("ViewportScene/CameraRig")
	_model_camera.stores_document_pose = false
	_model_camera.bounds_provider = _model_bounds
	var view_group: ButtonGroup = _model.get_node("Viewport/ControlBar/PanToggle").button_group.duplicate()
	for button in ["PanToggle", "RotateToggle"]:
		_model.get_node("Viewport/ControlBar/" + button).button_group = view_group
	_model.get_node("Viewport/EnvironmentLayer/EnvironmentBar/Margin/Bar/LightToggle").button_group = view_group
	for view in VIEWS:
		_sheet_settings.get_node("ViewRow/View").add_item(view)
	_sheet_settings.get_node("ViewRow/View").select(1)
	add_menu_bar_item(_menu_item)
	add_tab(_workspace)
	var panels: BoxContainer = _workspace.get_node("%Panels")
	if OS.has_feature("mobile"):
		panels.vertical = true
	_model_scene = _model_viewport.get_node("ViewportScene")
	_default_lighting = _model_scene.get_lighting_settings()
	_default_camera = _capture_export_camera()
	_model_scene.lighting_changed.connect(_on_model_lighting_changed)
	_menu_item.get_node("ExportBtn").toggled.connect(_on_export_toggled)
	_workspace.visibility_changed.connect(_on_workspace_visibility_changed)
	_model.get_node("Export").pressed.connect(_choose_gltf_file)
	_dialog.file_selected.connect(_on_gltf_file_selected)
	_sheet_dialog.file_selected.connect(_on_sheet_file_selected)
	_gif_dialog.file_selected.connect(_on_gif_file_selected)
	_export_button.pressed.connect(_choose_export_file)
	_gif_button.toggled.connect(_on_gif_toggled)
	var sheet_preview: Control = _controls.get_node("Preview")
	var sheet_bar: HBoxContainer = _controls.get_node("ControlBar")
	sheet_bar.get_node("PanToggle").toggled.connect(sheet_preview.set_pan_mode)
	sheet_bar.get_node("PanToggle").button_pressed = true
	sheet_bar.get_node("ZoomSlider").value_changed.connect(sheet_preview.set_zoom_percent)
	sheet_preview.zoom_changed.connect(sheet_bar.get_node("ZoomSlider").set_value_no_signal)
	sheet_bar.get_node("ZoomOne").pressed.connect(sheet_preview.set_zoom_percent.bind(100.0))
	sheet_bar.get_node("CenterBtn").pressed.connect(sheet_preview.fit)
	_light_button.toggled.connect(_on_light_toggled)
	_maps_button.toggled.connect(_on_maps_preview_toggled)
	_specular_intensity.value_changed.connect(_on_specular_intensity_changed)
	_sheet_settings.get_node("FrameRow/Frames").item_selected.connect(_on_sheet_tag_selected)
	_sheet_settings.get_node("ViewRow/View").item_selected.connect(_sheet_settings_changed.unbind(1))
	_sheet_settings.get_node("ViewRow/Center").toggled.connect(_sheet_settings_changed.unbind(1))
	_sheet_settings.get_node("TurntableRow/Views").value_changed.connect(_sheet_settings_changed.unbind(1))
	_sheet_settings.get_node("SizeRow/Size").value_changed.connect(_sheet_settings_changed.unbind(1))
	_sheet_settings.get_node("SizeRow/Reset").pressed.connect(_reset_sprite_size)
	_sheet_settings.get_node("TurntableRow/Turntable").toggled.connect(_sheet_settings_changed.unbind(1))
	_controls.get_node("ExportRow/Metadata").toggled.connect(_save_export_settings.unbind(1))
	_model.get_node("AnimationRow/Center").toggled.connect(_model_settings_changed.unbind(1))
	_model.get_node("AnimationRow/Tags").item_selected.connect(_on_model_tag_selected)
	_model.get_node("AnimationRow/Play").toggled.connect(_on_play_toggled)
	_model_camera.view_changed.connect(_on_preview_camera_changed)
	State.document_changed.connect(_on_document_changed)
	State.frames_changed.connect(_source_changed)
	State.tag_changed.connect(_source_changed)
	State.cells_changed.connect(_source_changed.unbind(3))
	State.chunks_changed.connect(_source_changed.unbind(3))
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
		"sprite_center": _sheet_settings.get_node("ViewRow/Center").button_pressed,
		"frame_size": _sheet_settings.get_node("SizeRow/Size").value,
		"turntable": _sheet_settings.get_node("TurntableRow/Turntable").button_pressed,
		"views": _sheet_settings.get_node("TurntableRow/Views").value,
		"metadata": _controls.get_node("ExportRow/Metadata").button_pressed,
		"normal": _light_button.button_pressed,
		"specular": _light_button.button_pressed,
		"specular_intensity": float(_specular_intensity.value),
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
	_sheet_settings.get_node("ViewRow/Center").set_pressed_no_signal(saved.get("sprite_center", false))
	_sheet_settings.get_node("SizeRow/Size").set_value_no_signal(saved.get("frame_size", 64))
	_sheet_settings.get_node("TurntableRow/Turntable").set_pressed_no_signal(saved.get("turntable", true))
	_sheet_settings.get_node("TurntableRow/Views").set_value_no_signal(saved.get("views", 8))
	_controls.get_node("ExportRow/Metadata").set_pressed_no_signal(saved.get("metadata", false))
	_light_button.set_pressed_no_signal(bool(saved.get("normal", false)) or bool(saved.get("specular", false)))
	_maps_button.set_pressed_no_signal(false)
	_specular_intensity.set_value_no_signal(saved.get("specular_intensity", 1.0))
	_model.get_node("AnimationRow/Center").set_pressed_no_signal(saved.get("center", false))
	var lighting: Dictionary = saved.get("lighting", _default_lighting)
	_model_scene.set_lighting_settings(lighting)
	_pending_export_camera = saved.get("camera", {}).duplicate()
	_model_camera._yaw = _pending_export_camera.get("yaw", _default_camera.yaw)
	_model_camera._pitch = _pending_export_camera.get("pitch", _default_camera.pitch)
	_model_camera.fov = clampf(float(_pending_export_camera.get("fov", _default_camera.fov)), EditorCameraRig.MIN_FOV, EditorCameraRig.MAX_FOV)
	_model_scene.set_orthographic(_pending_export_camera.get("orthographic", _default_camera.orthographic))
	_gif_button.set_pressed_no_signal(false)
	_controls.get_node("Preview").clear_animation()
	_controls.get_node("Preview").set_light_enabled(false)
	_controls.get_node("Preview").set_normal_map(null)
	_controls.get_node("Preview").set_specular_map(null)
	_preview_texture = null
	_preview_canvas_texture = null
	_preview_normal_image = null
	_preview_normal_texture = null
	_preview_specular_image = null
	_preview_specular_texture = null
	_preview_maps_texture = null
	_restoring_export_settings = false


func apply_document_export_settings() -> void:
	_restore_export_settings()
	_model_dirty = true
	_preview_revision += 1
	_preview_due_ms = Time.get_ticks_msec() + PREVIEW_DELAY_MS


func current_export_settings() -> Dictionary:
	var view_index: int = _sheet_settings.get_node("ViewRow/View").selected
	var sheet_range := _selected_frames()
	var model_range := _model_range()
	var sheet_tag_index := State.document.tags.find(_sheet_tag) if _sheet_tag else -1
	var model_tag_index := State.document.tags.find(_selected_tag) if _selected_tag else -1
	return {
		"sprite": {
			"view": VIEW_KEYS[clampi(view_index, 0, VIEW_KEYS.size() - 1)],
			"orthographic": _model_camera.is_orthogonal,
			"center": _sheet_settings.get_node("ViewRow/Center").button_pressed,
			"tile_size": int(_sheet_settings.get_node("SizeRow/Size").value),
			"views": _view_count(),
			"metadata": _controls.get_node("ExportRow/Metadata").button_pressed,
			"normal": _light_button.button_pressed,
			"specular": _light_button.button_pressed,
			"specular_intensity": float(_specular_intensity.value),
			"tag": sheet_tag_index,
			"tag_name": _sheet_tag.name if _sheet_tag else "",
			"first_frame": sheet_range.x,
			"last_frame": sheet_range.y,
		},
		"model": {
			"center": _model.get_node("AnimationRow/Center").button_pressed,
			"tag": model_tag_index,
			"smooth_normals": State.document.smooth_normals,
			"ao": State.document.ao_strength,
			"unlit": false,
			"first_frame": model_range.x,
			"last_frame": model_range.y,
		},
	}


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
		_set_status_context(_export_status)
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
	if not is_instance_valid(_sheet_settings):
		return 1
	return int(_sheet_settings.get_node("TurntableRow/Views").value) if _sheet_settings.get_node("TurntableRow/Turntable").button_pressed else 1


static func _sprite_span(bounds: AABB, settings: Dictionary) -> int:
	var span: float = settings.get("content_span", settings.size)
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
	_preview_texture = null
	_preview_canvas_texture = null
	_preview_normal_image = null
	_preview_normal_texture = null
	_preview_specular_image = null
	_preview_specular_texture = null
	_preview_maps_texture = null
	var preview: Control = _controls.get_node("Preview")
	preview.clear_animation()
	preview.set_light_enabled(false)
	preview.set_normal_map(null)
	preview.set_specular_map(null)
	preview.texture = null
	_save_export_settings()
	_sync()


func _sheet_lighting() -> Dictionary:
	return _model_scene.get_lighting_settings()


func _on_model_lighting_changed() -> void:
	_sync_model_shading()
	_sheet_settings_changed()


func _sync_model_shading() -> void:
	var unshaded: bool = not bool(_sheet_lighting().get("shaded", true))
	_model_renderer.unshaded = unshaded
	_model_back_renderer.unshaded = unshaded


func _on_preview_camera_changed() -> void:
	if _restoring_export_settings or State.document != _settings_document:
		return
	_save_export_settings()
	_refresh_export_status()
	var projection_changed := _model_camera.projection != _sheet_projection
	_sheet_projection = _model_camera.projection
	var fov_changed := not is_equal_approx(_model_camera.fov, _sheet_fov)
	_sheet_fov = _model_camera.fov
	if projection_changed or fov_changed or _sheet_settings.get_node("ViewRow/View").selected == 0:
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
	var model_delays := []
	for index in range(frame_range.x, frame_range.y + 1):
		_model_frames.append(State.get_composite_voxel_frame(index).copy_frame())
		model_delays.append(State.document.frame_delay(index))
	_model_renderer.transform = _model_transform()
	_model_back_renderer.transform = _model_renderer.transform
	var was_playing := _model_playback.is_playing
	var was_frame := _model_playback.current_frame
	var preview_document := VoxelDocument.new()
	preview_document.replace_active_frames(_model_frames, model_delays)
	preview_document.tags.clear()
	if _selected_tag:
		var tag: AnimationTag = _selected_tag.duplicate()
		tag.from -= frame_range.x
		tag.to -= frame_range.x
		preview_document.tags.append(tag)
	_model_playback.document = preview_document
	_model_playback.active_tag = 0 if _selected_tag else -1
	_model_playback.current_frame = clampi(
		was_frame if was_playing else State.current_frame - frame_range.x,
		0,
		maxi(0, _model_frames.size() - 1)
	)
	preview_document.edit_playing = was_playing
	_show_model_frame()
	_apply_export_camera()
	_on_preview_camera_changed()
	_model_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS


func _apply_export_camera() -> void:
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


func _ensure_export_camera() -> void:
	if _model_dirty:
		_refresh_model()
	else:
		_apply_export_camera()


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
	_sync_model_shading()
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
	if not is_instance_valid(_sheet_settings):
		return
	var busy := State.edit_busy()
	var frame_range := _selected_frames()
	var count := frame_range.y - frame_range.x + 1
	var views := _view_count()
	var tile_size := int(_sheet_settings.get_node("SizeRow/Size").value)
	_sheet_settings.get_node("SizeRow/Size").tooltip_text = "Frame size: %d × %d px. Use Reset for the camera framing." % [tile_size, tile_size]
	var layout := sheet_layout(count * views, tile_size)
	var gif := _gif_enabled()
	var normal_on := _light_button.button_pressed and not gif
	_menu_item.get_node("ExportBtn").disabled = busy
	_model.get_node("Export").disabled = busy
	_export_button.disabled = busy or (not gif and (layout.size.x > Image.MAX_WIDTH or layout.size.y > Image.MAX_HEIGHT))
	if gif:
		_export_button.tooltip_text = "Export the animation as a GIF"
	elif normal_on:
		_export_button.tooltip_text = "Export the sprite sheet, normal map, and specular map as PNG images"
	else:
		_export_button.tooltip_text = "Export the sprite sheet as a PNG image"
	_gif_button.disabled = busy
	_light_button.disabled = busy or gif
	_light_button.tooltip_text = "Turn off GIF mode to enable normal and specular maps." if gif else "Enable normal and specular maps. Move the pointer over the sheet to light it. The export writes both map sheets."
	_maps_button.disabled = busy or gif or not _light_button.button_pressed
	_specular_intensity.editable = not busy and not gif
	if _maps_button.disabled and _maps_button.button_pressed:
		_maps_button.set_pressed_no_signal(false)
		_show_sheet_preview()
	if not _light_button.button_pressed:
		_maps_button.tooltip_text = "Turn on Light to enable maps."
	elif gif:
		_maps_button.tooltip_text = "Turn off GIF mode to view the maps."
	else:
		_maps_button.tooltip_text = "Show both map sheets side by side. Press again to return to the lit sheet."
	_specular_intensity.tooltip_text = "Specular intensity: %.2f. Drag to change." % float(_specular_intensity.value)
	for path in ["FrameRow/Frames", "ViewRow/View", "ViewRow/Center"]:
		_sheet_settings.get_node(path).disabled = busy
	_sheet_settings.get_node("SizeRow/Size").editable = not busy
	_controls.get_node("ExportRow/Metadata").disabled = busy
	_sheet_settings.get_node("SizeRow/Reset").disabled = busy
	_sheet_settings.get_node("TurntableRow/Turntable").disabled = busy
	_sheet_settings.get_node("TurntableRow/Views").editable = not busy and views > 1
	_model.get_node("AnimationRow/Center").disabled = busy
	_model.get_node("AnimationRow/Tags").disabled = busy
	_model.get_node("AnimationRow/Play").disabled = busy or _model_range().x == _model_range().y
	_refresh_export_status()


func _export_status() -> Dictionary:
	var frame_range := _selected_frames()
	var count := frame_range.y - frame_range.x + 1
	var views := _view_count()
	var tile_size := int(_sheet_settings.get_node("SizeRow/Size").value)
	var message := _result_message
	if message.is_empty():
		if _gif_enabled():
			message = "%d × %d pixels · %d GIF frames" % [tile_size, tile_size, count * views]
		else:
			var layout := sheet_layout(count * views, tile_size)
			message = "%d × %d pixels · %d frames × %d views" % [layout.size.x, layout.size.y, count, views]
			if _light_button.button_pressed:
				message += " · normal + specular"
	return {
		"left": "%s   #%d/%d   %d%%" % [
			message,
			_model_step + 1,
			maxi(1, _model_frames.size()),
			roundi(_model_camera.zoom_percent()),
		],
		"right": "",
	}


func _refresh_export_status() -> void:
	if _workspace.is_visible_in_tree():
		_set_status_context(_export_status)


func _set_status_context(provider: Callable) -> void:
	var main: Node = context.main if context != null and is_instance_valid(context.main) else null
	if main:
		var status_bar: EditorStatusBar = main.get_node_or_null("%StatusBar")
		if status_bar:
			status_bar.set_context(provider)


func _process(delta: float) -> void:
	if not is_instance_valid(_workspace) or not _workspace.is_visible_in_tree():
		return
	_model_playback.update(delta)
	if State.edit_busy():
		return
	if _model_dirty:
		_refresh_model()
	_present_model_frame()
	if not _preview_running and _preview_due_ms >= 0 and Time.get_ticks_msec() >= _preview_due_ms:
		_update_sheet_preview()


func _choose_gltf_file() -> void:
	_dialog.current_file = State.document.get_file_name().get_basename() + ".glb"
	_dialog.popup_centered()


func _gif_enabled() -> bool:
	return _gif_button.button_pressed


func _choose_export_file() -> void:
	if _gif_enabled():
		_choose_gif_file()
	else:
		_choose_sheet_file()


func _choose_sheet_file() -> void:
	_sheet_dialog.title = "Export Sprite Sheet and Maps" if _light_button.button_pressed else "Export Sprite Sheet"
	_sheet_dialog.current_file = State.document.get_file_name().get_basename() + "_sheet.png"
	_sheet_dialog.popup_centered()


func _choose_gif_file() -> void:
	_gif_dialog.current_file = State.document.get_file_name().get_basename() + ".gif"
	_gif_dialog.popup_centered()


func _on_gif_toggled(_pressed: bool) -> void:
	_show_sheet_preview()
	_apply_preview_animation()
	if _light_button.button_pressed:
		_preview_due_ms = Time.get_ticks_msec() + PREVIEW_DELAY_MS
	_sync()


func _on_light_toggled(pressed: bool) -> void:
	if not pressed:
		_maps_button.set_pressed_no_signal(false)
	_sheet_settings_changed()


func _on_maps_preview_toggled(pressed: bool) -> void:
	if pressed and (not _light_button.button_pressed or _preview_maps_texture == null):
		_maps_button.set_pressed_no_signal(false)
		return
	_show_sheet_preview()
	_apply_preview_animation()
	_sync()


func _on_specular_intensity_changed(value: float) -> void:
	var preview: Control = _controls.get_node("Preview")
	preview.set_specular_intensity(value)
	_save_export_settings()
	_sync()


func _on_gltf_file_selected(path: String) -> void:
	_report_result(await export_gltf(path), path)


func export_gltf(path: String) -> Error:
	return await export_gltf_settings(path, {
		"center": _model.get_node("AnimationRow/Center").button_pressed,
		"tag": State.document.tags.find(_selected_tag) if _selected_tag else -1,
	})


func export_gltf_settings(path: String, settings: Dictionary) -> Error:
	if _exporting or State.edit_busy():
		return ERR_BUSY
	var tag_value: Variant = settings.get("tag", -1)
	var tag_index := int(tag_value) if tag_value is int or tag_value is float else -1
	if tag_index < -1 or tag_index >= State.document.tags.size():
		return ERR_INVALID_PARAMETER
	var overrides := {}
	for key in ["smooth_normals", "ao", "unlit"]:
		if settings.has(key):
			overrides[key] = settings[key]
	var error: Error = OK
	_exporting = true
	error = await _gltf.export_gltf(path, bool(settings.get("center", false)), tag_index, overrides)
	_exporting = false
	_sync()
	_preview_due_ms = Time.get_ticks_msec() + PREVIEW_DELAY_MS
	return error


func _on_sheet_file_selected(path: String) -> void:
	var settings: Dictionary = current_export_settings().sprite
	_report_result(await export_sprite_sheet_settings(path, settings), path, bool(settings.get("normal", false)), bool(settings.get("specular", false)))


func _on_gif_file_selected(path: String) -> void:
	_report_result(await export_gif(path), path)


func _report_result(error: Error, path: String, normal := false, specular := false) -> void:
	if error == OK:
		_result_message = "Saved %s" % path.get_file()
		if normal:
			_result_message += " + normal"
		if specular:
			_result_message += " + specular"
	else:
		_result_message = "Export cancelled" if error == ERR_BUSY or error == ERR_UNAVAILABLE else "Export failed: %s" % error_string(error)
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


static func normal_path(path: String) -> String:
	return path.get_basename() + "_normal.png"


static func specular_path(path: String) -> String:
	return path.get_basename() + "_specular.png"


func _pose_fit_distance(camera: Camera3D, bounds: AABB, fov_value: float) -> float:
	var center := bounds.get_center()
	if not bounds.has_surface():
		return (camera.position - center).length()
	var tan_half := maxf(tan(deg_to_rad(fov_value) * 0.5), 0.0001)
	var required := 0.0
	for index in 8:
		var corner := bounds.get_endpoint(index) - center
		var extent := maxf(absf(corner.dot(camera.basis.x)), absf(corner.dot(camera.basis.y)))
		required = maxf(required, extent / tan_half + corner.dot(camera.basis.z))
	return maxf(required, 0.001) * SHEET_FIT_MARGIN


func _sheet_camera(view: int, views := 1, orthographic_value: Variant = null) -> Dictionary:
	var orthographic: bool = bool(orthographic_value) if orthographic_value is bool else _model_camera.is_orthogonal
	var bounds := State.document.bounds()
	var transform: Transform3D
	var size: float = _model_camera.size
	var near_plane: float = _model_camera.near
	var content_span := 0.0
	if view == 0:
		var inverse := _model_transform().affine_inverse()
		transform = _model_camera.transform
		transform.origin = inverse * transform.origin
		if orthographic:
			content_span = size
		else:
			var distance := (transform.origin - bounds.get_center()).dot(transform.basis.z)
			content_span = maxf(0.001, 2.0 * distance * tan(deg_to_rad(_model_camera.fov) * 0.5))
		if orthographic and _model_camera.projection != Camera3D.PROJECTION_ORTHOGONAL:
			size = content_span
	else:
		var camera := Camera3D.new()
		add_child(camera)
		var angles: Vector2 = ANGLES[view]
		VoxelImageRenderer.frame_camera(camera, bounds, angles.x, angles.y, orthographic)
		if orthographic:
			near_plane = camera.near
		else:
			var center := bounds.get_center()
			var offset := camera.position - center
			var distance := _pose_fit_distance(camera, bounds, _model_camera.fov)
			camera.position = center + offset.normalized() * distance
			near_plane = maxf(0.001, minf(camera.near, distance * 0.1))
		transform = camera.transform
		camera.free()
	var transforms: Array[Transform3D] = []
	for view_index in views:
		var turn := Basis(Vector3.UP, TAU * view_index / views)
		transforms.append(Transform3D(turn * transform.basis, bounds.get_center() + turn * (transform.origin - bounds.get_center())))
	if view > 0:
		content_span = 1.0
		for pose in transforms:
			content_span = maxf(content_span, pose.basis.x.abs().dot(bounds.size))
			content_span = maxf(content_span, pose.basis.y.abs().dot(bounds.size))
		if orthographic:
			size = ceili(content_span - 0.00001)
	return {"transforms": transforms, "projection": Camera3D.PROJECTION_ORTHOGONAL if orthographic else Camera3D.PROJECTION_PERSPECTIVE, "size": size, "content_span": content_span, "fov": _model_camera.fov, "near": near_plane}


func _sheet_render_settings(view: int, views: int, orthographic: bool, center: bool, lighting: Dictionary) -> Dictionary:
	var settings := _sheet_camera(view, views, orthographic)
	var bounds := State.document.bounds()
	var model_transform := Transform3D(Basis.IDENTITY, -bounds.get_center() if center else Vector3.ZERO)
	for index in settings.transforms.size():
		settings.transforms[index] = model_transform * settings.transforms[index]
	settings.model_transform = model_transform
	settings.lighting = lighting
	var render_bounds := model_transform * bounds
	var near_depth := INF
	var far_depth := -INF
	for pose: Transform3D in settings.transforms:
		var forward := -pose.basis.z
		near_depth = minf(near_depth, (render_bounds.get_support(-forward) - pose.origin).dot(forward))
		far_depth = maxf(far_depth, (render_bounds.get_support(forward) - pose.origin).dot(forward))
	settings.near = maxf(0.05, minf(settings.near, near_depth - 1.0))
	settings.far = maxf(settings.near + 1.0, far_depth + 1.0) * 2.0
	return settings


func _render_current(document: VoxelDocument, revision: int) -> bool:
	if not is_inside_tree() or State.document != document:
		return false
	if revision >= 0:
		return revision == _preview_revision and _workspace.is_visible_in_tree() and not State.edit_busy()
	return not _cancel_requested and State.has_operation(_operation_id)


func _fit_frames(entries: Array[Dictionary], union: Rect2i, tile_size: Vector2i) -> Array[Image]:
	var scale := minf(float(tile_size.x) / union.size.x, float(tile_size.y) / union.size.y)
	var fitted := Vector2i(
		clampi(roundi(union.size.x * scale), 1, tile_size.x),
		clampi(roundi(union.size.y * scale), 1, tile_size.y)
	)
	var origin := (tile_size - fitted) / 2
	var tiles: Array[Image] = []
	for entry in entries:
		var used: Rect2i = entry.used
		var source: Image = entry.image
		if source == null or used.size.x <= 0 or used.size.y <= 0:
			tiles.append(_blank_tile(tile_size))
			continue
		var canvas := Image.create(union.size.x, union.size.y, false, Image.FORMAT_RGBA8)
		canvas.fill(Color.TRANSPARENT)
		canvas.blit_rect(source, Rect2i(Vector2i.ZERO, used.size), used.position - union.position)
		canvas.resize(fitted.x, fitted.y, Image.INTERPOLATE_NEAREST)
		var tile := _blank_tile(tile_size)
		tile.blit_rect(canvas, Rect2i(Vector2i.ZERO, fitted), origin)
		tiles.append(tile)
	return tiles


func _blank_tile(tile_size: Vector2i) -> Image:
	var tile := Image.create(tile_size.x, tile_size.y, false, Image.FORMAT_RGBA8)
	tile.fill(Color.TRANSPARENT)
	return tile


func _blit_sheet_entries(sheets: Dictionary, entries: Array[Dictionary], union: Rect2i, tile_size: Vector2i) -> void:
	if union.size.x <= 0 or union.size.y <= 0:
		return
	var tiles := _fit_frames(entries, union, tile_size)
	for index in entries.size():
		var entry: Dictionary = entries[index]
		var tile_rect: Rect2i = entry.rect
		var sheet: Image = sheets[entry.output]
		sheet.blit_rect(tiles[index], Rect2i(Vector2i.ZERO, tile_size), tile_rect.position)


func _render_sheet(frames: Array[VoxelFrame], settings: Dictionary, document: VoxelDocument, revision := -1) -> Variant:
	var outputs: Array = settings.get("outputs", ["color"])
	var lighting_settings: Dictionary = settings.lighting
	var transforms: Array[Transform3D] = settings.transforms
	var layout: Dictionary = settings.layout
	var viewport := _open_image_viewport(settings, layout.tile_size * SUPERSAMPLE)
	if revision >= 0:
		_preview_viewport = viewport
	else:
		_export_viewport = viewport
	var renderer: VoxelRenderer = viewport.get_node("%VoxelRenderer")
	var camera: Camera3D = viewport.get_node("Node3D/Camera3D")
	var light: DirectionalLight3D = viewport.get_node("Node3D/Light")
	camera.transform = transforms[0]
	var tile_count: int = layout.rects.size()
	var capture_count := tile_count * outputs.size()
	var sheets := {}
	for output in outputs:
		var sheet := Image.create(layout.size.x, layout.size.y, false, Image.FORMAT_RGBA8)
		sheet.fill(Color.TRANSPARENT)
		sheets[output] = sheet
	var normal_material: ShaderMaterial
	if outputs.has("normal"):
		normal_material = ShaderMaterial.new()
		normal_material.shader = NORMAL_SHADER
	if outputs.has("specular"):
		_specular_materials.clear()
	var entries: Array[Dictionary] = []
	var union := Rect2i()
	var index := 0
	var capture_index := 0
	var complete := true
	for pose in transforms:
		if not _render_current(document, revision):
			complete = false
			break
		camera.transform = pose
		if lighting_settings.view_locked:
			light.basis = camera.basis * lighting_settings.view_basis
		for frame in frames:
			renderer.source_frame = frame
			while _render_current(document, revision) and not renderer.is_settled():
				await get_tree().process_frame
			if not _render_current(document, revision):
				complete = false
				break
			var rect: Rect2i = layout.rects[index]
			var tile_used := Rect2i()
			for output in outputs:
				var label := "Rendering sheet preview" if revision >= 0 else ("Rendering sprite %d" % (index + 1) if output == "color" else "Rendering %s %d" % [output, index + 1])
				State.update_operation(_preview_operation_id if revision >= 0 else _operation_id, capture_index, capture_count, label)
				renderer.override_material = normal_material if output == "normal" else null
				if output == "specular":
					renderer.material_builder = Callable(self, "_specular_material")
				else:
					renderer.material_builder = Callable()
				viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
				await RenderingServer.frame_post_draw
				if not _render_current(document, revision):
					complete = false
					break
				if output == "color":
					viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
					await RenderingServer.frame_post_draw
					if not _render_current(document, revision):
						complete = false
						break
				var image := viewport.get_texture().get_image()
				image.convert(Image.FORMAT_RGBA8)
				if output == "specular":
					image = _specular_sheet_image(image)
				if output == "color":
					tile_used = image.get_used_rect()
					if tile_used.size.x > 0 and tile_used.size.y > 0:
						union = tile_used if union.size.x <= 0 else union.merge(tile_used)
				var region: Image = null
				if tile_used.size.x > 0 and tile_used.size.y > 0:
					region = image.get_region(tile_used)
				entries.append({"output": output, "rect": rect, "used": tile_used, "image": region})
				capture_index += 1
			renderer.override_material = null
			renderer.material_builder = Callable()
			if not complete:
				break
			index += 1
		if not complete:
			break
	if complete and union.size.x > 0 and union.size.y > 0:
		_blit_sheet_entries(sheets, entries, union, layout.tile_size)
	if is_instance_valid(viewport):
		viewport.free()
	if revision >= 0:
		_preview_viewport = null
	else:
		_export_viewport = null
	_specular_materials.clear()
	return sheets if complete and capture_index == capture_count else null


func _specular_material(source: Material) -> Material:
	if not source is StandardMaterial3D:
		return _specular_default
	var material_3d := source as StandardMaterial3D
	if material_3d.roughness_texture == null:
		return _specular_default
	var key := source.get_instance_id()
	var material: ShaderMaterial = _specular_materials.get(key)
	if material == null:
		material = ShaderMaterial.new()
		material.shader = SPECULAR_SHADER
		material.set_shader_parameter("orm_texture", material_3d.roughness_texture)
		material.set_shader_parameter("has_orm", true)
		_specular_materials[key] = material
	return material


func _specular_sheet_image(image: Image) -> Image:
	var specular := Image.create(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8)
	specular.fill(Color.TRANSPARENT)
	for y in image.get_height():
		for x in image.get_width():
			var source := image.get_pixel(x, y)
			if source.a == 0.0:
				continue
			var metallic := source.r8
			var shininess := source.g8
			specular.set_pixel(x, y, Color8(metallic, metallic, metallic, shininess))
	return specular


func _open_image_viewport(settings: Dictionary, viewport_size: Vector2i) -> SubViewport:
	var lighting_settings: Dictionary = settings.lighting
	var viewport: SubViewport = VoxelImageRenderer.VIEWPORT_SCENE.instantiate()
	viewport.size = viewport_size
	viewport.use_debanding = false
	add_child(viewport)
	var environment_node: WorldEnvironment = viewport.get_node("Node3D/WorldEnvironment")
	environment_node.environment = environment_node.environment.duplicate()
	environment_node.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment_node.environment.tonemap_exposure = 1.0
	var light: DirectionalLight3D = viewport.get_node("Node3D/Light")
	VoxelImageRenderer.apply_lighting(light, environment_node.environment, lighting_settings)
	var renderer: VoxelRenderer = viewport.get_node("%VoxelRenderer")
	renderer.unshaded = not lighting_settings.shaded
	renderer.transform = settings.model_transform
	var camera: Camera3D = viewport.get_node("Node3D/Camera3D")
	camera.projection = settings.projection
	camera.size = settings.size
	camera.fov = settings.fov
	camera.near = settings.near
	camera.far = settings.far
	VoxelImageRenderer.apply_directional_shadow(light, camera)
	return viewport


func _render_gif_frames(frames: Array[VoxelFrame], delays: PackedInt32Array, settings: Dictionary, document: VoxelDocument, encoder) -> Error:
	var tile_size: Vector2i = settings.tile_size
	var viewport := _open_image_viewport(settings, tile_size * SUPERSAMPLE)
	_export_viewport = viewport
	var lighting_settings: Dictionary = settings.lighting
	var transforms: Array[Transform3D] = settings.transforms
	var renderer: VoxelRenderer = viewport.get_node("%VoxelRenderer")
	var camera: Camera3D = viewport.get_node("Node3D/Camera3D")
	var light: DirectionalLight3D = viewport.get_node("Node3D/Light")
	var count := frames.size() * transforms.size()
	var error := OK
	var index := 0
	var entries: Array[Dictionary] = []
	var union := Rect2i()
	for pose in transforms:
		if not _render_current(document, -1):
			error = ERR_BUSY
			break
		camera.transform = pose
		if lighting_settings.view_locked:
			light.basis = camera.basis * lighting_settings.view_basis
		for frame in frames:
			if not _render_current(document, -1):
				error = ERR_BUSY
				break
			var source_index := index % frames.size()
			State.update_operation(_operation_id, index, count, "Rendering GIF frame %d" % (index + 1))
			renderer.source_frame = frame
			while _render_current(document, -1) and not renderer.is_settled():
				await get_tree().process_frame
			if not _render_current(document, -1):
				error = ERR_BUSY
				break
			viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			await RenderingServer.frame_post_draw
			if not _render_current(document, -1):
				error = ERR_BUSY
				break
			viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			await RenderingServer.frame_post_draw
			if not _render_current(document, -1):
				error = ERR_BUSY
				break
			var image := viewport.get_texture().get_image()
			image.convert(Image.FORMAT_RGBA8)
			var used := image.get_used_rect()
			if used.size.x > 0 and used.size.y > 0:
				union = used if union.size.x <= 0 else union.merge(used)
			var region: Image = null
			if used.size.x > 0 and used.size.y > 0:
				region = image.get_region(used)
			entries.append({"used": used, "image": region, "delay": delays[source_index] if source_index < delays.size() else 100})
			index += 1
			await get_tree().process_frame
		if error != OK:
			break
	if is_instance_valid(viewport):
		viewport.free()
	_export_viewport = null
	if error == OK and not entries.is_empty():
		error = _add_gif_frames(encoder, entries, union, tile_size)
	if error == OK and not _render_current(document, -1):
		error = ERR_BUSY
	return error


func _add_gif_frames(encoder, entries: Array[Dictionary], union: Rect2i, tile_size: Vector2i) -> Error:
	if union.size.x <= 0 or union.size.y <= 0:
		union = Rect2i(Vector2i.ZERO, tile_size)
	var tiles := _fit_frames(entries, union, tile_size)
	for index in entries.size():
		var error: Error = encoder.add_frame(tiles[index], int(entries[index].delay))
		if error != OK:
			return error
	return OK


func _update_sheet_preview() -> void:
	_preview_due_ms = -1
	if DisplayServer.get_name() == "headless":
		return
	var frame_range := _selected_frames()
	var count := frame_range.y - frame_range.x + 1
	var views := _view_count()
	var resolution := int(_sheet_settings.get_node("SizeRow/Size").value)
	var layout := sheet_layout(count * views, resolution)
	if layout.size.x > Image.MAX_WIDTH or layout.size.y > Image.MAX_HEIGHT:
		return
	_preview_running = true
	var revision := _preview_revision
	var frames: Array[VoxelFrame] = []
	for index in range(frame_range.x, frame_range.y + 1):
		frames.append(State.get_composite_voxel_frame(index).copy_frame())
	var settings := _sheet_render_settings(
		_sheet_settings.get_node("ViewRow/View").selected,
		views,
		_model_camera.is_orthogonal,
		_sheet_settings.get_node("ViewRow/Center").button_pressed,
		_sheet_lighting()
	)
	settings.layout = layout
	var normal_on: bool = _light_button.button_pressed and not _gif_enabled()
	var outputs: Array = ["color"]
	if normal_on:
		outputs.append("normal")
		outputs.append("specular")
	settings.outputs = outputs
	_preview_operation_id = State.begin_operation("Rendering preview", frames.size() * views * outputs.size(), false, self)
	var images: Variant = await _render_sheet(frames, settings, State.document, revision)
	_preview_running = false
	State.finish_operation(_preview_operation_id)
	_preview_operation_id = 0
	_preview_viewport = null
	if images and revision == _preview_revision:
		_preview_image = images.get("color")
		_preview_texture = ImageTexture.create_from_image(_preview_image)
		_preview_normal_image = images.get("normal")
		_preview_normal_texture = ImageTexture.create_from_image(_preview_normal_image) if _preview_normal_image else null
		_preview_specular_image = images.get("specular")
		_preview_specular_texture = ImageTexture.create_from_image(_preview_specular_image) if _preview_specular_image else null
		_preview_maps_texture = null
		if _preview_normal_image and _preview_specular_image and _preview_image:
			var normal_display := _preview_normal_image
			var specular_display := _specular_display_image(_preview_specular_image, _preview_image)
			var maps := Image.create(normal_display.get_width() + SPRITE_GAP + specular_display.get_width(), maxi(normal_display.get_height(), specular_display.get_height()), false, Image.FORMAT_RGBA8)
			maps.fill(Color.TRANSPARENT)
			maps.blit_rect(normal_display, Rect2i(Vector2i.ZERO, normal_display.get_size()), Vector2i.ZERO)
			maps.blit_rect(specular_display, Rect2i(Vector2i.ZERO, specular_display.get_size()), Vector2i(normal_display.get_width() + SPRITE_GAP, 0))
			_preview_maps_texture = ImageTexture.create_from_image(maps)
		_preview_canvas_texture = null
		if _preview_normal_texture or _preview_specular_texture:
			_preview_canvas_texture = CanvasTexture.new()
			_preview_canvas_texture.diffuse_texture = _preview_texture
			_preview_canvas_texture.normal_texture = _preview_normal_texture
			if _preview_specular_texture:
				_preview_canvas_texture.specular_texture = _preview_specular_texture
				_preview_canvas_texture.specular_shininess = 0.99
		_show_sheet_preview()
		_apply_preview_animation()


func _specular_display_image(specular: Image, color: Image) -> Image:
	var display := Image.create(specular.get_width(), specular.get_height(), false, Image.FORMAT_RGBA8)
	display.fill(Color.TRANSPARENT)
	for y in specular.get_height():
		for x in specular.get_width():
			if color.get_pixel(x, y).a == 0.0:
				continue
			var value := specular.get_pixel(x, y)
			display.set_pixel(x, y, Color(value.r, value.g, value.b, 1.0))
	return display


func _show_sheet_preview() -> void:
	var preview: Control = _controls.get_node("Preview")
	if _gif_enabled():
		preview.texture = _preview_texture
		preview.set_light_enabled(false)
		return
	preview.set_normal_map(_preview_normal_texture)
	preview.set_specular_map(_preview_specular_texture)
	preview.set_specular_intensity(float(_specular_intensity.value))
	if _maps_button.button_pressed and _preview_maps_texture:
		preview.texture = _preview_maps_texture
		preview.set_light_enabled(false)
	else:
		preview.texture = _preview_canvas_texture if _preview_canvas_texture else _preview_texture
		preview.set_light_enabled(_light_button.button_pressed)


func _apply_preview_animation() -> void:
	var preview: Control = _controls.get_node("Preview")
	if not _gif_enabled() or _preview_image == null:
		preview.clear_animation()
		return
	var frame_range := _selected_frames()
	var count := frame_range.y - frame_range.x + 1
	var views := _view_count()
	var tile_size := int(_sheet_settings.get_node("SizeRow/Size").value)
	var layout := sheet_layout(count * views, tile_size)
	var delays := PackedInt32Array()
	for index in count * views:
		var source_index := frame_range.x + index % count
		delays.append(State.document.frame_delay(source_index))
	preview.set_animation(layout.rects, delays)


func export_sprite_sheet(path: String, first_frame := 0, last_frame := -1, tile_size := -1, view := 1, include_json := false, views := 1, tag_name := "", normal := false, specular := false) -> Error:
	if view < 0 or view >= VIEW_KEYS.size():
		return ERR_INVALID_PARAMETER
	return await export_sprite_sheet_settings(path, {
		"first_frame": first_frame,
		"last_frame": last_frame,
		"tile_size": tile_size,
		"view": VIEW_KEYS[view],
		"metadata": include_json,
		"views": views,
		"tag_name": tag_name,
		"normal": normal,
		"specular": specular,
	})


func export_sprite_sheet_settings(path: String, settings: Dictionary) -> Error:
	if _exporting or State.edit_busy():
		return ERR_BUSY
	if DisplayServer.get_name() == "headless":
		return ERR_UNAVAILABLE
	_ensure_export_camera()
	var tab: Dictionary = current_export_settings().sprite
	var frame_count := State.get_frame_count()
	var first_frame := int(settings.get("first_frame", 0))
	var last_frame := int(settings.get("last_frame", -1))
	if last_frame < 0:
		last_frame = frame_count - 1
	var tile_size := int(settings.get("tile_size", -1))
	if tile_size < 0:
		tile_size = tab.tile_size
	var view := VIEW_KEYS.find(str(settings.get("view", tab.view)))
	var views := int(settings.get("views", tab.views))
	var orthographic := bool(settings.get("orthographic", tab.orthographic))
	var center := bool(settings.get("center", tab.center))
	var include_json := bool(settings.get("metadata", tab.metadata))
	var normal_value: Variant = settings.get("normal", tab.get("normal", false))
	if not normal_value is bool:
		return ERR_INVALID_PARAMETER
	var normal: bool = normal_value
	var specular_value: Variant = settings.get("specular", tab.get("specular", false))
	if not specular_value is bool:
		return ERR_INVALID_PARAMETER
	var specular: bool = specular_value
	var tag_name := str(settings.get("tag_name", ""))
	var lighting: Dictionary = settings.get("lighting", {})
	if lighting.is_empty():
		lighting = _sheet_lighting()
	if first_frame < 0 or last_frame < first_frame or last_frame >= frame_count or view < 0 or views < 1 or tile_size < 1:
		return ERR_INVALID_PARAMETER
	var render_settings := _sheet_render_settings(view, views, orthographic, center, lighting)
	var frames: Array[VoxelFrame] = []
	for index in range(first_frame, last_frame + 1):
		frames.append(State.get_composite_voxel_frame(index).copy_frame())
	var layout := sheet_layout(frames.size() * views, tile_size)
	if layout.size.x > Image.MAX_WIDTH or layout.size.y > Image.MAX_HEIGHT:
		return ERR_INVALID_PARAMETER
	var outputs: Array = ["color"]
	if normal:
		outputs.append("normal")
	if specular:
		outputs.append("specular")
	render_settings.layout = layout
	render_settings.outputs = outputs
	if path.get_extension().to_lower() != "png":
		path += ".png"
	var metadata := sheet_metadata(path, first_frame, last_frame, layout, views, tag_name, normal, specular)
	var source_document := State.document
	State.stop()
	_exporting = true
	_cancel_requested = false
	_preview_revision += 1
	_operation_id = State.begin_operation("Exporting", frames.size() * views * outputs.size(), true, self, _cancel_export)
	var images: Variant = await _render_sheet(frames, render_settings, source_document)
	if not images is Dictionary:
		_finish_export()
		return ERR_BUSY
	var sheets: Dictionary = images
	var color_image: Image = sheets.get("color")
	if color_image == null:
		_finish_export()
		return ERR_INVALID_DATA
	var error := color_image.save_png(path)
	if error == OK and normal:
		var normal_image: Image = sheets.get("normal")
		if normal_image == null:
			error = ERR_INVALID_DATA
		else:
			error = normal_image.save_png(normal_path(path))
	if error == OK and specular:
		var specular_image: Image = sheets.get("specular")
		if specular_image == null:
			error = ERR_INVALID_DATA
		else:
			error = specular_image.save_png(specular_path(path))
	if error == OK and include_json:
		var file := FileAccess.open(path.get_basename() + ".json", FileAccess.WRITE)
		if file:
			file.store_string(JSON.stringify(metadata, "\t"))
			error = file.get_error()
		else:
			error = FileAccess.get_open_error()
	_finish_export()
	return error


func export_gif(path: String) -> Error:
	return await export_gif_settings(path, current_export_settings().sprite)


func export_gif_settings(path: String, settings: Dictionary) -> Error:
	if _exporting or State.edit_busy():
		return ERR_BUSY
	if DisplayServer.get_name() == "headless":
		return ERR_UNAVAILABLE
	_ensure_export_camera()
	var tab: Dictionary = current_export_settings().sprite
	var frame_count := State.get_frame_count()
	var first := int(settings.get("first_frame", tab.first_frame))
	var last := int(settings.get("last_frame", tab.last_frame))
	if last < 0:
		last = frame_count - 1
	var tile_size := int(settings.get("tile_size", -1))
	if tile_size < 0:
		tile_size = tab.tile_size
	var view := VIEW_KEYS.find(str(settings.get("view", tab.view)))
	var views := int(settings.get("views", tab.views))
	var orthographic := bool(settings.get("orthographic", tab.orthographic))
	var center := bool(settings.get("center", tab.center))
	var lighting: Dictionary = settings.get("lighting", {})
	if lighting.is_empty():
		lighting = _sheet_lighting()
	if first < 0 or last < first or last >= frame_count or view < 0 or views < 1 or tile_size < 1 or tile_size > 2048:
		return ERR_INVALID_PARAMETER
	var frames: Array[VoxelFrame] = []
	var frame_delays := PackedInt32Array()
	for index in range(first, last + 1):
		var frame := State.get_composite_voxel_frame(index)
		if frame == null:
			return ERR_INVALID_PARAMETER
		frames.append(frame.copy_frame())
		frame_delays.append(State.document.frame_delay(index))
	var render_settings := _sheet_render_settings(view, views, orthographic, center, lighting)
	render_settings.tile_size = Vector2i(tile_size, tile_size)
	if path.get_extension().to_lower() != "gif":
		path += ".gif"
	var source_document := State.document
	var base_colors := PackedColorArray()
	for entry in source_document.palette:
		var material: PackedFloat32Array = entry
		var color := VoxelFrame.material_color(material)
		if color.a <= 0.5:
			continue
		if base_colors.size() >= 255:
			break
		base_colors.append(color)
	State.stop()
	_exporting = true
	_cancel_requested = false
	_preview_revision += 1
	_operation_id = State.begin_operation("Exporting GIF", frames.size() * render_settings.transforms.size(), true, self, _cancel_export)
	var encoder = GIF_ENCODER.new(tile_size, tile_size, 0, base_colors)
	var error: Error = await _render_gif_frames(frames, frame_delays, render_settings, source_document, encoder)
	if error == OK:
		var gif: PackedByteArray = encoder.finish()
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			error = FileAccess.get_open_error()
		else:
			file.store_buffer(gif)
			error = file.get_error()
			file.close()
	_finish_export()
	return error


func sheet_metadata(path: String, first: int, last: int, layout: Dictionary, views := 1, tag_name := "", normal := false, specular := false) -> Dictionary:
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
		frames.append({"filename": filename, "frame": {"x": rect.position.x, "y": rect.position.y, "w": rect.size.x, "h": rect.size.y}, "rotated": false, "trimmed": false, "spriteSourceSize": {"x": 0, "y": 0, "w": dimensions.x, "h": dimensions.y}, "sourceSize": {"w": dimensions.x, "h": dimensions.y}, "duration": maxi(1, State.document.frame_delay(source_index))})
	var tags := []
	for view_index in views:
		for tag in State.document.tags:
			if tag.to < first or tag.from > last:
				continue
			var tag_label := tag.name if views == 1 else "%s_%d" % [tag.name, view_index]
			tags.append({"name": tag_label, "from": maxi(tag.from, first) - first + view_index * count, "to": mini(tag.to, last) - first + view_index * count, "direction": ["forward", "reverse", "pingpong", "pingpong_reverse"][tag.loop_mode], "repeat": str(tag.repeats)})
	var meta := {"app": VoxelDocument.APP_NAME, "image": path.get_file(), "format": "RGBA8888", "size": {"w": layout.size.x, "h": layout.size.y}, "scale": "1", "frameTags": tags}
	var lve := {}
	if normal:
		lve["normal"] = {"image": normal_path(path).get_file(), "space": "view", "convention": "+x, +y, +z"}
	if specular:
		lve["specular"] = {"image": specular_path(path).get_file(), "color": "metallic", "alpha": "shininess", "shininess": "1 - roughness"}
	if not lve.is_empty():
		meta["lve"] = lve
	return {"frames": frames, "meta": meta}


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
