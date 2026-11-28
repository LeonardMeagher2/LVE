extends VoxelTool


const INLINE_EDIT_LIMIT := 4096


const SURFACE_ONLY_WORK_FACTOR := 4
const StampSettings := preload("./StampToolSettings.gd")
const StampPattern := preload("./StampPatternJob.gd")
const DitherMask := preload("res://Globals/State/Tools/DitherMask.gd")


const Profile := preload("res://Globals/State/Tools/StrokeProfile.gd")


var _settings: StampSettings
var _filter := PixelPerfectStroke.new()
var _source_document: VoxelDocument
var _source_frame: VoxelFrame
var _end_requested := false
var _pending_centers: Array[Vector3i] = []
var _stroke_pattern := {}
var _stroke_offsets: Array = []


var _stroke_last_center := Vector3i.MAX
var _stroke_material_pattern := {}
var _stroke_diameter := 1
var _stroke_shape := 0
var _stroke_pattern_size := 1
var _stroke_color := Color.WHITE
var _stroke_material := VoxelFrame.material(Color.WHITE)

var _stroke_existing_only := false

var _stroke_erases := false
var _edit_context: VoxelFrame.EditContext
var _job: BrushJob
var _operation_id := 0
var _cursor_axis := -1
var _last_pick: PickResult
var _hover_job
var _hover_operation_id := 0


class BrushJob extends VoxelFrame.EditJob:

	var centers: Array[Vector3i] = []


	var centers_are_final := false

	var pattern := {}


	var offsets: Array = []


	var dither_density := -1.0

	var dither_origin := Vector3i.ZERO


	var previous_center := Vector3i.MAX

	var material_pattern := {}

	var replace_materials := false

	var diameter := 1

	var shape := 0

	var material := VoxelFrame.material(Color.WHITE)

	var paint_existing := false

	var surface_only := false

	var erase_existing := false

	var edited_frame: VoxelFrame

	var cell_materials := {}

	var changed_chunks: Array[Vector3i] = []

	var revision := 0


	func run() -> void:
		if pattern.is_empty() and shape != StampSettings.BrushShape.STAMP:
			pattern = StampPattern.build_pattern(diameter, shape, self)
		if offsets.size() != pattern.size():

			offsets = pattern.keys()
		if not checkpoint(0):
			return
		stage("Preparing brush", centers.size() * offsets.size())

		var uniform := not replace_materials and shape != StampSettings.BrushShape.STAMP
		var uniform_material := VoxelFrame.material(Color.TRANSPARENT) if erase_existing else material


		var existing_only := paint_existing


		var constant_material := erase_existing or uniform
		if constant_material:


			applied_uniform = uniform_material
		var dither_enabled := dither_density >= 0.0
		var covered := {}
		var previous := previous_center
		var completed := 0
		var until_checkpoint := 4096
		for center in centers:
			var use: Array = offsets
			if dither_enabled:


				use = DitherMask.select_offsets(offsets, center, dither_density, edited_frame, dither_origin)
			elif constant_material and previous != Vector3i.MAX:
				var delta: Vector3i = center - previous
				if delta == Vector3i.ZERO:

					use = []
				else:
					if not covered.has(delta):
						covered[delta] = _uncovered_offsets(offsets, pattern, delta)
					use = covered[delta]
			previous = center
			for offset: Vector3i in use:
				var cell_position := center + offset
				if not existing_only or edited_frame.has(cell_position):
					if erase_existing or uniform:
						cell_materials[cell_position] = uniform_material
					else:
						var source_color: Color = pattern[offset]
						var fallback := material if source_color == Color.TRANSPARENT and not replace_materials else VoxelFrame.material(source_color)
						cell_materials[cell_position] = material_pattern.get(offset, fallback)
				completed += 1
				until_checkpoint -= 1
				if until_checkpoint == 0:
					until_checkpoint = 4096
					if not checkpoint(completed):
						return
		stage("Applying brush", cell_materials.size())
		if centers_are_final:


			applied_cells = cell_materials
			if surface_only and edit_context != null:
				applied_cells = edit_context.expand(applied_cells, edited_frame, paint_existing, null, self, true)
			if checkpoint(0):
				changed_chunks = edited_frame.set_cells(applied_cells, self, applied_uniform)
			return
		changed_chunks = apply_cells(edited_frame, cell_materials, paint_existing, null, surface_only)


	static func _uncovered_offsets(offsets: Array, pattern: Dictionary, delta: Vector3i) -> Array:
		var kept: Array = []
		for offset: Vector3i in offsets:
			if not pattern.has(offset + delta):
				kept.append(offset)
		return kept


func _pick_adds() -> bool:
	return true


func _requires_hit() -> bool:
	return false


func _erases() -> bool:
	return false


func _paints_existing() -> bool:
	return false


func _enter_tree() -> void:


	if not tree_exited.is_connected(_release_context_subscriptions):
		tree_exited.connect(_release_context_subscriptions)
	if not State.edit_context_changing.is_connected(_cancel_edit):
		State.edit_context_changing.connect(_cancel_edit)
	if not State.history_changed.is_connected(_on_history_changed):
		State.history_changed.connect(_on_history_changed)
	if not _settings.changed.is_connected(_on_settings_changed):
		_settings.changed.connect(_on_settings_changed)


func _ready() -> void:
	State.color_changed.connect(_on_color_changed)
	_on_color_changed(State.current_color)
	visible = false


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return


	if _job:
		_job.cancel()
		_job.wait_for_worker()
		_job = null
	_teardown_hover()
	State.finish_operation(_operation_id)
	_operation_id = 0
	var tx := _edit
	_edit = null
	if tx != null:
		State.cancel_edit(tx)
	_release_context_subscriptions()


func _exit_tree() -> void:
	_teardown_hover()
	_last_pick = null
	_cursor_axis = -1
	if has_node("Cursor"):
		$Cursor.show_selection(null)
	visible = false
	if _settings.changed.is_connected(_on_settings_changed):
		_settings.changed.disconnect(_on_settings_changed)


func _release_context_subscriptions() -> void:
	if is_inside_tree() or _edit != null or _job != null:
		return
	if State.edit_context_changing.is_connected(_cancel_edit):
		State.edit_context_changing.disconnect(_cancel_edit)
	if State.history_changed.is_connected(_on_history_changed):
		State.history_changed.disconnect(_on_history_changed)


func _teardown_hover() -> void:
	if _hover_job:
		_hover_job.cancel()
		_hover_job.wait_for_worker()
		_hover_job = null
	State.finish_operation(_hover_operation_id)
	_hover_operation_id = 0


func _on_color_changed(_color: Color) -> void:
	$Cursor.set_brush_material(State.current_material)
	_cursor_axis = -1
	if _source_frame == null and _last_pick:
		update_visual(_last_pick)


func _on_settings_changed() -> void:
	if _hover_job:
		_hover_job.cancel()
	_on_color_changed(State.current_color)


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event.is_action_pressed("ui_cancel") and _edit != null:
		_cancel_edit()
		return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if _edit != null or _job:
			return true
		var ray := _ray(pos)
		if _pick_start(ray[0], ray[1]).target == VoxelPicking.NONE:
			return false
	return super.handle_input(event, pos)


func open_stroke() -> VoxelEditTransaction:

	if _edit != null and not _edit.is_closed():
		return _edit
	var tx := super.open_stroke()
	if tx == null:
		return null
	_filter.reset()
	_source_document = State.document
	_source_frame = State.get_current_voxel_frame()
	_end_requested = false
	_stroke_pattern = {}
	_stroke_offsets = []
	_stroke_last_center = Vector3i.MAX
	_stroke_material_pattern = _settings.stamp_material_pattern.duplicate(true) if _settings.shape == StampSettings.BrushShape.STAMP else {}
	_stroke_diameter = _settings.diameter
	_stroke_shape = _settings.shape
	_stroke_pattern_size = _settings.estimated_size()
	_stroke_color = State.current_color
	_stroke_material = State.current_material.duplicate()


	_stroke_erases = _erases()
	_stroke_existing_only = _paints_existing() or _stroke_erases


	_edit_context = tx.edit_context
	return tx


func _apply_pick(target: Vector3i, hit: Vector3i) -> void:
	if _stroke_pattern.is_empty():
		_stroke_pattern = _settings.pattern()
		_stroke_offsets = _settings.pattern_offsets()
	var center := hit if _paints_existing() else target
	if center == VoxelPicking.NONE:
		return


	if _settings.pixel_perfect and target != VoxelPicking.NONE:
		_filter.feed(target)
	_queue_centers([center])


func _apply_stroke_to(to: Vector3i) -> void:
	var centers: Array[Vector3i] = []
	if _settings.pixel_perfect:
		centers = _filter.feed(to)
	else:
		centers = StrokeLine.cells(_last_target, to)
		centers.pop_front()
	_queue_centers(centers)


func _queue_centers(centers: Array[Vector3i]) -> void:
	_pending_centers.append_array(centers)
	if _job == null:
		_run_stroke()


func _run_stroke() -> void:
	var tx := _edit
	while _edit == tx and _job == null and not _pending_centers.is_empty():
		var job := _build_job()
		_job = job
		var work := job.estimate_work(job.centers.size() * _stroke_pattern_size)
		if job.surface_only:
			work *= SURFACE_ONLY_WORK_FACTOR
		if work <= INLINE_EDIT_LIMIT:
			job.run()
		else:
			_operation_id = State.begin_operation("Erasing brush" if job.erase_existing else "Painting brush", work, true, self, _cancel_edit)
			await State.run_edit_job(job, _operation_id, "Brush stroke")


		if _job != job:
			_release_context_subscriptions()
			return
		_finish_edit(job)

	if _edit == tx and _end_requested and _job == null:
		_finish_stroke()
	_release_context_subscriptions()


func _build_job() -> BrushJob:
	var job := BrushJob.new()
	job.centers = _pending_centers
	_pending_centers = []
	job.pattern = _stroke_pattern
	job.offsets = _stroke_offsets
	job.previous_center = _stroke_last_center
	job.material_pattern = _stroke_material_pattern
	job.diameter = _stroke_diameter
	job.shape = _stroke_shape
	job.material = _stroke_material
	job.paint_existing = _stroke_existing_only
	job.erase_existing = _stroke_erases
	job.edit_context = _edit_context


	job.edited_frame = VoxelFrame.job_frame(_source_frame)
	return job


func _process(_delta: float) -> void:
	_update_hover()


func _finish_edit(job: BrushJob) -> void:
	var profile_started_us := Profile.mark_us()


	var operation_id := _operation_id
	_operation_id = 0
	_job = null


	var applied := job.checkpoint(0)
	if not applied:
		_stroke_last_center = Vector3i.MAX
	if applied and _edit != null and State.document == _source_document and State.get_current_voxel_frame() == _source_frame:
		_stroke_pattern = job.pattern
		_stroke_offsets = job.offsets
		if not job.centers.is_empty():
			_stroke_last_center = job.centers[job.centers.size() - 1]
		_settings.cache_pattern(job.diameter, job.shape, job.pattern, job.offsets)


		_source_frame.apply_published(job.changed_chunks, job.edited_frame)
		State.document._bounds_dirty = true
		if not job.changed_chunks.is_empty():
			State.chunks_changed.emit(State.active_layer_index, State.current_frame, job.changed_chunks)


		var affected_cells: Array[Vector3i] = []
		affected_cells.assign(job.applied_cells.keys())
		if not affected_cells.is_empty():
			State.cells_changed.emit(State.active_layer_index, State.current_frame, affected_cells)
	State.finish_operation(operation_id)
	Profile.publish(profile_started_us)


func _on_history_changed() -> void:
	_stroke_last_center = Vector3i.MAX
	if _job:
		_job.cancel()


func _end() -> void:
	if _settings.pixel_perfect:
		_queue_centers(_filter.flush())
	_end_requested = true
	_stroke_active = false
	if _job == null:
		_finish_stroke()


func finish_on_switch() -> void:
	if _edit == null:
		return
	_end()


func _finish_stroke() -> void:


	_end_requested = false
	_source_document = null
	_source_frame = null
	_edit_context = null
	super._end()


func close_stroke(_action: String = "Stroke") -> void:
	var tx := _edit
	if tx == null:
		return
	_edit = null
	State.finish_edit(tx, "Erase" if _stroke_erases else "Stroke")


func _cancel_edit() -> void:
	if _job:
		_job.cancel()
	_stroke_last_center = Vector3i.MAX
	_teardown_hover()
	_last_pick = null
	_cursor_axis = -1
	if has_node("Cursor"):
		$Cursor.show_selection(null)


	_pending_centers = []
	_end_requested = false
	_stroke_active = false
	_plane = null
	_last_target = VoxelPicking.NONE
	_source_document = null
	_source_frame = null
	_edit_context = null
	visible = false
	State.finish_operation(_operation_id)
	_operation_id = 0
	abort_stroke()


func _pick_start(origin: Vector3, dir: Vector3) -> PickResult:
	var pick := super._pick_start(origin, dir)
	if not _pick_adds() or pick.add_target == VoxelPicking.NONE:
		return pick
	pick.target = pick.add_target
	if not State.slice_enabled:
		pick.plane = VoxelPicking.view_plane(pick.target, origin, _forward())
	return pick


func update_visual(pick: PickResult) -> void:
	if pick.plane == null:
		pick.plane = _plane
	_last_pick = pick
	if pick.target == VoxelPicking.NONE or (_requires_hit() and pick.hit == VoxelPicking.NONE):
		visible = false
		return
	var axis := _plane.axis if _stroke_active else pick.plane.axis
	if axis != _cursor_axis:
		_show_brush_shape(axis)
	position = Vector3.ZERO if _cursor_uses_world_cells() else Vector3(pick.target)
	visible = true


func _cursor_pattern(pattern: Dictionary) -> Dictionary:
	return pattern


func _cursor_cube_diameter() -> int:
	return _settings.diameter if _settings.shape == StampSettings.BrushShape.CUBE else 0


func _cursor_uses_world_cells() -> bool:
	return false


func _cursor_world_cells(_center: Vector3i, _pattern: Dictionary) -> Dictionary:
	return {}


func _show_brush_shape(axis: int) -> void:
	var pattern := _settings.pattern()
	if pattern.is_empty() and _settings.shape != _settings.BrushShape.STAMP:
		if _hover_job == null:
			_hover_job = _settings.create_pattern_job()
			_hover_job.diameter = _settings.diameter
			_hover_job.shape = _settings.shape
			_hover_operation_id = State.begin_operation("Preparing brush preview", _settings.estimated_size(), false, self)
			_hover_job.worker_task_id = WorkerThreadPool.add_task(_hover_job.run, false, "Brush shape")
		return
	pattern = _cursor_pattern(pattern)
	if _cursor_uses_world_cells():
		var center := _last_pick.target if _last_pick != null else VoxelPicking.NONE
		var world := _cursor_world_cells(center, pattern)
		$Cursor.set_brush_material(State.current_material)

		$Cursor.mirrors_enabled = false
		position = Vector3.ZERO
		$Cursor.show_voxels(world, State.current_color, _erases(), 0, false)
		_cursor_axis = axis
		return
	$Cursor.mirrors_enabled = true
	var use_voxel_colors: bool = _settings.shape == _settings.BrushShape.STAMP


	var cube_diameter: int = _cursor_cube_diameter()
	$Cursor.set_brush_material(State.current_material)
	if use_voxel_colors and _settings.stamp_material_pattern.size() == pattern.size():
		pattern = _settings.stamp_material_pattern
	elif use_voxel_colors and not _settings.stamp_material_pattern.is_empty():
		pattern = pattern.duplicate()
		for cell in pattern:
			var color: Color = pattern[cell]
			var fallback := State.current_material if color == Color.TRANSPARENT else VoxelFrame.material(color)
			pattern[cell] = _settings.stamp_material_pattern.get(cell, fallback)
	$Cursor.show_voxels(pattern, Color.WHITE if use_voxel_colors else State.current_color, _erases(), cube_diameter, use_voxel_colors)
	_cursor_axis = axis


func _update_hover() -> void:
	if _hover_job == null or not WorkerThreadPool.is_task_completed(_hover_job.worker_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(_hover_job.worker_task_id)
	var job = _hover_job
	_hover_job = null
	State.finish_operation(_hover_operation_id)
	_hover_operation_id = 0
	if job.checkpoint(0):
		_settings.cache_pattern(job.diameter, job.shape, job.pattern, job.offsets)
	if _last_pick and _edit == null:
		_cursor_axis = -1
		update_visual(_last_pick)


func driver_is_busy() -> bool:
	return _edit != null or _job != null
