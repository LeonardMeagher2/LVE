class_name VoxelRenderer
extends Node3D


const CHUNK_SIZE := VoxelFrame.CHUNK_SIZE
const SURFACE_CACHE_LIMIT_BYTES := 64 * 1024 * 1024
const SURFACE_CACHE_LIMIT_BYTES_LOW_POLY := 256 * 1024 * 1024
const SURFACE_CACHE_LIMIT_ENTRIES := 1024
const SURFACE_CACHE_LIMIT_ENTRIES_LOW_POLY := 4096
const SURFACE_JOB_LIMIT_MIN := 2
const SURFACE_JOB_LIMIT_MAX := 8

static var _surface_cache: Dictionary = {}
static var _surface_use_order: Array[PackedInt64Array] = []
static var _surface_cache_bytes := 0
static var _surface_cache_filled := 0
static var _surface_cache_has_low_poly := false
static var _surface_jobs: Dictionary = {}
static var _active_renderer_count := 0
var _chunk_notice_frame := -1
var _chunk_notice_pending := false
static var _surface_job_limit := 0


static func _job_limit() -> int:
	if _surface_job_limit == 0:
		_surface_job_limit = clampi(OS.get_processor_count() - 1, SURFACE_JOB_LIMIT_MIN, SURFACE_JOB_LIMIT_MAX)
	return _surface_job_limit


@export_range(-1, 100, 1, "or_greater") var frame: int = -1:
	set(value):
		if value == frame:
			return
		frame = value
		if is_inside_tree():
			_rebuild()

@export var mesh: Mesh
@export var report_activity := true
@export var profile_surfaces := false
var source_frame: VoxelFrame:
	set(value):
		if value == source_frame:
			return
		source_frame = value
		if is_inside_tree():
			_rebuild(false)
var slice_axis := -1:
	set(value):
		if value == slice_axis:
			return
		slice_axis = value
		if is_inside_tree() and not _slice_setting:
			_rebuild()
var slice_index := 0:
	set(value):
		if value == slice_index:
			return
		slice_index = value
		if is_inside_tree() and not _slice_setting:
			_rebuild()
var slice_count := 1:
	set(value):
		value = maxi(value, 1)
		if value == slice_count:
			return
		slice_count = value
		if is_inside_tree() and not _slice_setting:
			_rebuild()
var unshaded := false:
	set(value):
		if value == unshaded:
			return
		unshaded = value
		_apply_materials()
var override_material: Material:
	set(value):
		if value == override_material:
			return
		override_material = value
		_apply_materials()
var material_builder: Callable:
	set(value):
		if value == material_builder:
			return
		material_builder = value
		_apply_materials()
var _slice_setting := false


func set_slice(axis: int, index: int, count: int) -> void:
	count = maxi(count, 1)
	if axis == slice_axis and index == slice_index and count == slice_count:
		return
	_slice_setting = true
	slice_axis = axis
	slice_index = index
	slice_count = count
	_slice_setting = false
	if is_inside_tree():
		_rebuild()

var _chunk_instances: Dictionary = {}
var _displayed_surface_keys: Dictionary = {}
var _chunk_materials: Dictionary = {}
var _unshaded_materials: Dictionary = {}
var _pending_surface_keys: Dictionary = {}
var _inflight_surface_keys: Dictionary = {}
var _retired_chunk_instances: Array[MeshInstance3D] = []
var _displayed_frame: VoxelFrame
var _operation_id := 0
var _reported_remaining := -1
var _launch_snapshot: VoxelFrame
var _profile := {
	"reaped": 0, "empty": 0, "culled": 0, "consume": 0, "launch": 0, "lost": 0, "truncated": 0,
	"material_us": 0, "cache_us": 0, "install_us": 0, "snapshot_us": 0, "snapshots": 0,
}


func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_active_renderer_count += 1
	State.frame_changed.connect(_on_frame_changed)
	State.frames_changed.connect(_rebuild)
	State.cells_changed.connect(_update)
	State.chunks_changed.connect(_update_chunks)
	State.document_changed.connect(_rebuild)
	State.model_settings_changed.connect(_rebuild)


func _notification(what: int) -> void:
	if what == NOTIFICATION_POST_ENTER_TREE:
		_rebuild()


func _exit_tree() -> void:
	State.frame_changed.disconnect(_on_frame_changed)
	State.frames_changed.disconnect(_rebuild)
	State.cells_changed.disconnect(_update)
	State.chunks_changed.disconnect(_update_chunks)
	State.document_changed.disconnect(_rebuild)
	State.model_settings_changed.disconnect(_rebuild)
	State.finish_operation(_operation_id)
	_operation_id = 0
	_active_renderer_count -= 1
	if _active_renderer_count == 0:
		for surface_key in _surface_jobs.keys():
			WorkerThreadPool.wait_for_task_completion(_surface_jobs[surface_key].worker_task_id)
		_surface_jobs.clear()
		_surface_cache.clear()
		_surface_use_order.clear()
		_surface_cache_bytes = 0
		_surface_cache_filled = 0
		_surface_cache_has_low_poly = false
	for chunk_instance in _retired_chunk_instances:
		chunk_instance.free()
	_retired_chunk_instances.clear()
	_launch_snapshot = null


func _get_frame() -> VoxelFrame:
	if source_frame:
		return source_frame
	return State.get_voxel_frame(frame) if frame >= 0 else State.get_current_voxel_frame()


func _on_frame_changed() -> void:
	if frame == -1 and source_frame == null:
		_rebuild()


func _rebuild(hide_all := true) -> void:
	if not is_inside_tree():
		return
	var active_frame := _get_frame()
	if active_frame != _displayed_frame:
		if hide_all:
			for chunk_instance in _chunk_instances.values():
				chunk_instance.visible = false
		_displayed_frame = active_frame
	_pending_surface_keys.clear()
	_inflight_surface_keys.clear()
	var requested := _request_locations(active_frame)
	for chunk_location in _displayed_surface_keys.keys():
		if not requested.has(chunk_location):
			_retire(chunk_location)
	for chunk_location: Vector3i in requested:
		_request(active_frame, chunk_location)
	_report_activity()


func _request_locations(active_frame: VoxelFrame) -> Dictionary:
	var locations := {}
	if active_frame == null:
		return locations
	var include_neighbors := State.document.mesh_style != 0
	for location: Vector3i in active_frame.chunks:
		locations[location] = true
		if not include_neighbors:
			continue
		for offset: Vector3i in VoxelMeshBuilder.neighbor_offsets(true):
			if offset != Vector3i.ZERO:
				locations[location + offset] = true
	return locations


func _update(updated_frame: int, affected_cells: Array[Vector3i]) -> void:
	if updated_frame != (frame if frame >= 0 else State.current_frame):
		return
	if affected_cells.is_empty():
		_rebuild()
		return
	if _chunk_notice_pending and _chunk_notice_frame == updated_frame:
		_report_activity()
		return
	var active_frame := _get_frame()
	var affected_chunks := {}
	for cell_position in affected_cells:
		var chunk_location := VoxelFrame.chunk_position(cell_position)
		affected_chunks[chunk_location] = true
		for offset in VoxelFrame.crosstalk_chunks(cell_position):
			affected_chunks[chunk_location + offset] = true
	for chunk_location in affected_chunks:
		_request(active_frame, chunk_location)
	_report_activity()


func _clear_chunk_notice() -> void:
	_chunk_notice_pending = false


func _request(active_frame: VoxelFrame, chunk_location: Vector3i) -> void:
	if not active_frame.chunks.has(chunk_location) and State.document.mesh_style == 0:
		_pending_surface_keys.erase(chunk_location)
		_inflight_surface_keys.erase(chunk_location)
		_retire(chunk_location)
		return
	if slice_axis >= 0:
		var first_row := VoxelFrame.chunk_position(Vector3i(slice_index, slice_index, slice_index))[slice_axis]
		var last_row := VoxelFrame.chunk_position(Vector3i(slice_index + slice_count - 1, slice_index + slice_count - 1, slice_index + slice_count - 1))[slice_axis]
		if chunk_location[slice_axis] < first_row or chunk_location[slice_axis] > last_row:
			_pending_surface_keys.erase(chunk_location)
			_inflight_surface_keys.erase(chunk_location)
			_retire(chunk_location)
			return
	var surface_key := _signature(active_frame, chunk_location, State.document.smooth_normals, slice_axis, slice_index, slice_count, State.document.ao_strength, State.document.mesh_style)
	if _displayed_surface_keys.get(chunk_location) == surface_key:
		_pending_surface_keys.erase(chunk_location)
		_inflight_surface_keys.erase(chunk_location)
		if _chunk_instances.has(chunk_location):
			_chunk_instances[chunk_location].visible = true
	else:
		_pending_surface_keys[chunk_location] = surface_key


func _update_chunks(updated_frame: int, chunk_positions: Array[Vector3i]) -> void:
	if updated_frame != (frame if frame >= 0 else State.current_frame):
		return
	var active_frame := _get_frame()
	var requested := {}
	for chunk_location in chunk_positions:
		if requested.has(chunk_location):
			continue
		requested[chunk_location] = true
		_request(active_frame, chunk_location)
	_chunk_notice_frame = updated_frame
	if not _chunk_notice_pending:
		_chunk_notice_pending = true
		_clear_chunk_notice.call_deferred()
	_report_activity()


static func _signature(active_frame: VoxelFrame, chunk_location: Vector3i, smooth_normals: bool, slice_axis := -1, slice_index := 0, slice_count := 1, ao_strength := 0.0, mesh_style := 0) -> PackedInt64Array:
	var ao_enabled := ao_strength > 0.0
	var offsets := VoxelMeshBuilder.neighbor_offsets(smooth_normals or ao_enabled or mesh_style != 0)
	var surface_key := PackedInt64Array()
	var tail := 4 if slice_axis >= 0 else 0
	var extra := 1 if ao_enabled else 0
	surface_key.resize(1 + offsets.size() * 2 + tail + extra)
	surface_key[0] = (1 if smooth_normals else 0) | (2 if ao_enabled else 0) | (mesh_style << 2)
	var index := 1
	for offset: Vector3i in offsets:
		var chunk: VoxelFrame.Chunk = active_frame.chunks.get(chunk_location + offset)
		if chunk:
			surface_key[index] = chunk.get_instance_id()
			surface_key[index + 1] = chunk.voxel_revision
		index += 2
	if slice_axis >= 0:
		surface_key[index] = 1
		surface_key[index + 1] = slice_axis
		surface_key[index + 2] = slice_index
		surface_key[index + 3] = slice_count
		index += 4
	if ao_enabled:
		surface_key[index] = roundi(ao_strength * 1000.0)
	return surface_key


func _process(_delta: float) -> void:
	_update_surfaces()
	_report_activity()


func _work_slice_us() -> int:
	return State.WORK_SLICE_US


func _update_surfaces() -> void:
	var update_started_us := Time.get_ticks_usec()
	var slice_us := _work_slice_us()
	var active_frame := _get_frame()
	_launch_snapshot = null
	for chunk_location in _inflight_surface_keys.keys():
		if _consume_inflight(chunk_location):
			_launch_surface(chunk_location, active_frame)
		if Time.get_ticks_usec() - update_started_us >= slice_us:
			if profile_surfaces:
				_profile.truncated += 1
			return
	for surface_key in _surface_jobs.keys():
		var surface_job = _surface_jobs[surface_key]
		if WorkerThreadPool.is_task_completed(surface_job.worker_task_id):
			var reap_started_us := Time.get_ticks_usec()
			WorkerThreadPool.wait_for_task_completion(surface_job.worker_task_id)
			var chunk_surface: ArrayMesh = null
			if not surface_job.surface_arrays[Mesh.ARRAY_VERTEX].is_empty():
				chunk_surface = ArrayMesh.new()
				chunk_surface.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_job.surface_arrays)
			var material := _build_material(surface_job)
			var cache_started_us := Time.get_ticks_usec()
			var cache_bytes: int = surface_job.geometry_bytes + surface_job.atlas_albedo.size() + surface_job.atlas_orm.size() + surface_job.atlas_emission.size()
			_cache_surface(surface_key, chunk_surface, cache_bytes, material)
			if profile_surfaces:
				_profile.reaped += 1
				if chunk_surface == null:
					_profile.empty += 1
				if surface_job.enclosed_culled:
					_profile.culled += 1
				_profile.material_us += cache_started_us - reap_started_us
				_profile.cache_us += Time.get_ticks_usec() - cache_started_us
			_surface_jobs.erase(surface_key)
		if Time.get_ticks_usec() - update_started_us >= slice_us:
			if profile_surfaces:
				_profile.truncated += 1
			return
	for chunk_location in _inflight_surface_keys.keys():
		if _consume_inflight(chunk_location):
			_launch_surface(chunk_location, active_frame)
		if Time.get_ticks_usec() - update_started_us >= slice_us:
			if profile_surfaces:
				_profile.truncated += 1
			return
	for chunk_location in _pending_surface_keys.keys():
		if _inflight_surface_keys.has(chunk_location):
			continue
		_launch_surface(chunk_location, active_frame)
		if Time.get_ticks_usec() - update_started_us >= slice_us:
			if profile_surfaces:
				_profile.truncated += 1
			return
	while not _retired_chunk_instances.is_empty():
		_retired_chunk_instances.pop_back().queue_free()
		if Time.get_ticks_usec() - update_started_us >= slice_us:
			break


func _consume_inflight(chunk_location: Vector3i) -> bool:
	if not _inflight_surface_keys.has(chunk_location):
		return false
	if not _pending_surface_keys.has(chunk_location):
		_inflight_surface_keys.erase(chunk_location)
		return false
	var surface_key: PackedInt64Array = _inflight_surface_keys[chunk_location]
	if not _surface_cache.has(surface_key):
		if _surface_jobs.has(surface_key):
			return false
		_inflight_surface_keys.erase(chunk_location)
		if profile_surfaces:
			_profile.lost += 1
		return false
	_install(chunk_location, surface_key, _surface_cache[surface_key])
	_touch_surface(surface_key)
	_inflight_surface_keys.erase(chunk_location)
	var wanted: PackedInt64Array = _pending_surface_keys[chunk_location]
	if wanted == surface_key:
		_pending_surface_keys.erase(chunk_location)
	if profile_surfaces:
		_profile.consume += 1
	return true


func _launch_surface(chunk_location: Vector3i, active_frame: VoxelFrame) -> void:
	if _inflight_surface_keys.has(chunk_location):
		return
	if not _pending_surface_keys.has(chunk_location):
		return
	var surface_key: PackedInt64Array = _pending_surface_keys[chunk_location]
	if _displayed_surface_keys.get(chunk_location) == surface_key:
		_pending_surface_keys.erase(chunk_location)
		if _chunk_instances.has(chunk_location):
			_chunk_instances[chunk_location].visible = true
		return
	if _surface_cache.has(surface_key):
		_install(chunk_location, surface_key, _surface_cache[surface_key])
		_pending_surface_keys.erase(chunk_location)
		_touch_surface(surface_key)
		return
	if _surface_jobs.has(surface_key):
		_inflight_surface_keys[chunk_location] = surface_key
		return
	if active_frame == null or (State.document.mesh_style == 0 and not active_frame.chunks.has(chunk_location)):
		_pending_surface_keys.erase(chunk_location)
		return
	if _surface_jobs.size() >= _job_limit():
		return
	var surface_job
	if State.document.mesh_style == 0:
		var greedy := VoxelMeshBuilder.new()
		greedy.smooth_normals = State.document.smooth_normals
		greedy.ao_strength = State.document.ao_strength
		greedy.slice_axis = slice_axis
		greedy.slice_index = slice_index
		greedy.slice_count = slice_count
		surface_job = greedy
	else:
		var marching := VoxelMarchingMeshBuilder.new()
		marching.slice_axis = slice_axis
		marching.slice_index = slice_index
		marching.slice_count = slice_count
		surface_job = marching
	surface_job.source_frame = _snapshot_for_launch(active_frame)
	surface_job.chunk_location = chunk_location
	surface_job.worker_task_id = WorkerThreadPool.add_task(surface_job.run, false, "Voxel surface")
	_surface_jobs[surface_key] = surface_job
	_inflight_surface_keys[chunk_location] = surface_key
	if profile_surfaces:
		_profile.launch += 1


func _snapshot_for_launch(active_frame: VoxelFrame) -> VoxelFrame:
	if _launch_snapshot == null:
		var started_us := Time.get_ticks_usec()
		_launch_snapshot = active_frame.copy_frame()
		if profile_surfaces:
			_profile.snapshot_us += Time.get_ticks_usec() - started_us
			_profile.snapshots += 1
	return _launch_snapshot


static func _touch_surface(surface_key: PackedInt64Array) -> void:
	_surface_use_order.erase(surface_key)
	_surface_use_order.append(surface_key)


func _report_activity() -> void:
	var remaining := _pending_surface_keys.size()
	if not report_activity or remaining == 0:
		State.finish_operation(_operation_id)
		_operation_id = 0
		_reported_remaining = -1
		return
	if not State.has_operation(_operation_id):
		_operation_id = State.begin_operation("Rendering", -1, false, self)
		_reported_remaining = -1
	if remaining != _reported_remaining:
		State.update_operation(_operation_id, 0, -1, "", "%d chunks remaining" % remaining)
		_reported_remaining = remaining


static func _cache_surface(surface_key: PackedInt64Array, chunk_surface: ArrayMesh, geometry_bytes: int, material: StandardMaterial3D) -> void:
	_surface_cache[surface_key] = {"surface": chunk_surface, "material": material, "bytes": geometry_bytes}
	_surface_use_order.append(surface_key)
	_surface_cache_bytes += geometry_bytes
	if chunk_surface != null:
		_surface_cache_filled += 1
	if (surface_key[0] & 4) != 0:
		_surface_cache_has_low_poly = true
	var byte_limit := SURFACE_CACHE_LIMIT_BYTES_LOW_POLY if _surface_cache_has_low_poly else SURFACE_CACHE_LIMIT_BYTES
	var entry_limit := SURFACE_CACHE_LIMIT_ENTRIES_LOW_POLY if _surface_cache_has_low_poly else SURFACE_CACHE_LIMIT_ENTRIES
	while (_surface_cache_bytes > byte_limit or _surface_cache_filled > entry_limit) and _surface_use_order.size() > 1:
		var oldest_surface_key: PackedInt64Array = _surface_use_order.pop_front()
		var oldest: Dictionary = _surface_cache[oldest_surface_key]
		_surface_cache_bytes -= oldest.bytes
		if oldest.surface != null:
			_surface_cache_filled -= 1
		_surface_cache.erase(oldest_surface_key)


func _build_material(surface_job) -> StandardMaterial3D:
	if surface_job.atlas_size.x == 0:
		return null
	var shared_material: Material = mesh.surface_get_material(0) if mesh and mesh.get_surface_count() > 0 else null
	var material: StandardMaterial3D
	if surface_job.atlas:
		material = surface_job.atlas.create_material(shared_material as StandardMaterial3D)
	else:
		material = shared_material.duplicate() if shared_material is StandardMaterial3D else StandardMaterial3D.new()
		var finish_texture := _atlas_texture(surface_job.atlas_size, surface_job.atlas_orm)
		material.albedo_texture = _atlas_texture(surface_job.atlas_size, surface_job.atlas_albedo)
		material.metallic_texture = finish_texture
		material.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
		material.roughness_texture = finish_texture
		material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		material.emission_texture = _atlas_texture(surface_job.atlas_size, surface_job.atlas_emission)
		material.emission_enabled = true
		material.emission = Color.BLACK
		material.emission_energy_multiplier = 1.0
		material.metallic = 1.0
		material.roughness = 1.0
		material.vertex_color_use_as_albedo = false
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	if surface_job.ao_strength > 0.0:
		material.vertex_color_use_as_albedo = true
		material.vertex_color_is_srgb = false
	return material


static func _atlas_texture(atlas_size: Vector2i, atlas_data: PackedByteArray) -> ImageTexture:
	var image := Image.create_from_data(atlas_size.x, atlas_size.y, false, Image.FORMAT_RGB8, atlas_data)
	return ImageTexture.create_from_image(image)


func _install(chunk_location: Vector3i, surface_key: PackedInt64Array, entry: Dictionary) -> void:
	var install_started_us := Time.get_ticks_usec()
	var chunk_surface: ArrayMesh = entry.surface
	if chunk_surface == null:
		_retire(chunk_location)
		_displayed_surface_keys[chunk_location] = surface_key
		if profile_surfaces:
			_profile.install_us += Time.get_ticks_usec() - install_started_us
		return
	var chunk_instance: MeshInstance3D = _chunk_instances.get(chunk_location)
	if chunk_instance == null:
		chunk_instance = MeshInstance3D.new()
		chunk_instance.position = Vector3(chunk_location * CHUNK_SIZE)
		add_child(chunk_instance)
		_chunk_instances[chunk_location] = chunk_instance
	chunk_instance.mesh = chunk_surface
	var source_material: Material = entry.material if entry.material else (mesh.surface_get_material(0) if mesh and mesh.get_surface_count() > 0 else null)
	chunk_instance.material_override = _instance_material(chunk_location, source_material)
	chunk_instance.visible = true
	_displayed_surface_keys[chunk_location] = surface_key
	if profile_surfaces:
		_profile.install_us += Time.get_ticks_usec() - install_started_us


func _instance_material(chunk_location: Vector3i, source: Material) -> Material:
	if override_material:
		return override_material
	if source == null:
		_chunk_materials.erase(chunk_location)
		_unshaded_materials.erase(chunk_location)
		return material_builder.call(null) if material_builder.is_valid() else null
	if _chunk_materials.get(chunk_location) != source:
		_chunk_materials[chunk_location] = source
		_unshaded_materials.erase(chunk_location)
	var material: Material = source
	if unshaded:
		material = _unshaded_materials.get(chunk_location)
		if material == null:
			material = source.duplicate()
			var base := material as BaseMaterial3D
			if base:
				base.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			_unshaded_materials[chunk_location] = material
	else:
		_unshaded_materials.erase(chunk_location)
	if material_builder.is_valid():
		return material_builder.call(material)
	return material


func _apply_materials() -> void:
	if not unshaded:
		_unshaded_materials.clear()
	for chunk_location in _chunk_instances:
		var chunk_instance: MeshInstance3D = _chunk_instances[chunk_location]
		chunk_instance.material_override = _instance_material(chunk_location, _chunk_materials.get(chunk_location))


func _retire(chunk_location: Vector3i) -> void:
	if _chunk_instances.has(chunk_location):
		var chunk_instance: MeshInstance3D = _chunk_instances[chunk_location]
		chunk_instance.visible = false
		_retired_chunk_instances.append(chunk_instance)
		_chunk_instances.erase(chunk_location)
	_chunk_materials.erase(chunk_location)
	_unshaded_materials.erase(chunk_location)
	_displayed_surface_keys.erase(chunk_location)
	_inflight_surface_keys.erase(chunk_location)


func is_settled() -> bool:
	return _pending_surface_keys.is_empty()


func reset_profile() -> void:
	_profile = {
		"reaped": 0, "empty": 0, "culled": 0, "consume": 0, "launch": 0, "lost": 0, "truncated": 0,
		"material_us": 0, "cache_us": 0, "install_us": 0, "snapshot_us": 0, "snapshots": 0,
	}


func profile_snapshot() -> Dictionary:
	var snapshot: Dictionary = _profile.duplicate()
	snapshot["pending"] = _pending_surface_keys.size()
	snapshot["inflight"] = _inflight_surface_keys.size()
	snapshot["jobs"] = _surface_jobs.size()
	return snapshot


func refresh() -> void:
	_rebuild()
