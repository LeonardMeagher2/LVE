extends VoxelTool

const INLINE_EDIT_LIMIT := 4096
const BrushSettings := preload("./BrushToolSettings.gd")

# Opt-in profiling hook. Off by default and free when off. A test turns it on to
# time the edit result publication, which the frame gap hides.
static var profile_enabled := false
static var profile_finish_us := 0
# One publication per `_finish_edit`. A reader compares this against the value
# it last saw, so a stale duration never attributes to a later frame.
static var profile_finish_seq := 0

var _settings := preload("./settings.tres")
var _filter := PixelPerfectStroke.new()
var _source_document: VoxelDocument
var _source_frame: VoxelFrame
var _end_requested := false
var _pending_centers: Array[Vector3i] = []
var _stroke_pattern := {}
var _stroke_offsets: Array = []
# The center of the last stamp in this stroke, or Vector3i.MAX when the next
# stamp must cover the whole pattern.
var _stroke_last_center := Vector3i.MAX
var _stroke_material_pattern := {}
var _stroke_diameter := 1
var _stroke_shape := 0
var _stroke_pattern_size := 1
var _stroke_color := Color.WHITE
var _stroke_material := VoxelFrame.material(Color.WHITE)
var _paint_existing := false
var _erase_existing := false
var _selection_mask := {}
var _edit_context: VoxelFrame.EditContext
var _job: BrushJob
var _operation_id := 0
var _cursor_axis := -1
var _last_pick: PickResult
var _hover_job: BrushSettings.PatternJob
var _hover_operation_id := 0

class BrushJob extends VoxelFrame.EditJob:
	var centers: Array[Vector3i] = []
	var pattern := {}
	# The pattern keys in the same order as the dictionary. The stamp reads only
	# the offsets, and an array iterates about twice as fast as the dictionary.
	var offsets: Array = []
	# The center of the previous stamp in this stroke, or Vector3i.MAX for the
	# first one. A short move leaves most of the footprint already written.
	var previous_center := Vector3i.MAX
	var material_pattern := {}
	var replace_materials := false
	var diameter := 1
	var shape := 0
	var material := VoxelFrame.material(Color.WHITE)
	var paint_existing := false
	var erase_existing := false
	var selection_mask := {}
	var edited_frame: VoxelFrame
	var cell_materials := {}
	var changed_chunks: Array[Vector3i] = []
	var revision := 0

	func run() -> void:
		if pattern.is_empty() and shape != BrushSettings.BrushShape.SELECTION:
			pattern = BrushSettings.build_pattern(diameter, shape, self)
		if offsets.size() != pattern.size():
			# The stamp reads the offsets, and a caller can leave them out.
			offsets = pattern.keys()
		if not checkpoint(0):
			return
		stage("Preparing brush", centers.size() * offsets.size())
		# A shape brush paints one material. A selection brush and a paste keep materials.
		var uniform := not replace_materials and shape != BrushSettings.BrushShape.SELECTION
		var uniform_material := VoxelFrame.material(Color.TRANSPARENT) if erase_existing else material
		# These tests do not change inside the loop, and the loop runs once per
		# pattern cell per center.
		var mask_empty: bool = selection_mask.is_empty()
		var existing_only := paint_existing
		var every_cell := edit_context != null or (mask_empty and not existing_only)
		# A shape brush paints one material, so an offset that wrote a cell leaves
		# the same material behind. That makes it safe to skip the offsets the
		# previous center already covered, which leaves the new edge alone. A
		# selection brush and a paste key the material on the offset, so they
		# cannot skip.
		var constant_material := erase_existing or uniform
		if constant_material:
			# Every cell of this job holds this one material, so the write can
			# skip its own uniform test.
			applied_uniform = uniform_material
		var covered := {}
		var previous := previous_center
		var completed := 0
		var until_checkpoint := 4096
		for center in centers:
			var use: Array = offsets
			if constant_material and previous != Vector3i.MAX:
				var delta: Vector3i = center - previous
				if delta == Vector3i.ZERO:
					# The previous center wrote this exact footprint already.
					use = []
				else:
					if not covered.has(delta):
						covered[delta] = _uncovered_offsets(offsets, pattern, delta)
					use = covered[delta]
			previous = center
			for offset: Vector3i in use:
				var cell_position := center + offset
				if every_cell or ((mask_empty or selection_mask.has(cell_position)) and (not existing_only or edited_frame.has(cell_position))):
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
		changed_chunks = apply_cells(edited_frame, cell_materials, paint_existing)


	# The offsets of a pattern that the same pattern shifted by `delta` does not
	# already cover. A cell at `center + offset` was written by the previous
	# center when `offset + delta` is also in the pattern.
	static func _uncovered_offsets(offsets: Array, pattern: Dictionary, delta: Vector3i) -> Array:
		var kept: Array = []
		for offset: Vector3i in offsets:
			if not pattern.has(offset + delta):
				kept.append(offset)
		return kept


func _enter_tree() -> void:
	# A tool switch re-enters this node. The guarded connects stay symmetric, so a
	# re-entry adds no duplicate subscription. `tree_exited` runs after the node
	# leaves the tree, where `_exit_tree` still reports it inside.
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
	# A freed node cannot await, so it cancels and joins its own work here. The
	# join is the one blocking wait. `wait_for_worker` is idempotent, so the stroke
	# runner's own join never double-waits.
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


# A tool or mode switch detaches this node but keeps the stroke. The stroke runner
# owns its worker join, and the context and history signals must outlive the
# detach: a frame, document, or history change still invalidates a pending result.
# `tree_exited` releases them once no work is pending, after the node has left the
# tree. The settings signal only refreshes the hover cursor, so it stops here.
func _exit_tree() -> void:
	_teardown_hover()
	_last_pick = null
	_cursor_axis = -1
	if has_node("Cursor"):
		$Cursor.show_selection(null)
	visible = false
	if _settings.changed.is_connected(_on_settings_changed):
		_settings.changed.disconnect(_on_settings_changed)


# Release the context and history subscriptions only when no stroke work is pending
# and the node is outside the tree. A pending worker keeps them, so a frame or
# document change can still cancel its result.
func _release_context_subscriptions() -> void:
	if is_inside_tree() or _edit != null or _job != null:
		return
	if State.edit_context_changing.is_connected(_cancel_edit):
		State.edit_context_changing.disconnect(_cancel_edit)
	if State.history_changed.is_connected(_on_history_changed):
		State.history_changed.disconnect(_on_history_changed)


# The hover job belongs to `_process`, which stops on a detach, so its join runs
# with the teardown rather than with the stroke runner.
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
	# A closed handle is stale, so fall through to the base acquire.
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
	_stroke_material_pattern = _settings.selection_material_pattern.duplicate(true) if _settings.shape == BrushSettings.BrushShape.SELECTION else {}
	_stroke_diameter = _settings.diameter
	_stroke_shape = _settings.shape
	_stroke_pattern_size = _settings.estimated_size()
	_stroke_color = State.current_color
	_stroke_material = State.current_material.duplicate()
	_paint_existing = _settings.mode == _settings.BrushMode.PAINT
	_erase_existing = _settings.mode == _settings.BrushMode.ERASER
	# Reuse the context the transaction froze at begin. Its selection is a read-only
	# snapshot, so the job can filter on it without copying the selection again.
	_edit_context = tx.edit_context
	_selection_mask = tx.edit_context.selection
	return tx


func _apply_pick(target: Vector3i, hit: Vector3i) -> void:
	if _stroke_pattern.is_empty():
		_stroke_pattern = _settings.pattern()
		_stroke_offsets = _settings.pattern_offsets()
	var center := hit if _paint_existing else target
	if center == VoxelPicking.NONE:
		return
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


# One runner owns one stroke batch at a time. An inline batch runs at once, so the
# first stamp lands in the input event. A worker batch awaits `State.run_edit_job`,
# which pumps the progress and joins the worker even when a tool switch detaches
# this node. A center that arrives while the worker runs joins the next batch of
# the same loop, so the loop drains the queue without recursion.
func _run_stroke() -> void:
	var tx := _edit
	while _edit == tx and _job == null and not _pending_centers.is_empty():
		var job := _build_job()
		_job = job
		var work := job.estimate_work(job.centers.size() * _stroke_pattern_size)
		if work <= INLINE_EDIT_LIMIT:
			job.run()
		else:
			_operation_id = State.begin_operation("Erasing brush" if job.erase_existing else "Painting brush", work, true, self, _cancel_edit)
			await State.run_edit_job(job, _operation_id, "Brush stroke")
		# A cancel or a replacement owns the stroke now, so this runner stops. A
		# publication callback can also start a new runner on the same transaction,
		# so the job identity, not `_job == null`, decides the next batch.
		if _job != job:
			_release_context_subscriptions()
			return
		_finish_edit(job)
	# The stroke closes only after its last batch is published.
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
	job.paint_existing = _paint_existing or _erase_existing
	job.erase_existing = _erase_existing
	job.selection_mask = _selection_mask
	job.edit_context = _edit_context
	job.edited_frame = _source_frame.copy_frame()
	return job


func _process(_delta: float) -> void:
	_update_hover()


func _finish_edit(job: BrushJob) -> void:
	var profile_started_us := Time.get_ticks_usec() if profile_enabled else 0
	# Capture the operation and clear the fields before the publication signals, so
	# a handler that starts a new stroke on this transaction keeps its own state.
	var operation_id := _operation_id
	_operation_id = 0
	_job = null
	# A cancelled job stopped partway, and history may have replaced the frame under
	# it, so its snapshot must not be published. Invalidate the stroke coverage so
	# the next stamp covers the whole pattern again.
	var applied := job.checkpoint(0)
	if not applied:
		_stroke_last_center = Vector3i.MAX
	if applied and _edit != null and State.document == _source_document and State.get_current_voxel_frame() == _source_frame:
		_stroke_pattern = job.pattern
		_stroke_offsets = job.offsets
		if not job.centers.is_empty():
			_stroke_last_center = job.centers[job.centers.size() - 1]
		_settings.cache_pattern(job.diameter, job.shape, job.pattern, job.offsets)
		_source_frame.restore(job.edited_frame.capture())
		State.document._bounds_dirty = true
		if not job.changed_chunks.is_empty():
			State.chunks_changed.emit(State.current_frame, job.changed_chunks)
	State.finish_operation(operation_id)
	if profile_enabled:
		profile_finish_us = Time.get_ticks_usec() - profile_started_us
		profile_finish_seq += 1


# Undo and redo replace frame contents without an edit context change, so the
# coverage the last stamp left behind no longer holds. A job still running holds a
# snapshot taken before the undo, so it must not publish that snapshot either.
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


# End the stroke like a release when a tool or mode switch detaches this tool. The
# runner stamps the queued centers, awaits a running worker, and closes the stroke
# as one history action. Escape and a context change keep their cooperative
# rollback.
func finish_on_switch() -> void:
	if _edit == null:
		return
	_end()


func _finish_stroke() -> void:
	# Clear the tool's stroke state before the close signals, so a handler that
	# opens a new stroke keeps its own captured state.
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
	State.finish_edit(tx, "Erase" if _erase_existing else "Stroke")


func _cancel_edit() -> void:
	if _job:
		_job.cancel()
	_stroke_last_center = Vector3i.MAX
	_teardown_hover()
	_last_pick = null
	_cursor_axis = -1
	if has_node("Cursor"):
		$Cursor.show_selection(null)
	# Clear the tool's stroke state before the cancel signals, so a handler that
	# opens a new stroke keeps its own captured state. The runner keeps `_job`
	# until it resumes, so a teardown can still join the cancelled worker.
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
	if _settings.mode in [_settings.BrushMode.PAINT, _settings.BrushMode.ERASER] or pick.add_target == VoxelPicking.NONE:
		return pick
	pick.target = pick.add_target
	pick.plane = VoxelPicking.view_plane(pick.target, origin, _forward())
	return pick


func pick_drag(request: PickRequest) -> PickResult:
	if _settings.mode != _settings.BrushMode.PAINT:
		return super.pick_drag(request)
	return VoxelPicking.start_pick(request.origin, request.dir, request.frame, request.forward)


func update_visual(pick: PickResult) -> void:
	if pick.plane == null:
		pick.plane = _plane
	_last_pick = pick
	if pick.target == VoxelPicking.NONE or (_settings.mode == _settings.BrushMode.PAINT and pick.hit == VoxelPicking.NONE):
		visible = false
		return
	var axis := _plane.axis if _stroke_active else pick.plane.axis
	if axis != _cursor_axis:
		_show_brush_shape(axis)
	position = Vector3(pick.target)
	visible = true


func _show_brush_shape(axis: int) -> void:
	var pattern := _settings.pattern()
	if pattern.is_empty() and _settings.shape != _settings.BrushShape.SELECTION:
		if _hover_job == null:
			_hover_job = _settings.PatternJob.new()
			_hover_job.diameter = _settings.diameter
			_hover_job.shape = _settings.shape
			_hover_operation_id = State.begin_operation("Preparing brush preview", _settings.estimated_size(), false, self)
			_hover_job.worker_task_id = WorkerThreadPool.add_task(_hover_job.run, false, "Brush shape")
		return
	var use_voxel_colors: bool = _settings.shape == _settings.BrushShape.SELECTION
	# A cube's preview is the same six faces as its voxels, so the box is exact and
	# costs nothing. A sphere's voxels are a stepped shape that no primitive
	# matches, so its preview always stays per-cell, however long that takes. The
	# selection shape keeps its own materials and already debounces.
	var cube_diameter: int = _settings.diameter if _settings.shape == _settings.BrushShape.CUBE else 0
	$Cursor.set_brush_material(State.current_material)
	if use_voxel_colors and _settings.selection_material_pattern.size() == pattern.size():
		pattern = _settings.selection_material_pattern
	elif use_voxel_colors and not _settings.selection_material_pattern.is_empty():
		pattern = pattern.duplicate()
		for cell in pattern:
			var color: Color = pattern[cell]
			var fallback := State.current_material if color == Color.TRANSPARENT else VoxelFrame.material(color)
			pattern[cell] = _settings.selection_material_pattern.get(cell, fallback)
	$Cursor.show_voxels(pattern, Color.WHITE if use_voxel_colors else State.current_color, _settings.mode == _settings.BrushMode.ERASER, cube_diameter, use_voxel_colors)
	_cursor_axis = axis


func _update_hover() -> void:
	if _hover_job == null or not WorkerThreadPool.is_task_completed(_hover_job.worker_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(_hover_job.worker_task_id)
	var job := _hover_job
	_hover_job = null
	State.finish_operation(_hover_operation_id)
	_hover_operation_id = 0
	if job.checkpoint(0):
		_settings.cache_pattern(job.diameter, job.shape, job.pattern, job.offsets)
	if _last_pick and _edit == null:
		_cursor_axis = -1
		update_visual(_last_pick)
