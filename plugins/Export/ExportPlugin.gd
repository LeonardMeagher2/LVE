extends VoxiPlugin

const GLTF_EXPORT := preload("./GLTFExport.gd")
const VIEWS := ["3D preview", "Isometric", "Front", "Back", "Left", "Right", "Top", "Bottom"]
const ANGLES := [Vector2.ZERO, Vector2(-45, 45), Vector2.ZERO, Vector2(180, 0), Vector2(90, 0), Vector2(-90, 0), Vector2(0, 90), Vector2(0, -90)]
const PREVIEW_DELAY_MS := 200

@onready var _menu_item := preload("./MenuBarItem.tscn").instantiate()
@onready var _workspace := preload("./Workspace.tscn").instantiate()
@onready var _model: VBoxContainer = _workspace.get_node("%Model")
@onready var _controls: VBoxContainer = _workspace.get_node("%Sheet")
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
var _model_viewport: SubViewport
var _model_renderer: VoxelRenderer
var _model_back_renderer: VoxelRenderer
var _model_pending_frame := -1
var _model_playback := AnimationPlayback.new()
var _model_camera: EditorCameraRig
var _selected_tag: AnimationTag
var _sheet_tag: AnimationTag
var _model_frames: Array[VoxelFrame] = []
var _model_step := 0
var _automatic_sprite_size := true
var _result_message := ""


func _ready() -> void:
	name = "ExportPlugin"
	_gltf = GLTF_EXPORT.new(self)
	_model_viewport = _model.get_node("Viewport/PanelContainer/SubViewportContainer/Viewport")
	_model_viewport.own_world_3d = true
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
	_model.get_node("Viewport/ControlBar/PanToggle").button_group = view_group
	_model.get_node("Viewport/ControlBar/RotateToggle").button_group = view_group
	for view in VIEWS:
		_controls.get_node("ViewRow/View").add_item(view)
	_controls.get_node("ViewRow/View").select(1)
	add_menu_bar_item(_menu_item)
	add_tab(_workspace)
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
	_controls.get_node("FrameRow/Frames").item_selected.connect(_on_sheet_tag_selected)
	_controls.get_node("ViewRow/View").item_selected.connect(_sheet_settings_changed.unbind(1))
	for path in ["ColumnsRow/Columns", "TurntableRow/Views"]:
		_controls.get_node(path).value_changed.connect(_sheet_settings_changed.unbind(1))
	_controls.get_node("SizeRow/Size").value_changed.connect(_on_sprite_size_changed.unbind(1))
	_controls.get_node("SizeRow/Reset").pressed.connect(_reset_sprite_size)
	_controls.get_node("TurntableRow/Turntable").toggled.connect(_sheet_settings_changed.unbind(1))
	_model.get_node("OriginRow/Center").toggled.connect(_model_settings_changed.unbind(1))
	_model.get_node("AnimationRow/Tags").item_selected.connect(_on_model_tag_selected)
	_model.get_node("AnimationRow/Play").toggled.connect(_on_play_toggled)
	_model_camera.view_changed.connect(_on_preview_camera_changed)
	State.document_changed.connect(_on_document_changed)
	State.frames_changed.connect(_source_changed)
	State.frame_changed.connect(_source_changed)
	State.tag_changed.connect(_source_changed)
	State.cells_changed.connect(_source_changed.unbind(2))
	State.chunks_changed.connect(_source_changed.unbind(2))
	State.activity_changed.connect(_sync)
	_model.get_node("Viewport/ControlBar/GridToggle").button_pressed = false
	_model.get_node("Viewport/ControlBar/RotateToggle").button_pressed = true
	_sync_tags()
	_update_default_sprite_size()
	_sync()


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
	_automatic_sprite_size = true
	_model_frames.clear()
	_model_playback.is_playing = false
	_model_playback.document = VoxiDocument.new()
	_model_renderer.source_frame = VoxelFrame.new()
	_model_back_renderer.source_frame = VoxelFrame.new()
	_model_pending_frame = -1
	_source_changed()


func _on_sprite_size_changed() -> void:
	_automatic_sprite_size = false
	_sheet_settings_changed()


func _reset_sprite_size() -> void:
	_automatic_sprite_size = true
	_sheet_settings_changed()


func _view_count() -> int:
	return int(_controls.get_node("TurntableRow/Views").value) if _controls.get_node("TurntableRow/Turntable").button_pressed else 1


func _update_default_sprite_size() -> void:
	if not _automatic_sprite_size:
		return
	var range := _selected_frames()
	var span := _sprite_span(_bounds(range.x, range.y), _sheet_camera(_controls.get_node("ViewRow/View").selected), _view_count())
	_controls.get_node("SizeRow/Size").set_value_no_signal(span)


static func _sprite_span(bounds: AABB, settings: Dictionary, views: int) -> int:
	if not settings.has("angles"):
		var camera_span: float = settings.size
		if settings.projection == Camera3D.PROJECTION_PERSPECTIVE:
			var transform: Transform3D = settings.transform
			var distance := (transform.origin - bounds.get_center()).dot(transform.basis.z)
			camera_span = 2.0 * distance * tan(deg_to_rad(settings.fov) * 0.5)
		return maxi(1, ceili(camera_span - 0.00001))
	var right: Vector3
	var up: Vector3
	var angles: Vector2 = settings.angles
	var yaw := deg_to_rad(angles.x)
	var pitch := deg_to_rad(angles.y)
	right = Vector3(cos(yaw), 0, -sin(yaw))
	up = Vector3(-sin(yaw) * sin(pitch), cos(pitch), -cos(yaw) * sin(pitch))
	var span := 1.0
	for index in views:
		var rotation := Basis(Vector3.UP, TAU * index / views)
		span = maxf(span, (rotation * right).abs().dot(bounds.size))
		span = maxf(span, (rotation * up).abs().dot(bounds.size))
	return ceili(span - 0.00001)


func _sync_tags() -> void:
	var selector: OptionButton = _model.get_node("AnimationRow/Tags")
	var index := State.document.tags.find(_selected_tag) if _selected_tag else -1
	_selected_tag = State.document.get_tag(index)
	var sheet_selector: OptionButton = _controls.get_node("FrameRow/Frames")
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
	_result_message = ""
	_sync()


func _model_range() -> Vector2i:
	return Vector2i(_selected_tag.from, _selected_tag.to) if _selected_tag and State.document.tags.has(_selected_tag) else Vector2i(0, State.get_frame_count() - 1)


func _sheet_settings_changed() -> void:
	_result_message = ""
	_update_default_sprite_size()
	_preview_revision += 1
	_preview_due_ms = Time.get_ticks_msec() + PREVIEW_DELAY_MS
	_preview_image = null
	_controls.get_node("Preview").texture = null
	_sync()


func _on_preview_camera_changed() -> void:
	_refresh_export_status()
	if _controls.get_node("ViewRow/View").selected == 0:
		_sheet_settings_changed()


func _selected_frames() -> Vector2i:
	if _sheet_tag and State.document.tags.has(_sheet_tag):
		return Vector2i(_sheet_tag.from, _sheet_tag.to)
	return Vector2i(0, State.get_frame_count() - 1)


func _bounds(first: int, last: int) -> AABB:
	var bounds := AABB()
	for index in range(first, last + 1):
		var box := State.get_voxel_frame(index).get_bounds()
		if box.has_volume():
			bounds = bounds.merge(box) if bounds.has_volume() else box
	return bounds


func _model_transform() -> Transform3D:
	var range := _model_range()
	var center := _bounds(range.x, range.y).get_center() if _model.get_node("OriginRow/Center").button_pressed else Vector3.ZERO
	return Transform3D(Basis.IDENTITY, -center)


func _model_bounds() -> AABB:
	var range := _model_range()
	return _model_transform() * _bounds(range.x, range.y)


func _refresh_model() -> void:
	_model_dirty = false
	var range := _model_range()
	_model_frames.clear()
	for index in range(range.x, range.y + 1):
		_model_frames.append(State.get_voxel_frame(index).copy_frame())
	_model_renderer.transform = _model_transform()
	_model_back_renderer.transform = _model_renderer.transform
	var playing: bool = _model.get_node("AnimationRow/Play").button_pressed
	_model_playback.is_playing = false
	var preview_document := VoxiDocument.new()
	preview_document.frames.assign(_model_frames)
	preview_document.tags.clear()
	if _selected_tag:
		var tag: AnimationTag = _selected_tag.duplicate()
		tag.from -= range.x
		tag.to -= range.x
		preview_document.tags.append(tag)
	_model_playback.document = preview_document
	_model_playback.active_tag = 0 if _selected_tag else -1
	_model_playback.current_frame = clampi(State.current_frame - range.x, 0, _model_frames.size() - 1)
	if playing:
		_model_playback.is_playing = true
	_show_model_frame()
	_model_camera.center_active()
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
	_model.get_node("AnimationRow/Play").text = "Pause" if playing else "Play"


func _sync() -> void:
	var busy := State.edit_busy()
	var range := _selected_frames()
	var count := range.y - range.x + 1
	var views := _view_count()
	var tile_size := int(_controls.get_node("SizeRow/Size").value)
	var layout := sheet_layout(count * views, tile_size, int(_controls.get_node("ColumnsRow/Columns").value))
	_menu_item.get_node("ExportBtn").disabled = busy
	_model.get_node("Export").disabled = busy
	_controls.get_node("Export").disabled = busy or layout.size.x > Image.MAX_WIDTH or layout.size.y > Image.MAX_HEIGHT
	for path in ["FrameRow/Frames", "ViewRow/View"]:
		_controls.get_node(path).disabled = busy
	for path in ["SizeRow/Size", "ColumnsRow/Columns"]:
		_controls.get_node(path).editable = not busy
	_controls.get_node("Metadata").disabled = busy
	_controls.get_node("SizeRow/Reset").disabled = busy
	_controls.get_node("TurntableRow/Turntable").disabled = busy
	_controls.get_node("TurntableRow/Views").editable = not busy and views > 1
	_model.get_node("OriginRow/Center").disabled = busy
	_model.get_node("AnimationRow/Tags").disabled = busy
	_model.get_node("AnimationRow/Play").disabled = busy or _model_range().x == _model_range().y
	_refresh_export_status()


func _export_status() -> Dictionary:
	var range := _selected_frames()
	var count := range.y - range.x + 1
	var layout := sheet_layout(count * _view_count(), int(_controls.get_node("SizeRow/Size").value), int(_controls.get_node("ColumnsRow/Columns").value))
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
	_dialog.current_file = State.document.title.get_file().get_basename() + ".glb"
	_dialog.popup_centered()


func _choose_sheet_file() -> void:
	_sheet_dialog.current_file = State.document.title.get_file().get_basename() + "_sheet.png"
	_sheet_dialog.popup_centered()


func _on_gltf_file_selected(path: String) -> void:
	_report_result(await export_gltf(path), path)


func export_gltf(path: String) -> Error:
	var error: Error = await _gltf.export_gltf(path, _model.get_node("OriginRow/Center").button_pressed, State.document.tags.find(_selected_tag) if _selected_tag else -1)
	_sync()
	_preview_due_ms = Time.get_ticks_msec() + PREVIEW_DELAY_MS
	return error


func _on_sheet_file_selected(path: String) -> void:
	var range := _selected_frames()
	_report_result(await export_sprite_sheet(path, range.x, range.y, int(_controls.get_node("SizeRow/Size").value), int(_controls.get_node("ColumnsRow/Columns").value), _controls.get_node("ViewRow/View").selected, _controls.get_node("Metadata").button_pressed, _view_count()), path)


func _report_result(error: Error, path: String) -> void:
	_result_message = "Saved %s" % path.get_file() if error == OK else ("Export cancelled" if error == ERR_BUSY or error == ERR_UNAVAILABLE else "Export failed: %s" % error_string(error))
	_refresh_export_status()


static func sheet_layout(frame_count: int, tile_size: int, columns: int) -> Dictionary:
	var actual_columns := mini(frame_count, columns) if columns > 0 else ceili(sqrt(float(frame_count)))
	actual_columns = maxi(1, actual_columns)
	var rows := ceili(frame_count / float(actual_columns))
	return {"columns": actual_columns, "size": Vector2i(actual_columns * tile_size, rows * tile_size)}


func _sheet_camera(view: int) -> Dictionary:
	if view == 0:
		var inverse := _model_transform().affine_inverse()
		var transform := _model_camera.transform
		transform.origin = inverse * transform.origin
		return {"transform": transform, "projection": _model_camera.projection, "size": _model_camera.size, "fov": _model_camera.fov, "near": _model_camera.near, "far": _model_camera.far}
	return {"angles": ANGLES[view]}


func _render_current(document: VoxiDocument, revision: int) -> bool:
	if not is_inside_tree() or State.document != document:
		return false
	if revision >= 0:
		return revision == _preview_revision and _workspace.is_visible_in_tree() and not State.edit_busy()
	return not _cancel_requested and State.has_operation(_operation_id)


func _render_sheet(frames: Array[VoxelFrame], bounds: AABB, tile_size: int, columns: int, camera_settings: Dictionary, document: VoxiDocument, revision := -1, views := 1) -> Image:
	var viewport: SubViewport = VoxelImageRenderer.VIEWPORT_SCENE.instantiate()
	viewport.size = Vector2i.ONE * tile_size
	if revision >= 0:
		_preview_viewport = viewport
	else:
		_export_viewport = viewport
	add_child(viewport)
	var renderer: VoxelRenderer = viewport.get_node("%VoxelRenderer")
	var camera: Camera3D = viewport.get_node("Node3D/Camera3D")
	if camera_settings.has("angles"):
		var angles: Vector2 = camera_settings.angles
		VoxelImageRenderer.frame_camera(camera, bounds, angles.x, angles.y, true)
		camera.size = _sprite_span(bounds, camera_settings, views)
	else:
		for property in camera_settings:
			camera.set(property, camera_settings[property])
	var initial_transform := camera.transform
	var layout := sheet_layout(frames.size() * views, tile_size, columns)
	var sheet := Image.create(layout.size.x, layout.size.y, false, Image.FORMAT_RGBA8)
	sheet.fill(Color.TRANSPARENT)
	for index in frames.size() * views:
		State.update_operation(_preview_operation_id if revision >= 0 else _operation_id, index, frames.size() * views, "Rendering sheet preview" if revision >= 0 else "Rendering sprite %d" % (index + 1))
		var angle := TAU * (index / frames.size()) / views
		var rotation := Basis(Vector3.UP, angle)
		camera.transform = Transform3D(rotation * initial_transform.basis, bounds.get_center() + rotation * (initial_transform.origin - bounds.get_center()))
		renderer.source_frame = frames[index % frames.size()]
		while not renderer.is_settled():
			await get_tree().process_frame
			if not _render_current(document, revision):
				if is_instance_valid(viewport):
					viewport.free()
				return null
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		if not _render_current(document, revision):
			if is_instance_valid(viewport):
				viewport.free()
			return null
		var image := viewport.get_texture().get_image()
		image.convert(Image.FORMAT_RGBA8)
		var tile := Vector2i(index % int(layout.columns), index / int(layout.columns)) * tile_size
		sheet.blit_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), tile)
	viewport.free()
	return sheet


func _update_sheet_preview() -> void:
	_preview_due_ms = -1
	if DisplayServer.get_name() == "headless" or _controls.get_node("Export").disabled:
		return
	_preview_running = true
	var revision := _preview_revision
	var range := _selected_frames()
	var frames: Array[VoxelFrame] = []
	for index in range(range.x, range.y + 1):
		frames.append(State.get_voxel_frame(index).copy_frame())
	_preview_operation_id = State.begin_operation("Rendering sheet preview", frames.size() * _view_count(), false, self)
	var image := await _render_sheet(frames, _bounds(range.x, range.y), int(_controls.get_node("SizeRow/Size").value), int(_controls.get_node("ColumnsRow/Columns").value), _sheet_camera(_controls.get_node("ViewRow/View").selected), State.document, revision, _view_count())
	_preview_running = false
	State.finish_operation(_preview_operation_id)
	_preview_operation_id = 0
	_preview_viewport = null
	if image and revision == _preview_revision:
		_preview_image = image
		_controls.get_node("Preview").texture = ImageTexture.create_from_image(image)


func export_sprite_sheet(path: String, first_frame := 0, last_frame := -1, tile_size := -1, columns := 0, view := 1, include_json := true, views := 1) -> Error:
	if _exporting or State.edit_busy():
		return ERR_BUSY
	if DisplayServer.get_name() == "headless":
		return ERR_UNAVAILABLE
	last_frame = State.get_frame_count() - 1 if last_frame < 0 else last_frame
	if columns < 0 or first_frame < 0 or last_frame < first_frame or last_frame >= State.get_frame_count() or view < 0 or view >= VIEWS.size() or views < 1:
		return ERR_INVALID_PARAMETER
	if tile_size < 0:
		tile_size = _sprite_span(_bounds(first_frame, last_frame), _sheet_camera(view), views)
	if tile_size < 1:
		return ERR_INVALID_PARAMETER
	var layout := sheet_layout((last_frame - first_frame + 1) * views, tile_size, columns)
	if layout.size.x > Image.MAX_WIDTH or layout.size.y > Image.MAX_HEIGHT:
		return ERR_INVALID_PARAMETER
	var frames: Array[VoxelFrame] = []
	for index in range(first_frame, last_frame + 1):
		frames.append(State.get_voxel_frame(index).copy_frame())
	if path.get_extension().to_lower() != "png":
		path += ".png"
	var metadata := sheet_metadata(path, first_frame, last_frame, tile_size, columns, views)
	var source_document := State.document
	State.stop()
	_exporting = true
	_cancel_requested = false
	_preview_revision += 1
	_operation_id = State.begin_operation("Exporting sprite sheet", frames.size() * views, true, self)
	var image := await _render_sheet(frames, _bounds(first_frame, last_frame), tile_size, columns, _sheet_camera(view), source_document, -1, views)
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


func sheet_metadata(path: String, first: int, last: int, tile_size: int, columns: int, views := 1) -> Dictionary:
	var count := last - first + 1
	var layout := sheet_layout(count * views, tile_size, columns)
	var frames := []
	for index in count * views:
		var source_index := first + index % count
		var filename := "%s %d" % [path.get_file().get_basename(), source_index]
		if views > 1:
			filename += " view %d" % (index / count)
		var tile := Vector2i(index % int(layout.columns), index / int(layout.columns)) * tile_size
		frames.append({"filename": filename, "frame": {"x": tile.x, "y": tile.y, "w": tile_size, "h": tile_size}, "rotated": false, "trimmed": false, "spriteSourceSize": {"x": 0, "y": 0, "w": tile_size, "h": tile_size}, "sourceSize": {"w": tile_size, "h": tile_size}, "duration": maxi(1, State.get_voxel_frame(source_index).delay_ms)})
	var tags := []
	for view_index in views:
		for tag in State.document.tags:
			if tag.to < first or tag.from > last:
				continue
			var tag_name := tag.name if views == 1 else "%s view %d" % [tag.name, view_index]
			tags.append({"name": tag_name, "from": maxi(tag.from, first) - first + view_index * count, "to": mini(tag.to, last) - first + view_index * count, "direction": ["forward", "reverse", "pingpong", "pingpong_reverse"][tag.loop_mode], "repeat": str(tag.repeats)})
	return {"frames": frames, "meta": {"app": "Voxi", "image": path.get_file(), "format": "RGBA8888", "size": {"w": layout.size.x, "h": layout.size.y}, "scale": "1", "frameTags": tags}}


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
