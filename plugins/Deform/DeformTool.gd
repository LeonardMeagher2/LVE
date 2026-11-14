extends VoxelTool

## Shared base for the deform tools: Grab and Pose.
##
## Both tools capture one baseline snapshot at the press and recompute their
## result from that baseline for every accepted pointer position. The newest
## position wins, so a drag never accumulates rounding error. A large drag runs
## on the worker pool and only the newest position waits for the running job. A
## release commits the whole gesture as one history action. Escape, an edit
## context change, and a history change roll it back.
##
## The cursor is one white circle in the view plane. It shows the reach of the
## tool and predicts no voxel. A tool that also draws a bone poses it from the
## press onward, like Blender's Pose brush.

const BrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")
const VoxelLineMesh := preload("res://Globals/Rendering/VoxelLineMesh.gd")

## The estimated work above which a drag runs on the worker pool.
const INLINE_EDIT_LIMIT := 4096


## One cancellable deform drag.
##
## The job starts from the baseline snapshot and writes its whole result into one
## frame copy. A subclass supplies the changes in
## [method compute_changes]. [method VoxelFrame.EditJob.run] is the worker body.
##
## The job never sets [member VoxelFrame.EditJob.edit_context]: a write filter
## would apply the symmetry and the selection a second time. The changes already
## respect both.
class DeformJob extends VoxelFrame.EditJob:
	## The stroke id that the job belongs to.
	var stroke_id := 0
	## The operation id that the job belongs to.
	var operation_id := 0
	## The frame copy that the drag writes. It starts as the baseline copy.
	var edited_frame: VoxelFrame
	## The frozen edit context that limits the slice and the document size.
	var context: VoxelFrame.EditContext
	## The moved set at its destinations, keyed by cell. The tool restores the
	## selection from it, so the selection follows a moved cell.
	var destination_selection := {}
	## The cells that the drag emptied. A selected cell that leaves the world also
	## leaves the selection.
	var removed_cells := {}
	## The chunk locations that the drag changed.
	var changed_chunks: Array[Vector3i] = []

	## Writes the drag result. This is the worker body.
	func run() -> void:
		var changes := compute_changes()
		if changes.is_empty() or not checkpoint(0):
			return
		stage("Applying deform", changes.size())
		changed_chunks = apply_cells(edited_frame, changes)

	## Returns the cells to write, keyed by cell. A subclass overrides it.
	func compute_changes() -> Dictionary:
		return {}

	## Returns the estimated work of the drag, for the worker decision.
	func estimated_work() -> int:
		return 0

	## Returns [code]true[/code] when the frozen context allows a write to
	## [param cell]. It covers the slice, the document size, and the selection.
	func allows(cell: Vector3i) -> bool:
		return context == null or context.allows(cell)


var _settings: DeformToolSettings = preload("./settings.tres")

var _last_pick: PickResult
var _footprint: MeshInstance3D
var _footprint_meshes := {}

# The stroke state.
var _stroke_id := 0
var _stroke_tx: VoxelEditTransaction
var _stroke_size := 4
var _stroke_falloff := 0.5
var _stroke_context: VoxelFrame.EditContext
## The same context without the selection. A moved cell may land outside the
## selection, so only the slice, the size, and the symmetry limit the writes.
var _write_context: VoxelFrame.EditContext
var _stroke_selection := {}
## Whether the selection follows the moved cells. A selection that opened the
## stroke stays the moved set, like the transform tools.
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

# The captured view basis of the press. A camera change during the drag must not
# move the plane, and the screen angle of a pose keeps the basis the user saw.
var _view_forward := Vector3.FORWARD
var _view_right := Vector3.RIGHT
var _view_up := Vector3.UP


## Returns the history action name of one completed gesture.
func _action_name() -> String:
	return "Deform"


## Returns the artist-facing operation label of one worker drag.
func _operation_label() -> String:
	return "Deforming voxels"


# --- Lifecycle --------------------------------------------------------------


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
	# The cursor follows the size. A drag keeps the size it captured at the press.
	if _edit == null:
		_update_visual(_last_pick)


func _on_document_changed() -> void:
	if _edit != null:
		_cancel_edit()
	_last_pick = null
	_hide_footprint()


# --- Input ------------------------------------------------------------------


## Handles one input event. A press starts a gesture, a drag updates it, and a
## release commits it. Escape rolls the open gesture back.
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
			# A release outside the window sends no button event. A motion with
			# no button ends the gesture the same way a release does.
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
	# The plane faces the viewer and keeps the exact camera forward, so the drag
	# maps onto it without a cardinal snap.
	var plane := StrokePlane.new()
	plane.axis = VoxelPicking.view_axis(_view_forward)
	plane.idx = roundi(Vector3(pick.hit)[plane.axis])
	plane.point = Vector3(pick.hit)
	plane.normal = _view_forward
	_plane = plane
	_stroke_active = true
	_last_target = pick.hit
	if not _capture_gesture(pick):
		# Nothing can move, so the gesture never opens a history action.
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


## Ends the gesture like a release when a tool or settings switch detaches it.
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


# --- Gesture hooks ----------------------------------------------------------


## Captures the gesture state of one press. Returns [code]false[/code] when the
## pick has nothing to move, so the stroke is refused.
func _capture_gesture(_pick: PickResult) -> bool:
	return false


## Returns the job of one drag target, or null when the target changes nothing.
func _make_job(_target: Vector3i) -> DeformJob:
	return null


## Moves the selection with the drag. A selected cell that stays keeps its place,
## a cell that the drag empties leaves, and every new cell joins.
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


# --- Drag plumbing ----------------------------------------------------------


## Returns the edit context that one drag job reads.
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
		# A newer stroke owns the tool. Run its queued target when one waits.
		_replay_pending()
		# The newer stroke may already be released while this older job ran. Its
		# release arrived while no job tracked it, so it waits for this point.
		_settle_release()
		return
	if not _job_is_current(job):
		return
	# The drag recomputes from the baseline, so a chunk that moved in an earlier
	# update and not in this one must revert. Publish the union of both updates.
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
		State.chunks_changed.emit(State.current_frame, locations)
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
		State.chunks_changed.emit(State.current_frame, locations)
	# The frame is back at the press state, so the selection must be too. An
	# earlier target published a moved set, and those destination cells no longer
	# exist. Without this restore the next stroke searches an empty selection.
	if _stroke_track_selection:
		State.selection.restore(_stroke_selection)
		State.selection_changed.emit()


func _job_is_current(job: DeformJob) -> bool:
	if job.stroke_id != _stroke_id or not job.checkpoint(0):
		return false
	if _edit == null or _edit != _stroke_tx:
		return false
	return State.document == _source_document and State.get_current_voxel_frame() == _source_frame


# --- Commit and cancel ------------------------------------------------------


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


# --- View plane -------------------------------------------------------------


# Captures the view basis of the press. The plane and the screen angle keep it
# for the whole gesture, so a camera move never changes an accepted drag.
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


# Intersects the captured view plane and returns the world point, or null when
# the ray is parallel to the plane or points away from it.
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


## Returns the cell of one world point on the view plane. A view plane can be
## oblique, so the drag keeps all three rounded components.
func _view_cell(point: Vector3) -> Vector3i:
	return Vector3i(roundi(point.x), roundi(point.y), roundi(point.z))


# --- Hover cursor -----------------------------------------------------------


func _hover(pos: Vector2) -> void:
	var ray := _ray(pos)
	if ray[1] == Vector3.ZERO:
		return
	var pick := VoxelPicking.start_pick(ray[0], ray[1], State.get_current_voxel_frame(), _forward(), State.slice_enabled)
	_last_pick = pick
	_update_visual(pick)


# Poses the cursor for the drag target. The circle follows the pointer, and the
# entry face of the press keeps its normal.
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


## Poses the bone of the gesture. The base tool draws no bone.
func _pose_bone(_pick: PickResult) -> void:
	pass


func _setup_footprint() -> void:
	_footprint = get_node_or_null("Footprint") as MeshInstance3D
	if _footprint == null:
		return
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.WHITE
	# The cursor must stay readable inside geometry, so it skips the depth test.
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_footprint.material_override = material
	_footprint.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_footprint.visible = false


## Shows the cursor circle of the tool, centered on the picked cell.
##
## The circle is the stepped voxel outline and lies in the view plane, so its
## screen size is the reach of the tool and it stays a true circle from every
## view. The mesh depends on the reach only, so a reach builds one mesh and every
## cell reuses it.
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
	# The tool node carries the hide state. A hide sets it false, so a pose must
	# set it true or an invisible parent keeps the cursor off screen forever.
	visible = true
	_footprint.visible = true


## Returns the reach of the cursor circle, in cells: the brush radius. The circle
## is the footprint of the brush, so a size of one is one cell.
func _cursor_reach() -> float:
	return float(clampi(_settings.size, 1, 32)) * 0.5


# Returns the cursor mesh of one reach. The line is the stepped voxel circle, so
# it reads like the brush footprint and not like a smooth drawn circle. The
# vertices lie in the local XY plane, so the node transform carries the view
# orientation.
func _cursor_mesh(reach: float) -> ArrayMesh:
	var mesh: ArrayMesh = _footprint_meshes.get(reach)
	if mesh != null:
		return mesh
	# The helper centers an even size half a cell below zero, so an even outline
	# needs that same half-cell shift back onto the picked cell.
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
