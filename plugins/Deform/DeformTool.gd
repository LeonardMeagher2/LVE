extends VoxelTool


const BrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")
const VoxelLineMesh := preload("res://Globals/Rendering/VoxelLineMesh.gd")

const INLINE_EDIT_LIMIT := 4096


class DeformJob extends VoxelFrame.EditJob:
	var stroke_id := 0
	var operation_id := 0
	var edited_frame: VoxelFrame
	var context: VoxelFrame.EditContext
	var destination_selection := {}
	var removed_cells := {}
	var changed_chunks: Array[Vector3i] = []

	func run() -> void:
		var changes := compute_changes()
		if changes.is_empty() or not checkpoint(0):
			return
		stage("Applying deform", changes.size())
		changed_chunks = apply_cells(edited_frame, changes)

	func compute_changes() -> Dictionary:
		return {}

	func estimated_work() -> int:
		return 0

	func allows(cell: Vector3i) -> bool:
		return context == null or context.allows(cell)


var _settings: DeformToolSettings = preload("./DeformSettings.tres")

var _last_pick: PickResult
var _footprint: MeshInstance3D
var _footprint_meshes := {}

var _stroke_id := 0
var _stroke_tx: VoxelEditTransaction
var _stroke_size := 4
var _stroke_face := -1
var _stroke_touch := Vector2.ZERO
var _hover_face := -1
var _hover_touch := Vector2.ZERO
var _stroke_falloff := 0.5
var _stroke_context: VoxelFrame.EditContext
var _write_context: VoxelFrame.EditContext
var _stroke_selection := {}
var _stroke_track_selection := false
var _source_document: VoxelDocument
var _source_frame: VoxelFrame
var _baseline: VoxelFrame
var _anchor := VoxelPicking.NONE
var _drag := VoxelPicking.NONE
var _drag_point := Vector3.ZERO
var _pending_target = null
var _published := {}
var _job: DeformJob
var _operation_id := 0
var _end_requested := false

var _view_forward := Vector3.FORWARD
var _view_right := Vector3.RIGHT
var _view_up := Vector3.UP


func _action_name() -> String:
	return "Deform"


func _operation_label() -> String:
	return "Deforming voxels"


func _enter_tree() -> void:
	if not tree_exited.is_connected(_release_subscriptions):
		tree_exited.connect(_release_subscriptions)
	if not State.edit_context_changing.is_connected(_cancel_edit):
		State.edit_context_changing.connect(_cancel_edit)
	if not State.history_changed.is_connected(_on_history_changed):
		State.history_changed.connect(_on_history_changed)
	if not _settings.changed.is_connected(_on_settings_changed):
		_settings.changed.connect(_on_settings_changed)
	if not State.document_changed.is_connected(_on_document_changed):
		State.document_changed.connect(_on_document_changed)


func _ready() -> void:
	_setup_footprint()
	visible = false


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	if _job:
		_job.cancel()
		_job.wait_for_worker()
		_job = null
	State.finish_operation(_operation_id)
	_operation_id = 0
	var tx := _edit
	_edit = null
	if tx != null:
		State.cancel_edit(tx)
	_release_subscriptions()


func _exit_tree() -> void:
	_last_pick = null
	_hide_footprint()
	visible = false
	if _settings.changed.is_connected(_on_settings_changed):
		_settings.changed.disconnect(_on_settings_changed)
	_disconnect_state_subscriptions()


func _release_subscriptions() -> void:
	if is_inside_tree() or _edit != null or _job != null:
		return
	if State.edit_context_changing.is_connected(_cancel_edit):
		State.edit_context_changing.disconnect(_cancel_edit)
	if State.history_changed.is_connected(_on_history_changed):
		State.history_changed.disconnect(_on_history_changed)
	_disconnect_state_subscriptions()


func _disconnect_state_subscriptions() -> void:
	if State.document_changed.is_connected(_on_document_changed):
		State.document_changed.disconnect(_on_document_changed)


func _on_settings_changed() -> void:
	if _edit == null:
		_update_visual(_last_pick)


func _on_document_changed() -> void:
	if _edit != null:
		_cancel_edit()
	_last_pick = null
	_hide_footprint()


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event.is_action_pressed("ui_cancel") and _edit != null:
		_cancel_edit()
		return true
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return false
		if button.pressed:
			_press(pos)
		elif _edit != null:
			_release()
		return true
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if motion.button_mask & MOUSE_BUTTON_MASK_LEFT:
			if _edit != null:
				_drag_pointer(pos)
			return true
		if motion.button_mask == 0:
			if _edit != null:
				_release()
			_hover(pos)
			return true
		return false
	return false


func _press(pos: Vector2) -> void:
	if _edit != null:
		return
	var ray := _ray(pos)
	if ray[1] == Vector3.ZERO:
		return
	var pick := VoxelPicking.start_pick(ray[0], ray[1], State.get_current_voxel_frame(), _forward(), State.slice_enabled)
	if pick.hit == VoxelPicking.NONE:
		return
	_stroke_face = _face_axis(pick)
	_stroke_touch = _face_touch(ray[0], ray[1], pick)
	_capture_view()
	if open_stroke() == null:
		return
	_stroke_id += 1
	_stroke_tx = _edit
	_stroke_size = _settings.size
	_stroke_falloff = _settings.falloff
	_stroke_context = _stroke_tx.edit_context
	_stroke_selection = _stroke_context.selection
	_stroke_track_selection = not _stroke_selection.is_empty()
	_write_context = _stroke_context.duplicate()
	_write_context.selection = {}
	_source_document = State.document
	_source_frame = State.get_current_voxel_frame()
	_baseline = _source_frame.copy_frame()
	_anchor = pick.hit
	_drag = pick.hit
	_drag_point = Vector3(pick.hit)
	_pending_target = null
	_end_requested = false
	_published.clear()
	var plane := StrokePlane.new()
	plane.axis = VoxelPicking.view_axis(_view_forward)
	plane.cell_index = roundi(Vector3(pick.hit)[plane.axis])
	plane.point = Vector3(pick.hit)
	plane.normal = _view_forward
	_plane = plane
	_stroke_active = true
	_last_target = pick.hit
	if not _capture_gesture(pick):
		_cancel_edit()
		return
	_last_pick = pick
	_update_visual(pick)


func _drag_pointer(pos: Vector2) -> void:
	var ray := _ray(pos)
	if ray[1] == Vector3.ZERO:
		return
	var point = _view_point(ray[0], ray[1])
	if point == null:
		return
	_drag_point = point
	var target := _view_cell(point)
	if target == _drag:
		return
	_drag = target
	_drag_visual(target)
	if _job != null:
		_pending_target = target
		return
	_run_job(target)


func _release() -> void:
	if _edit == null:
		return
	_end_requested = true
	_stroke_active = false
	_settle_release()


func finish_on_switch() -> void:
	if _edit == null:
		return
	_release()


func _end() -> void:
	_release()


func _settle_release() -> void:
	if not _end_requested or _job != null:
		return
	_finish_stroke()


func _capture_gesture(_pick: PickResult) -> bool:
	return false


func _make_job(_target: Vector3i) -> DeformJob:
	return null


func _publish_selection(job: DeformJob) -> void:
	if job.destination_selection.is_empty():
		return
	var cells := {}
	for cell: Vector3i in _stroke_selection:
		if not job.removed_cells.has(cell):
			cells[cell] = true
	for cell: Vector3i in job.destination_selection:
		cells[cell] = true
	State.selection.restore(cells)
	State.selection_changed.emit()


func _context_for_job() -> VoxelFrame.EditContext:
	return _write_context


func _run_job(target: Vector3i) -> void:
	if _baseline == null:
		return
	var job := _make_job(target)
	if job == null:
		_publish_baseline()
		_settle_release()
		return
	job.stroke_id = _stroke_id
	job.edited_frame = VoxelFrame.job_frame(_baseline)
	job.context = _context_for_job()
	_job = job
	if job.estimated_work() <= INLINE_EDIT_LIMIT:
		job.run()
		_finish_job(job)
	else:
		_operation_id = State.begin_operation(_operation_label(), job.estimated_work(), true, self, _cancel_edit)
		job.operation_id = _operation_id
		_run_job_worker(job)


func _run_job_worker(job: DeformJob) -> void:
	await State.run_edit_job(job, job.operation_id, _operation_label())
	if _job != job:
		return
	_finish_job(job)


func _finish_job(job: DeformJob) -> void:
	if _job == job:
		_job = null
	if _operation_id == job.operation_id:
		_operation_id = 0
	State.finish_operation(job.operation_id)
	if job.stroke_id != _stroke_id:
		_replay_pending()
		_settle_release()
		return
	if not _job_is_current(job):
		_release_subscriptions()
		return
	var locations: Array[Vector3i] = []
	for location in _published:
		locations.append(location)
	for location in job.changed_chunks:
		if not _published.has(location):
			_published[location] = true
			locations.append(location)
	_source_frame.apply_published(locations, job.edited_frame)
	State.document._bounds_dirty = true
	if not locations.is_empty():
		State.chunks_changed.emit(State.active_layer_index, State.current_frame, locations)
	if _stroke_track_selection:
		_publish_selection(job)
	if _pending_target != null:
		var pending: Vector3i = _pending_target
		_pending_target = null
		_run_job(pending)
	else:
		_settle_release()
	_release_subscriptions()


func _replay_pending() -> void:
	if _pending_target == null or _edit == null or _edit != _stroke_tx:
		return
	var queued: Vector3i = _pending_target
	_pending_target = null
	_run_job(queued)


func _publish_baseline() -> void:
	if _baseline == null or _edit == null or _edit != _stroke_tx:
		return
	if State.document != _source_document or State.get_current_voxel_frame() != _source_frame:
		return
	var locations: Array[Vector3i] = []
	for location in _published:
		locations.append(location)
	_published.clear()
	_source_frame.apply_published(locations, _baseline)
	State.document._bounds_dirty = true
	if not locations.is_empty():
		State.chunks_changed.emit(State.active_layer_index, State.current_frame, locations)
	if _stroke_track_selection:
		State.selection.restore(_stroke_selection)
		State.selection_changed.emit()


func _job_is_current(job: DeformJob) -> bool:
	if job.stroke_id != _stroke_id or not job.checkpoint(0):
		return false
	if _edit == null or _edit != _stroke_tx:
		return false
	return State.document == _source_document and State.get_current_voxel_frame() == _source_frame


func _finish_stroke() -> void:
	if _edit == null or _edit != _stroke_tx:
		return
	_end_requested = false
	var action := _action_name()
	_clear_state()
	close_stroke(action)


func _clear_state() -> void:
	_published.clear()
	_baseline = null
	_anchor = VoxelPicking.NONE
	_drag = VoxelPicking.NONE
	_pending_target = null
	_stroke_context = null
	_write_context = null
	_stroke_selection = {}
	_stroke_track_selection = false
	_stroke_tx = null
	_source_document = null
	_source_frame = null
	_stroke_active = false
	_plane = null
	_last_target = VoxelPicking.NONE
	_last_pick = null
	_hide_footprint()
	visible = false


func _cancel_edit() -> void:
	if _job:
		_job.cancel()
	_end_requested = false
	_clear_state()
	State.finish_operation(_operation_id)
	_operation_id = 0
	abort_stroke()
	_release_subscriptions()


func _on_history_changed() -> void:
	if _edit != null:
		_cancel_edit()


func _capture_view() -> void:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		_view_forward = Vector3.FORWARD
		_view_right = Vector3.RIGHT
		_view_up = Vector3.UP
		return
	var basis := camera.global_transform.basis
	_view_right = basis.x.normalized()
	_view_up = basis.y.normalized()
	_view_forward = -basis.z.normalized()


func _view_point(origin: Vector3, dir: Vector3) -> Variant:
	if _plane == null:
		return null
	var denom := dir.dot(_view_forward)
	if absf(denom) < 1e-8:
		return null
	var t: float = (Vector3(_anchor) - origin).dot(_view_forward) / denom
	if t <= 0.0:
		return null
	return origin + dir * t


func _view_cell(point: Vector3) -> Vector3i:
	return Vector3i(roundi(point.x), roundi(point.y), roundi(point.z))


func _hover(pos: Vector2) -> void:
	var ray := _ray(pos)
	if ray[1] == Vector3.ZERO:
		return
	var pick := VoxelPicking.start_pick(ray[0], ray[1], State.get_current_voxel_frame(), _forward(), State.slice_enabled)
	_hover_face = _face_axis(pick)
	_hover_touch = _face_touch(ray[0], ray[1], pick)
	_last_pick = pick
	_update_visual(pick)


func _face_axis(pick: PickResult) -> int:
	if pick == null:
		return -1
	for axis in 3:
		if pick.entry[axis] != 0:
			return axis
	return -1


func _face_point(origin: Vector3, dir: Vector3, pick: PickResult) -> Vector3:
	var axis := _face_axis(pick)
	if axis < 0 or pick.hit == VoxelPicking.NONE or absf(dir[axis]) < 1e-8:
		return Vector3.ZERO
	var center := Vector3(pick.hit)
	var plane: float = center[axis] + (0.5 if pick.entry[axis] > 0 else -0.5)
	var t: float = (plane - origin[axis]) / dir[axis]
	if t <= 0.0:
		return Vector3.ZERO
	return origin + dir * t


func _face_touch(origin: Vector3, dir: Vector3, pick: PickResult) -> Vector2:
	var axis := _face_axis(pick)
	var point := _face_point(origin, dir, pick)
	if axis < 0 or point == Vector3.ZERO:
		return Vector2.ZERO
	var center := Vector3(pick.hit)
	var axis_u := (axis + 1) % 3
	var axis_v := (axis + 2) % 3
	return Vector2(
		clampf(point[axis_u] - center[axis_u], -0.5, 0.5),
		clampf(point[axis_v] - center[axis_v], -0.5, 0.5)
	)


func _drag_visual(target: Vector3i) -> void:
	if _last_pick == null:
		return
	var pick := PickResult.new()
	pick.target = target
	pick.hit = target
	pick.entry = _last_pick.entry
	pick.plane = _plane
	_last_pick = pick
	_update_visual(pick)


func _update_visual(pick: PickResult) -> void:
	if pick == null or pick.hit == VoxelPicking.NONE:
		_hide_footprint()
		visible = false
		return
	_pose_footprint(pick)
	_pose_bone(pick)


func _pose_bone(_pick: PickResult) -> void:
	pass


func _setup_footprint() -> void:
	_footprint = get_node_or_null("Footprint") as MeshInstance3D
	if _footprint == null:
		return
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.WHITE
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_footprint.material_override = material
	_footprint.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_footprint.visible = false


func _pose_footprint(pick: PickResult) -> void:
	if _footprint == null or pick.hit == VoxelPicking.NONE:
		return
	var reach := _cursor_reach()
	_footprint.mesh = _cursor_mesh(reach)
	var right := Vector3.RIGHT
	var up := Vector3.UP
	if is_inside_tree():
		var camera := get_viewport().get_camera_3d()
		if camera != null:
			right = camera.global_transform.basis.x.normalized()
			up = camera.global_transform.basis.y.normalized()
	var basis := Basis(right, up, right.cross(up))
	_footprint.global_transform = Transform3D(basis, Vector3(pick.hit))
	visible = true
	_footprint.visible = true


func _cursor_forward() -> Vector3:
	if _edit != null:
		return _view_forward
	if is_inside_tree():
		var camera := get_viewport().get_camera_3d()
		if camera != null:
			return -camera.global_transform.basis.z.normalized()
	return _view_forward


func _cursor_reach() -> float:
	return float(clampi(_settings.size, 1, 32)) * 0.5


func _cursor_mesh(reach: float) -> ArrayMesh:
	var mesh: ArrayMesh = _footprint_meshes.get(reach)
	if mesh != null:
		return mesh
	var size := clampi(roundi(reach * 2.0), 1, 64)
	var vertices := BrushSize.disk_outline(size)
	if size % 2 == 0:
		var shift := Vector3(0.5, 0.5, 0.0)
		for index in vertices.size():
			vertices[index] += shift
	mesh = VoxelLineMesh.build(vertices)
	_footprint_meshes[reach] = mesh
	return mesh


func _hide_footprint() -> void:
	if _footprint != null:
		_footprint.visible = false
