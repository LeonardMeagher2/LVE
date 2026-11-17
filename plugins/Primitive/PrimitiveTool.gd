extends VoxelTool

## One primitive tool.
##
## A drag builds a pending primitive on the pick plane. The third axis starts at
## the pressed cell and grows toward the camera. Release keeps the primitive
## pending and shows six face handles. Drag a handle to change the bounds. Drag
## outside the handles to add another primitive to the same pending request.
## Enter or the option bar commits all pending primitives in one undo action.
## Escape or the option bar cancels them.

const PrimitiveField := preload("res://Globals/State/Tools/PrimitiveField.gd")
const PrimitiveJob := preload("res://Globals/State/Tools/PrimitiveJob.gd")
const HANDLE_RADIUS_PX := 11.0
## The preview work below which the result runs inline. A larger preview uses a
## worker job.
const INLINE_PREVIEW_CELLS := 512

## The primitive kind that this tool builds. The three tool scenes set it.
@export var shape := PrimitiveField.KIND_BOX

var _settings := preload("./PrimitiveSettings.tres")
var _primitives: Array[Dictionary] = []
var _active_index := -1
var _pending_box := AABB()
var _dragging_new := false
var _dragging_handle := false
var _moving := false
var _move_plane: StrokePlane
var _move_grab := Vector3.ZERO
var _move_start_box := AABB()
var _move_offset := Vector3i.ZERO
var _start_cell := VoxelPicking.NONE
var _end_cell := VoxelPicking.NONE
var _depth_side := 1.0
var _shift := false
var _alt := false
var _handle_kind := 0
var _handle_axis := -1
var _handle_side := 0
var _handle_signs := Vector3i.ZERO
var _handle_start_box := AABB()
var _handle_plane := Vector3.ZERO
var _handle_point := Vector3.ZERO
var _active_axis := 1
var _draft_axis := 1
var _last_pick: PickResult
var _preview_job: PrimitiveJob = null
var _preview_request := {}
var _preview_frame: VoxelFrame = null
var _preview_operation_id := 0
var _preview_generation := 0
var _preview_start_frame := -1
var _preview_renderer: VoxelRenderer = null
var _installed_preview_frame: VoxelFrame = null


func _enter_tree() -> void:
	if not State.edit_context_changing.is_connected(cancel_pending):
		State.edit_context_changing.connect(cancel_pending)
	if not State.cells_changed.is_connected(_on_cells_changed):
		State.cells_changed.connect(_on_cells_changed)
	if not State.history_changed.is_connected(_on_history_changed):
		State.history_changed.connect(_on_history_changed)
	if not State.color_changed.is_connected(_on_color_changed):
		State.color_changed.connect(_on_color_changed)
	if not State.material_changed.is_connected(_on_material_changed):
		State.material_changed.connect(_on_material_changed)
	if not State.selection_changed.is_connected(_on_context_aid_changed):
		State.selection_changed.connect(_on_context_aid_changed)
	if not State.symmetry_changed.is_connected(_on_context_aid_changed):
		State.symmetry_changed.connect(_on_context_aid_changed)
	if not State.slice_changed.is_connected(_on_context_aid_changed):
		State.slice_changed.connect(_on_context_aid_changed)
	if not State.floor_plane_changed.is_connected(_on_context_aid_changed):
		State.floor_plane_changed.connect(_on_context_aid_changed)
	if not State.size_changed.is_connected(_on_context_aid_changed):
		State.size_changed.connect(_on_context_aid_changed)
	if not _settings.changed.is_connected(_on_settings_changed):
		_settings.changed.connect(_on_settings_changed)
	if not _settings.commit_requested.is_connected(commit_pending):
		_settings.commit_requested.connect(commit_pending)
	if not _settings.cancel_requested.is_connected(cancel_pending):
		_settings.cancel_requested.connect(cancel_pending)


func _exit_tree() -> void:
	if State.edit_context_changing.is_connected(cancel_pending):
		State.edit_context_changing.disconnect(cancel_pending)
	if State.cells_changed.is_connected(_on_cells_changed):
		State.cells_changed.disconnect(_on_cells_changed)
	if State.history_changed.is_connected(_on_history_changed):
		State.history_changed.disconnect(_on_history_changed)
	if State.color_changed.is_connected(_on_color_changed):
		State.color_changed.disconnect(_on_color_changed)
	if State.material_changed.is_connected(_on_material_changed):
		State.material_changed.disconnect(_on_material_changed)
	if State.selection_changed.is_connected(_on_context_aid_changed):
		State.selection_changed.disconnect(_on_context_aid_changed)
	if State.symmetry_changed.is_connected(_on_context_aid_changed):
		State.symmetry_changed.disconnect(_on_context_aid_changed)
	if State.slice_changed.is_connected(_on_context_aid_changed):
		State.slice_changed.disconnect(_on_context_aid_changed)
	if State.floor_plane_changed.is_connected(_on_context_aid_changed):
		State.floor_plane_changed.disconnect(_on_context_aid_changed)
	if State.size_changed.is_connected(_on_context_aid_changed):
		State.size_changed.disconnect(_on_context_aid_changed)
	if _settings.changed.is_connected(_on_settings_changed):
		_settings.changed.disconnect(_on_settings_changed)
	if _settings.commit_requested.is_connected(commit_pending):
		_settings.commit_requested.disconnect(commit_pending)
	if _settings.cancel_requested.is_connected(cancel_pending):
		_settings.cancel_requested.disconnect(cancel_pending)
	cancel_pending()


func _ready() -> void:
	visible = false
	if has_node("Gizmo"):
		$Gizmo.hide_box()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	_preview_request = {}
	_preview_generation += 1
	var job := _preview_job
	_preview_job = null
	if job != null:
		job.cancel()
		job.wait_for_worker()
	State.finish_operation(_preview_operation_id)
	_preview_operation_id = 0
	_clear_preview_frame()


## Handles one input event.
func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.is_action_pressed("ui_accept") and (_dragging_new or _dragging_handle or not _primitives.is_empty()):
			commit_pending()
			return true
		if key.is_action_pressed("ui_cancel") and (_dragging_new or _dragging_handle or not _primitives.is_empty()):
			cancel_pending()
			return true
		if _dragging_new and (key.keycode == KEY_SHIFT or key.keycode == KEY_ALT):
			_shift = key.shift_pressed or (key.keycode == KEY_SHIFT and key.pressed)
			_alt = key.alt_pressed or (key.keycode == KEY_ALT and key.pressed)
			_refresh_preview()
			return true
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		var ray := _ray(pos)
		if mb.pressed:
			if _dragging_new or _dragging_handle:
				return true
			if not _primitives.is_empty():
				var hit := _handle_at(pos)
				if not hit.is_empty():
					_begin_handle_drag(hit)
				else:
					_begin_move(ray[0], ray[1])
				# A pending primitive must be committed or cancelled before a
				# new drag can start. A press outside the handles moves it.
				return true
			if not _start_new_drag(ray[0], ray[1], mb):
				return false
			return true
		if _dragging_handle:
			_dragging_handle = false
			_handle_kind = 0
			_handle_axis = -1
			_handle_side = 0
			_handle_signs = Vector3i.ZERO
			_refresh_preview()
			return true
		if _moving:
			_moving = false
			_refresh_preview()
			return true
		if _dragging_new:
			var final_pick := _pick_drag(ray[0], ray[1])
			if final_pick.target != VoxelPicking.NONE:
				_end_cell = final_pick.target
			_finish_new_drag()
			return true
		return false
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var ray := _ray(pos)
		if _dragging_handle and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_update_handle(ray[0], ray[1])
			return true
		if _moving and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_update_move(ray[0], ray[1])
			return true
		if _dragging_new and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var pick := _pick_drag(ray[0], ray[1])
			if pick.target != VoxelPicking.NONE:
				_end_cell = pick.target
			_shift = mm.shift_pressed
			_alt = mm.alt_pressed
			_refresh_preview()
			return true
		if (_dragging_handle or _dragging_new or _moving) and mm.button_mask == 0:
			if _dragging_handle:
				_dragging_handle = false
				_handle_kind = 0
				_handle_axis = -1
				_handle_side = 0
				_handle_signs = Vector3i.ZERO
				_refresh_preview()
			elif _moving:
				_moving = false
				_refresh_preview()
			else:
				var pick := _pick_drag(ray[0], ray[1])
				if pick.target != VoxelPicking.NONE:
					_end_cell = pick.target
				_finish_new_drag()
			return true
		if mm.button_mask == 0 and _primitives.is_empty() and not _dragging_new:
			update_visual(_pick_start(ray[0], ray[1]))
			return true
		return false
	return false


## Updates the idle cursor. A pending shape owns the cursor.
func update_visual(pick: PickResult) -> void:
	_last_pick = pick
	if not _primitives.is_empty() or _dragging_new or _dragging_handle or _moving:
		return
	if not has_node("Gizmo"):
		return
	if pick.target == VoxelPicking.NONE:
		$Gizmo.hide_box()
		visible = false
		return
	$Gizmo.show_box(AABB(Vector3(pick.target) - Vector3.ONE * 0.5, Vector3.ONE), -1, 0, false)
	visible = true


## Commits every pending primitive as one undo action.
func commit_pending() -> void:
	if _dragging_new:
		_finish_new_drag()
	if _primitives.is_empty():
		cancel_pending()
		return
	var request := _build_request(false)
	_clear_pending()
	var plugin := get_node_or_null("/root/PrimitivePlugin")
	if plugin == null or not plugin.has_method("build_shape"):
		return
	await plugin.build_shape(request)



## Discards every pending primitive.
func cancel_pending() -> void:
	_cancel_preview_job()
	_primitives.clear()
	_active_index = -1
	_pending_box = AABB()
	_dragging_new = false
	_dragging_handle = false
	_moving = false
	_move_plane = null
	_move_offset = Vector3i.ZERO
	_start_cell = VoxelPicking.NONE
	_end_cell = VoxelPicking.NONE
	_plane = null
	_shift = false
	_alt = false
	_handle_kind = 0
	_handle_axis = -1
	_handle_side = 0
	_handle_signs = Vector3i.ZERO
	_active_axis = 1
	_draft_axis = 1
	_settings.editing = false
	visible = false
	if has_node("Gizmo"):
		$Gizmo.hide_box()


## Commits a pending primitive on a tool or shape switch.
func finish_on_switch() -> void:
	commit_pending()


func _start_new_drag(origin: Vector3, dir: Vector3, event: InputEventMouseButton) -> bool:
	var pick := _pick_start(origin, dir)
	if pick.target == VoxelPicking.NONE:
		return false
	_start_cell = pick.target
	_end_cell = pick.target
	_plane = pick.plane
	_depth_side = signf(pick.plane.point[pick.plane.axis] - float(_start_cell[pick.plane.axis]))
	if _depth_side == 0.0:
		_depth_side = 1.0
	_shift = event.shift_pressed
	_alt = event.alt_pressed
	_draft_axis = pick.plane.axis
	_dragging_new = true
	_refresh_preview()
	return true


func _finish_new_drag() -> void:
	if not _dragging_new:
		return
	var box := _draft_box()
	_pending_box = box
	_active_axis = _draft_axis
	_primitives.append(_build_primitive(box, _active_axis))
	_active_index = _primitives.size() - 1
	_dragging_new = false
	_start_cell = VoxelPicking.NONE
	_end_cell = VoxelPicking.NONE
	_settings.editing = true
	_refresh_preview()


func _refresh_preview(cancel_running := false) -> void:
	# The handles follow the shape immediately. The result frame follows when the
	# worker finishes.
	_refresh_gizmo()
	visible = not _primitives.is_empty()
	var request := _build_request(true)
	_preview_request = request
	_preview_frame = State.get_current_voxel_frame()
	if _preview_job != null:
		# A settings or context change must not wait behind a stale result. The
		# runner starts the newest request after the cancelled job joins.
		if cancel_running:
			_preview_job.cancel()
		return
	# A fast mouse sends several events in one frame. One preview per frame
	# keeps the newest request without copying the frame for every event.
	var frame_id := Engine.get_process_frames()
	if frame_id == _preview_start_frame:
		return
	_preview_start_frame = frame_id
	_run_preview()


func _process(_delta: float) -> void:
	if _preview_job != null or _preview_request.is_empty():
		return
	_preview_start_frame = Engine.get_process_frames()
	_run_preview()


func _run_preview() -> void:
	while not _preview_request.is_empty():
		var request: Dictionary = _preview_request
		_preview_request = {}
		var frame := _preview_frame
		_preview_frame = null
		if frame == null:
			continue
		var job := PrimitiveJob.new()
		job.request = request
		job.edit_context = State.drawing_context()
		# A preview job can outlive the next edit. A frozen copy keeps the worker
		# from writing the live frame.
		job.edited_frame = frame.copy_frame()
		_preview_job = job
		var generation := _preview_generation
		var work := PrimitiveField.estimated_cells(request)
		if work <= INLINE_PREVIEW_CELLS:
			job.run()
		else:
			_preview_operation_id = State.begin_operation("Preparing primitive preview", work, false, self, job.cancel)
			await State.run_edit_job(job, _preview_operation_id, "Primitive preview")
			State.finish_operation(_preview_operation_id)
			_preview_operation_id = 0
		if _preview_job != job:
			return
		_preview_job = null
		if generation != _preview_generation:
			continue
		if job.checkpoint(0):
			_install_preview_frame(job.edited_frame)


func _install_preview_frame(frame: VoxelFrame) -> void:
	var renderer := _preview_renderer_node()
	if renderer == null:
		return
	_preview_renderer = renderer
	_installed_preview_frame = frame
	renderer.source_frame = frame


func _preview_renderer_node() -> VoxelRenderer:
	if State.context == null or State.context.viewport_scene == null:
		return null
	return State.context.viewport_scene.get_node_or_null("VoxelRenderer") as VoxelRenderer


func _clear_preview_frame() -> void:
	if is_instance_valid(_preview_renderer) and _preview_renderer.source_frame == _installed_preview_frame:
		_preview_renderer.source_frame = null
	_preview_renderer = null
	_installed_preview_frame = null


func _cancel_preview_job() -> void:
	_preview_request = {}
	_preview_generation += 1
	if _preview_job != null:
		_preview_job.cancel()
	State.finish_operation(_preview_operation_id)
	_preview_operation_id = 0
	_clear_preview_frame()


func _refresh_gizmo() -> void:
	if not has_node("Gizmo"):
		return
	if _primitives.is_empty() or _dragging_new:
		$Gizmo.hide_box()
		return
	$Gizmo.show_box(_pending_box, _handle_axis, _handle_side, true)


func _build_request(include_draft: bool) -> Dictionary:
	var primitives: Array = _primitives.duplicate()
	if include_draft and _dragging_new:
		primitives.append(_build_primitive(_draft_box(), _draft_axis))
	var request := {
		"primitives": primitives,
		"op": int(_settings.op),
		"smooth": 0.0,
		"shell": float(_settings.shell),
		"step": 1,
		"material": State.current_material.duplicate(),
		"label": "Build Shape",
	}
	# The setting is a fraction of the largest blend that the shape allows. The
	# job takes cells, so an MCP request and a tool request share one unit.
	request["smooth"] = float(_settings.smooth) * PrimitiveField.smallest_extent(request) * 0.5
	return request


func _build_primitive(box: AABB, axis := -1) -> Dictionary:
	var center := (box.position + box.end) * 0.5
	var half := Vector3(absf(box.size.x), absf(box.size.y), absf(box.size.z)) * 0.5
	match shape:
		PrimitiveField.KIND_ELLIPSOID:
			return {"kind": PrimitiveField.KIND_ELLIPSOID, "center": center, "radii": half}
		PrimitiveField.KIND_CONE:
			return _cone_primitive(box, axis if axis >= 0 else _active_axis)
		_:
			return {
				"kind": PrimitiveField.KIND_BOX,
				"center": center,
				"half_size": half,
				"roundness": _settings.roundness,
			}


func _draft_box() -> AABB:
	var plane_axis := _plane.axis
	var first_axis := 0 if plane_axis != 0 else 1
	var second_axis := 2 if plane_axis != 2 else 1
	var start := Vector3(_start_cell)
	var finish := Vector3(_end_cell)
	var level := float(_start_cell[plane_axis])
	start[plane_axis] = level
	finish[plane_axis] = level
	var low := Vector3.ZERO
	var high := Vector3.ZERO
	for axis in 3:
		if axis == plane_axis:
			continue
		if _alt:
			var half := absf(finish[axis] - start[axis]) + 0.5
			low[axis] = start[axis] - half
			high[axis] = start[axis] + half
		else:
			low[axis] = minf(start[axis], finish[axis]) - 0.5
			high[axis] = maxf(start[axis], finish[axis]) + 0.5
	if _shift:
		var half_first := (high[first_axis] - low[first_axis]) * 0.5
		var half_second := (high[second_axis] - low[second_axis]) * 0.5
		var half := maxf(half_first, half_second)
		var center_first := (low[first_axis] + high[first_axis]) * 0.5
		var center_second := (low[second_axis] + high[second_axis]) * 0.5
		low[first_axis] = center_first - half
		high[first_axis] = center_first + half
		low[second_axis] = center_second - half
		high[second_axis] = center_second + half
	var depth := minf(high[first_axis] - low[first_axis], high[second_axis] - low[second_axis])
	depth = maxf(depth, 1.0)
	# Start at the near face of the pressed cell, not at its center. A four-cell
	# drag then covers four cell centers, and the first layer is the pressed
	# cell rather than the cell in front of it.
	var depth_start := level - 0.5 * _depth_side
	var depth_end := depth_start + depth * _depth_side
	low[plane_axis] = minf(depth_start, depth_end)
	high[plane_axis] = maxf(depth_start, depth_end)
	return AABB(low, high - low)


func _cone_primitive(box: AABB, axis: int) -> Dictionary:
	var extent := box.size
	var first_axis := (axis + 1) % 3
	var second_axis := (axis + 2) % 3
	var radius := minf(absf(extent[first_axis]), absf(extent[second_axis])) * 0.5
	radius = maxf(radius, 0.5)
	var narrow := clampf(_settings.second_radius, 0.0, 1.0) * radius
	var center := (box.position + box.end) * 0.5
	var direction := signf(box.end[axis] - box.position[axis])
	if direction == 0.0:
		direction = 1.0
	var a := center
	var b := center
	a[axis] = box.position[axis] + radius * _settings.roundness * direction
	b[axis] = box.end[axis] - narrow * _settings.roundness * direction
	# A zero top radius is a point. Put that point on the center of the last
	# cell on the end side, or the cell grid can miss the tip and leave a hole.
	if narrow <= 0.0:
		if direction > 0.0:
			b[axis] = floorf(box.end[axis])
		else:
			b[axis] = ceilf(box.end[axis])
	return {
		"kind": PrimitiveField.KIND_CONE,
		"a": a,
		"b": b,
		"r1": radius,
		"r2": narrow,
		"roundness": _settings.roundness,
	}


func _handle_at(pos: Vector2) -> Dictionary:
	if not has_node("Gizmo"):
		return {}
	var camera := get_viewport().get_camera_3d() if get_viewport() != null else null
	if camera == null:
		return {}
	var forward := -camera.global_transform.basis.z
	var best := {}
	var best_distance := HANDLE_RADIUS_PX
	for value in $Gizmo.handles():
		var hit: Dictionary = value
		var axis: int = hit["axis"]
		# A face handle that points at the camera cannot change its own axis.
		# Skip it, so a click at the shape center can still move the shape.
		if int(hit.get("kind", 0)) == 0 and absf(forward[axis]) > 0.9:
			continue
		var world: Vector3 = hit["position"]
		if camera.is_position_behind(world):
			continue
		var screen := camera.unproject_position(world)
		var distance := screen.distance_to(pos)
		if distance <= best_distance:
			best_distance = distance
			best = hit
	return best


func _begin_move(origin: Vector3, dir: Vector3) -> void:
	if _primitives.is_empty() or _active_index < 0:
		return
	_move_plane = VoxelPicking.view_plane_through(_pending_box.get_center(), _forward())
	_move_grab = _plane_point(origin, dir, _move_plane)
	if _move_grab == Vector3.INF:
		return
	_move_start_box = _pending_box
	_move_offset = Vector3i.ZERO
	_moving = true


func _update_move(origin: Vector3, dir: Vector3) -> void:
	if not _moving or _active_index < 0 or _active_index >= _primitives.size():
		return
	var point := _plane_point(origin, dir, _move_plane)
	if point == Vector3.INF:
		return
	var offset := Vector3i(
		roundi(point.x - _move_grab.x),
		roundi(point.y - _move_grab.y),
		roundi(point.z - _move_grab.z)
	)
	if offset == _move_offset:
		return
	_move_offset = offset
	_pending_box = AABB(_move_start_box.position + Vector3(offset), _move_start_box.size)
	_primitives[_active_index] = _build_primitive(_pending_box, _active_axis)
	_refresh_preview()


func _plane_point(origin: Vector3, dir: Vector3, plane: StrokePlane) -> Vector3:
	if plane == null:
		return Vector3.INF
	var denominator := dir.dot(plane.normal)
	if absf(denominator) < 1e-8:
		return Vector3.INF
	var amount := (plane.point - origin).dot(plane.normal) / denominator
	if amount <= 0.0:
		return Vector3.INF
	return origin + dir * amount


func _begin_handle_drag(hit: Dictionary) -> void:
	_dragging_handle = true
	_handle_kind = int(hit.get("kind", 0))
	_handle_axis = int(hit.get("axis", -1))
	_handle_side = int(hit.get("side", 0))
	_handle_signs = hit.get("signs", Vector3i.ZERO)
	_handle_start_box = _pending_box
	var camera := get_viewport().get_camera_3d() if get_viewport() != null else null
	_handle_plane = -camera.global_transform.basis.z if camera != null else Vector3.BACK
	_handle_point = hit["position"]
	_refresh_gizmo()


func _update_handle(origin: Vector3, dir: Vector3) -> void:
	if _active_index < 0 or _active_index >= _primitives.size():
		return
	var denominator := dir.dot(_handle_plane)
	if absf(denominator) < 1e-8:
		return
	var amount := (_handle_point - origin).dot(_handle_plane) / denominator
	if amount <= 0.0:
		return
	var point := origin + dir * amount
	if _handle_kind == 1:
		_update_corner(point)
		return
	if _handle_axis < 0:
		return
	var value := snappedf(point[_handle_axis], 0.5)
	var low := _pending_box.position
	var high := _pending_box.end
	# Let a handle cross the opposite bound. The box size can become negative,
	# which flips a cone end. A box or an ellipsoid is symmetric, so it uses the
	# absolute extent.
	if _handle_side < 0:
		low[_handle_axis] = value
	else:
		high[_handle_axis] = value
	_pending_box = AABB(low, high - low)
	_primitives[_active_index] = _build_primitive(_pending_box)
	_refresh_preview()


func _update_corner(point: Vector3) -> void:
	var delta := point - _handle_point
	var low := _handle_start_box.position
	var high := _handle_start_box.end
	for axis in 3:
		var shift := snappedf(delta[axis], 0.5)
		if _handle_signs[axis] < 0:
			low[axis] += shift
		else:
			high[axis] += shift
	_pending_box = AABB(low, high - low)
	_primitives[_active_index] = _build_primitive(_pending_box)
	_refresh_preview()


func _clear_pending() -> void:
	_cancel_preview_job()
	_primitives.clear()
	_active_index = -1
	_pending_box = AABB()
	_dragging_new = false
	_dragging_handle = false
	_moving = false
	_move_plane = null
	_move_offset = Vector3i.ZERO
	_start_cell = VoxelPicking.NONE
	_end_cell = VoxelPicking.NONE
	_plane = null
	_handle_kind = 0
	_handle_axis = -1
	_handle_side = 0
	_handle_signs = Vector3i.ZERO
	_active_axis = 1
	_draft_axis = 1
	_settings.editing = false
	visible = false
	if has_node("Gizmo"):
		$Gizmo.hide_box()


func _on_cells_changed(_frame: int, _cells: Array[Vector3i]) -> void:
	if not _primitives.is_empty() or _dragging_new:
		cancel_pending()


func _on_history_changed() -> void:
	if not _primitives.is_empty() or _dragging_new:
		cancel_pending()


func _on_settings_changed() -> void:
	if _active_index >= 0 and _active_index < _primitives.size() and shape != PrimitiveField.KIND_ELLIPSOID:
		_primitives[_active_index] = _build_primitive(_pending_box, _active_axis)
	if not _primitives.is_empty() or _dragging_new:
		_refresh_preview(true)


func _on_color_changed(_color: Color) -> void:
	if not _primitives.is_empty() or _dragging_new:
		_refresh_preview(true)


func _on_material_changed() -> void:
	if not _primitives.is_empty() or _dragging_new:
		_refresh_preview(true)


func _on_context_aid_changed() -> void:
	if not _primitives.is_empty() or _dragging_new:
		_refresh_preview(true)

