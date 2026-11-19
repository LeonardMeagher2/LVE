extends "res://plugins/brush/StrokeTool.gd"


const VoxelPreviewScript := preload("res://Globals/Rendering/VoxelPreview.gd")
const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")


const INLINE_SURFACE_PREVIEW_LIMIT := 4096


var _preview_key: Array = []

var _preview_request := {}

var _preview_job: SurfacePreviewJob = null


var _retired_preview_jobs: Array[SurfacePreviewJob] = []

var last_preview_inline := true


var _last_world := {}

var _last_world_frame: VoxelFrame


class SurfacePreviewJob extends VoxelFrame.EditJob:

	var frame: VoxelFrame

	var context: VoxelFrame.EditContext

	var center := Vector3i.ZERO

	var pattern := {}

	var display_color := Color.WHITE

	var key: Array = []

	var payload = null


	func run() -> void:
		var changes := {}
		var completed := 0
		for offset: Vector3i in pattern:
			changes[center + offset] = display_color
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return
		var world := context.expand(changes, frame, true, null, self, true)
		if not checkpoint(0) or world.is_empty():
			return
		var cells: Array[Vector3i] = []
		cells.assign(world.keys())
		payload = VoxelPreviewScript.build_solid_payload(cells, display_color)


func _init() -> void:
	_settings = preload("./PaintSettings.tres")


func _process(delta: float) -> void:
	super._process(delta)
	_pump_surface_preview()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_teardown_surface_preview()
	super._notification(what)


func _exit_tree() -> void:
	_teardown_surface_preview()
	_preview_key = []
	_last_world = {}
	_last_world_frame = null
	super._exit_tree()


func _pick_adds() -> bool:
	return false


func _requires_hit() -> bool:
	return true


func _paints_existing() -> bool:
	return true


func pick_drag(request: PickRequest) -> PickResult:
	return VoxelPicking.start_pick(request.origin, request.direction, request.frame, request.forward, State.slice_enabled)


func _cursor_uses_world_cells() -> bool:
	return true


func _cursor_world_cells(center: Vector3i, pattern: Dictionary) -> Dictionary:
	if center == VoxelPicking.NONE or pattern.is_empty():
		return {}
	var frame := _current_preview_frame()
	var context := _current_preview_context()
	if frame == null or context == null:
		return {}
	var key := _preview_key_for(center)
	if key != _preview_key:
		_preview_key = key
	var estimate := pattern.size() * _symmetry_mask_count(context.axes)
	last_preview_inline = estimate <= INLINE_SURFACE_PREVIEW_LIMIT
	if last_preview_inline:
		var changes := {}
		for offset: Vector3i in pattern:
			changes[center + offset] = Color.TRANSPARENT
		var world := context.expand(changes, frame, true, null, null, true)
		world.make_read_only()
		_last_world = world
		_last_world_frame = frame
		return world
	_request_surface_preview(center, pattern, frame, context)


	if _last_world_frame == frame:
		return _last_world
	_last_world = {}
	_last_world_frame = frame
	return {}


func update_visual(pick: PickResult) -> void:
	if _cursor_uses_world_cells():
		var key := _preview_key_for(pick.target)
		if key != _preview_key:
			_preview_key = key
			_cursor_axis = -1
	super.update_visual(pick)


func _build_job() -> BrushJob:
	var job := super._build_job()
	job.surface_only = true
	return job


func _on_color_changed(color: Color) -> void:

	_cancel_surface_preview()
	super._on_color_changed(color)


func _on_history_changed() -> void:
	_cancel_surface_preview()
	_preview_key = []
	_last_world = {}
	_last_world_frame = null
	_cursor_axis = -1
	super._on_history_changed()
	if _edit == null and _last_pick != null:
		update_visual(_last_pick)


func is_surface_preview_settled() -> bool:
	return _preview_job == null and _preview_request.is_empty()


func _current_preview_frame() -> VoxelFrame:
	return _source_frame if _edit != null and _source_frame != null else State.get_current_voxel_frame()


func _current_preview_context() -> VoxelFrame.EditContext:
	return _edit_context if _edit != null and _edit_context != null else State.drawing_context()


func _preview_key_for(target: Vector3i) -> Array:
	var frame := _current_preview_frame()
	var context := _current_preview_context()
	if context == null:
		return [frame, target]
	var size := State.document.size if State.document != null else Vector3i.ZERO
	var selection_revision := 0 if _edit != null else State.selection.revision
	return [
		frame, target,
		context.axes, context.origin_twice,
		context.slice_axis, context.slice_index, context.slice_count,
		context.bounded_axes, context.bounds_min, context.bounds_max,
		selection_revision, size,
	]


func _request_surface_preview(center: Vector3i, pattern: Dictionary, frame: VoxelFrame, context: VoxelFrame.EditContext) -> void:
	_preview_request = {
		"center": center,
		"context": context,
		"snapshot": frame.copy_chunks(_preview_chunks(center, pattern, context)),
		"pattern": pattern,
		"color": State.current_color,
		"key": _preview_key,
	}
	_start_surface_preview()


func _start_surface_preview() -> void:
	if _preview_job != null or _preview_request.is_empty() or not is_inside_tree():
		return
	var request := _preview_request
	_preview_request = {}
	var job := SurfacePreviewJob.new()
	job.frame = request["snapshot"]
	job.context = request["context"]
	job.center = request["center"]
	job.pattern = request["pattern"]
	job.display_color = request["color"]
	job.key = request["key"]
	_preview_job = job
	job.worker_task_id = WorkerThreadPool.add_task(job.run, false, "Paint preview")


func _pump_surface_preview() -> void:
	_reap_retired_previews()
	var job := _preview_job
	if job == null or not WorkerThreadPool.is_task_completed(job.worker_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
	job.worker_task_id = -1
	_preview_job = null
	if job.checkpoint(0) and job.key == _preview_key:
		if job.payload != null:
			$Cursor.submit_prepared(job.payload)
			_last_world = job.payload.spots
			_last_world_frame = _current_preview_frame()
		else:
			$Cursor.show_voxels({})
			_last_world = {}
			_last_world_frame = _current_preview_frame()
	_start_surface_preview()


func _cancel_surface_preview() -> void:
	_preview_request = {}
	if _preview_job != null:
		_preview_job.cancel()
		_retired_preview_jobs.append(_preview_job)
		_preview_job = null


func _reap_retired_previews() -> void:
	for job in _retired_preview_jobs.duplicate():
		if not WorkerThreadPool.is_task_completed(job.worker_task_id):
			continue
		job.wait_for_worker()
		_retired_preview_jobs.erase(job)


func _teardown_surface_preview() -> void:
	_cancel_surface_preview()
	for job in _retired_preview_jobs:
		job.wait_for_worker()
	_retired_preview_jobs.clear()


func _symmetry_mask_count(axes: int) -> int:
	var count := 1
	for axis in 3:
		if axes & (1 << axis):
			count *= 2
	return count


func _preview_chunks(center: Vector3i, pattern: Dictionary, context: VoxelFrame.EditContext) -> Array[Vector3i]:
	var bounds := _pattern_bounds(pattern)
	var low: Vector3i = center + bounds[0] - Vector3i.ONE
	var high: Vector3i = center + bounds[1] + Vector3i.ONE
	var locations := {}
	for mask in 8:
		if (mask & ~context.axes) != 0:
			continue
		var reflected_low := low
		var reflected_high := high
		for axis in 3:
			if mask & (1 << axis):
				reflected_low[axis] = context.origin_twice[axis] - high[axis]
				reflected_high[axis] = context.origin_twice[axis] - low[axis]
		var min_chunk := VoxelFrame.chunk_position(reflected_low)
		var max_chunk := VoxelFrame.chunk_position(reflected_high)
		for x in range(min_chunk.x, max_chunk.x + 1):
			for y in range(min_chunk.y, max_chunk.y + 1):
				for z in range(min_chunk.z, max_chunk.z + 1):
					locations[Vector3i(x, y, z)] = true
	var result: Array[Vector3i] = []
	result.assign(locations.keys())
	return result


func _pattern_bounds(pattern: Dictionary) -> Array[Vector3i]:
	if _settings.shape != StampSettings.BrushShape.STAMP:
		var first := VoxelBrushSize.first_offset(_settings.diameter)
		var last := VoxelBrushSize.last_offset(_settings.diameter)
		return [Vector3i.ONE * first, Vector3i.ONE * last]
	var low := Vector3i.MAX
	var high := Vector3i.MIN
	for offset: Vector3i in pattern:
		low = Vector3i(mini(low.x, offset.x), mini(low.y, offset.y), mini(low.z, offset.z))
		high = Vector3i(maxi(high.x, offset.x), maxi(high.y, offset.y), maxi(high.z, offset.z))
	return [low, high]
