class_name VoxelRenderer
extends Node3D

const CHUNK_SIZE := VoxelFrame.CHUNK_SIZE
const MAX_SURFACE_JOBS := 2
const SURFACE_CACHE_LIMIT_BYTES := 64 * 1024 * 1024
const SURFACE_CACHE_LIMIT_ENTRIES := 1024

# All viewports share meshes and jobs. Workers own their input and output arrays.
static var _surface_cache: Dictionary = {}
static var _surface_use_order: Array[String] = []
static var _surface_cache_bytes := 0
static var _surface_jobs: Dictionary = {}
static var _active_renderer_count := 0

@export_range(-1, 100, 1, "or_greater") var frame: int = -1:
	set(value):
		if value == frame:
			return
		frame = value
		if is_inside_tree():
			_rebuild()

# Keep the scene's shared voxel material as the source of render settings.
@export var mesh: Mesh
@export var report_activity := true
var source_frame: VoxelFrame:
	set(value):
		if value == source_frame:
			return
		source_frame = value
		if is_inside_tree():
			_rebuild()
var _chunk_instances: Dictionary = {}
var _displayed_surface_keys: Dictionary = {}
var _pending_surface_keys: Dictionary = {}
var _retired_chunk_instances: Array[MeshInstance3D] = []
var _displayed_frame: VoxelFrame
var _operation_id := 0
var _reported_remaining := -1


func _enter_tree() -> void:
	# Finish surface work while a workspace is hidden.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_active_renderer_count += 1
	State.frame_changed.connect(_on_frame_changed)
	State.frames_changed.connect(_rebuild)
	State.cells_changed.connect(_update)
	State.chunks_changed.connect(_update_chunks)
	State.document_changed.connect(_rebuild)


func _notification(what: int) -> void:
	if what == NOTIFICATION_POST_ENTER_TREE:
		_rebuild()


func _exit_tree() -> void:
	State.frame_changed.disconnect(_on_frame_changed)
	State.frames_changed.disconnect(_rebuild)
	State.cells_changed.disconnect(_update)
	State.chunks_changed.disconnect(_update_chunks)
	State.document_changed.disconnect(_rebuild)
	State.finish_operation(_operation_id)
	_operation_id = 0
	# No worker accesses a renderer. Collect every task when the last viewport exits.
	_active_renderer_count -= 1
	if _active_renderer_count == 0:
		for surface_key in _surface_jobs.keys():
			WorkerThreadPool.wait_for_task_completion(_surface_jobs[surface_key].worker_task_id)
		_surface_jobs.clear()
		_surface_cache.clear()
		_surface_use_order.clear()
		_surface_cache_bytes = 0
	for chunk_instance in _retired_chunk_instances:
		chunk_instance.free()
	_retired_chunk_instances.clear()


func _get_frame() -> VoxelFrame:
	if source_frame:
		return source_frame
	return State.get_voxel_frame(frame) if frame >= 0 else State.get_current_voxel_frame()


func _on_frame_changed() -> void:
	if frame == -1 and source_frame == null:
		_rebuild()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	var source_frame := _get_frame()
	if source_frame != _displayed_frame:
		for chunk_instance in _chunk_instances.values():
			chunk_instance.visible = false
		_displayed_frame = source_frame
	_pending_surface_keys.clear()
	for chunk_location in _displayed_surface_keys.keys():
		if source_frame == null or not source_frame.chunks.has(chunk_location):
			_retire(chunk_location)
	if source_frame:
		for chunk_location in source_frame.chunks:
			_request(source_frame, chunk_location)
	_report_activity()


func _update(updated_frame: int, affected_cells: Array[Vector3i]) -> void:
	if updated_frame != (frame if frame >= 0 else State.current_frame):
		return
	if affected_cells.is_empty():
		_rebuild()
		return
	var source_frame := _get_frame()
	var affected_chunks := {}
	for cell_position in affected_cells:
		var chunk_location := VoxelFrame.chunk_position(cell_position)
		affected_chunks[chunk_location] = true
		var local_cell: Vector3i = cell_position - chunk_location * CHUNK_SIZE
		for direction in VoxelFrame.DIRECTIONS:
			var neighbor_cell: Vector3i = local_cell + direction
			if neighbor_cell.x < 0 or neighbor_cell.y < 0 or neighbor_cell.z < 0 or neighbor_cell.x >= CHUNK_SIZE or neighbor_cell.y >= CHUNK_SIZE or neighbor_cell.z >= CHUNK_SIZE:
				affected_chunks[chunk_location + direction] = true
	for chunk_location in affected_chunks:
		_request(source_frame, chunk_location)
	_report_activity()


func _request(source_frame: VoxelFrame, chunk_location: Vector3i) -> void:
	if not source_frame.chunks.has(chunk_location):
		_pending_surface_keys.erase(chunk_location)
		_retire(chunk_location)
		return
	var surface_key := _signature(source_frame, chunk_location)
	if _displayed_surface_keys.get(chunk_location) == surface_key:
		_pending_surface_keys.erase(chunk_location)
		if _chunk_instances.has(chunk_location):
			_chunk_instances[chunk_location].visible = true
	else:
		_pending_surface_keys[chunk_location] = surface_key
		# Keep the completed mesh visible until the replacement is ready.


func _update_chunks(updated_frame: int, chunk_positions: Array[Vector3i]) -> void:
	if updated_frame != (frame if frame >= 0 else State.current_frame):
		return
	var source_frame := _get_frame()
	var affected_chunks := {}
	for chunk_location in chunk_positions:
		affected_chunks[chunk_location] = true
		for direction in VoxelFrame.DIRECTIONS:
			affected_chunks[chunk_location + direction] = true
	for chunk_location in affected_chunks:
		_request(source_frame, chunk_location)
	_report_activity()


static func _signature(source_frame: VoxelFrame, chunk_location: Vector3i) -> String:
	var surface_key := ""
	var sampled_chunks: Array = [chunk_location]
	for direction in VoxelFrame.DIRECTIONS:
		sampled_chunks.append(chunk_location + direction)
	for sampled_location in sampled_chunks:
		var chunk: VoxelFrame.Chunk = source_frame.chunks.get(sampled_location)
		surface_key += "%s:%s/" % [chunk.get_instance_id(), chunk.voxel_revision] if chunk else "0/"
	return surface_key


func _process(_delta: float) -> void:
	_update_surfaces()
	_report_activity()


func _update_surfaces() -> void:
	var update_started_us := Time.get_ticks_usec()
	for surface_key in _surface_jobs.keys():
		var surface_job: VoxelMeshBuilder = _surface_jobs[surface_key]
		if WorkerThreadPool.is_task_completed(surface_job.worker_task_id):
			WorkerThreadPool.wait_for_task_completion(surface_job.worker_task_id)
			var chunk_surface: ArrayMesh = null
			if not surface_job.surface_arrays[Mesh.ARRAY_VERTEX].is_empty():
				chunk_surface = ArrayMesh.new()
				chunk_surface.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_job.surface_arrays)
			_cache_surface(surface_key, chunk_surface, surface_job.geometry_bytes)
			_surface_jobs.erase(surface_key)
		if Time.get_ticks_usec() - update_started_us >= State.WORK_SLICE_US:
			return
	var source_frame := _get_frame()
	for chunk_location in _pending_surface_keys.keys():
		var surface_key: String = _pending_surface_keys[chunk_location]
		if _surface_cache.has(surface_key):
			_install(chunk_location, surface_key, _surface_cache[surface_key].surface)
			_pending_surface_keys.erase(chunk_location)
			_surface_use_order.erase(surface_key)
			_surface_use_order.append(surface_key)
		elif not _surface_jobs.has(surface_key) and _surface_jobs.size() < MAX_SURFACE_JOBS:
			var surface_job := VoxelMeshBuilder.new()
			surface_job.source_frame = source_frame.copy_frame()
			surface_job.chunk_location = chunk_location
			surface_job.worker_task_id = WorkerThreadPool.add_task(surface_job.run, false, "Voxel surface")
			_surface_jobs[surface_key] = surface_job
		if Time.get_ticks_usec() - update_started_us >= State.WORK_SLICE_US:
			return
	while not _retired_chunk_instances.is_empty():
		_retired_chunk_instances.pop_back().queue_free()
		if Time.get_ticks_usec() - update_started_us >= State.WORK_SLICE_US:
			break


func _report_activity() -> void:
	var remaining := _pending_surface_keys.size()
	if not report_activity or remaining == 0:
		State.finish_operation(_operation_id)
		_operation_id = 0
		_reported_remaining = -1
		return
	if not State.has_operation(_operation_id):
		_operation_id = State.begin_operation("Building surfaces", -1, false, self)
		_reported_remaining = -1
	if remaining != _reported_remaining:
		State.update_operation(_operation_id, 0, -1, "", "%d chunks remaining" % remaining)
		_reported_remaining = remaining


static func _cache_surface(surface_key: String, chunk_surface: ArrayMesh, geometry_bytes: int) -> void:
	_surface_cache[surface_key] = {"surface": chunk_surface, "geometry_bytes": geometry_bytes}
	_surface_use_order.append(surface_key)
	_surface_cache_bytes += geometry_bytes
	while (_surface_cache_bytes > SURFACE_CACHE_LIMIT_BYTES or _surface_cache.size() > SURFACE_CACHE_LIMIT_ENTRIES) and _surface_use_order.size() > 1:
		var oldest_surface_key: String = _surface_use_order.pop_front()
		_surface_cache_bytes -= _surface_cache[oldest_surface_key].geometry_bytes
		_surface_cache.erase(oldest_surface_key)


func _install(chunk_location: Vector3i, surface_key: String, chunk_surface: ArrayMesh) -> void:
	if chunk_surface == null:
		_retire(chunk_location)
		_displayed_surface_keys[chunk_location] = surface_key
		return
	var chunk_instance: MeshInstance3D = _chunk_instances.get(chunk_location)
	if chunk_instance == null:
		chunk_instance = MeshInstance3D.new()
		chunk_instance.position = Vector3(chunk_location * CHUNK_SIZE)
		if mesh and mesh.get_surface_count() > 0:
			chunk_instance.material_override = mesh.surface_get_material(0)
		add_child(chunk_instance)
		_chunk_instances[chunk_location] = chunk_instance
	chunk_instance.mesh = chunk_surface
	chunk_instance.visible = true
	_displayed_surface_keys[chunk_location] = surface_key


func _retire(chunk_location: Vector3i) -> void:
	if _chunk_instances.has(chunk_location):
		var chunk_instance: MeshInstance3D = _chunk_instances[chunk_location]
		chunk_instance.visible = false
		_retired_chunk_instances.append(chunk_instance)
		_chunk_instances.erase(chunk_location)
	_displayed_surface_keys.erase(chunk_location)


func is_settled() -> bool:
	return _pending_surface_keys.is_empty()


func refresh() -> void:
	_rebuild()
