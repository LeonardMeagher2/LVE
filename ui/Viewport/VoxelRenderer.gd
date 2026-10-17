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
	var active_frame := _get_frame()
	if active_frame != _displayed_frame:
		for chunk_instance in _chunk_instances.values():
			chunk_instance.visible = false
		_displayed_frame = active_frame
	_pending_surface_keys.clear()
	for chunk_location in _displayed_surface_keys.keys():
		if active_frame == null or not active_frame.chunks.has(chunk_location):
			_retire(chunk_location)
	if active_frame:
		for chunk_location in active_frame.chunks:
			_request(active_frame, chunk_location)
	_report_activity()


func _update(updated_frame: int, affected_cells: Array[Vector3i]) -> void:
	if updated_frame != (frame if frame >= 0 else State.current_frame):
		return
	if affected_cells.is_empty():
		_rebuild()
		return
	var active_frame := _get_frame()
	var affected_chunks := {}
	var offsets := VoxelMeshBuilder.neighbor_offsets(State.document.smooth_normals)
	for cell_position in affected_cells:
		for offset in offsets:
			affected_chunks[VoxelFrame.chunk_position(cell_position + offset)] = true
	for chunk_location in affected_chunks:
		_request(active_frame, chunk_location)
	_report_activity()


func _request(active_frame: VoxelFrame, chunk_location: Vector3i) -> void:
	if not active_frame.chunks.has(chunk_location):
		_pending_surface_keys.erase(chunk_location)
		_retire(chunk_location)
		return
	var surface_key := _signature(active_frame, chunk_location, State.document.smooth_normals)
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
	var active_frame := _get_frame()
	var affected_chunks := {}
	var offsets := VoxelMeshBuilder.neighbor_offsets(State.document.smooth_normals)
	for chunk_location in chunk_positions:
		for offset in offsets:
			affected_chunks[chunk_location + offset] = true
	for chunk_location in affected_chunks:
		_request(active_frame, chunk_location)
	_report_activity()


static func _signature(active_frame: VoxelFrame, chunk_location: Vector3i, smooth_normals: bool) -> String:
	var surface_key := "smooth/" if smooth_normals else "flat/"
	for offset in VoxelMeshBuilder.neighbor_offsets(smooth_normals):
		var chunk: VoxelFrame.Chunk = active_frame.chunks.get(chunk_location + offset)
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
			_cache_surface(surface_key, chunk_surface, surface_job.geometry_bytes, _build_material(surface_job))
			_surface_jobs.erase(surface_key)
		if Time.get_ticks_usec() - update_started_us >= State.WORK_SLICE_US:
			return
	var active_frame := _get_frame()
	for chunk_location in _pending_surface_keys.keys():
		var surface_key: String = _pending_surface_keys[chunk_location]
		if _surface_cache.has(surface_key):
			_install(chunk_location, surface_key, _surface_cache[surface_key])
			_pending_surface_keys.erase(chunk_location)
			_surface_use_order.erase(surface_key)
			_surface_use_order.append(surface_key)
		elif not _surface_jobs.has(surface_key) and _surface_jobs.size() < MAX_SURFACE_JOBS:
			var surface_job := VoxelMeshBuilder.new()
			surface_job.source_frame = active_frame.copy_frame()
			surface_job.chunk_location = chunk_location
			surface_job.smooth_normals = State.document.smooth_normals
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


static func _cache_surface(surface_key: String, chunk_surface: ArrayMesh, geometry_bytes: int, material: StandardMaterial3D) -> void:
	var total_bytes := geometry_bytes + _texture_bytes(material)
	_surface_cache[surface_key] = {"surface": chunk_surface, "material": material, "bytes": total_bytes}
	_surface_use_order.append(surface_key)
	_surface_cache_bytes += total_bytes
	while (_surface_cache_bytes > SURFACE_CACHE_LIMIT_BYTES or _surface_cache.size() > SURFACE_CACHE_LIMIT_ENTRIES) and _surface_use_order.size() > 1:
		var oldest_surface_key: String = _surface_use_order.pop_front()
		_surface_cache_bytes -= _surface_cache[oldest_surface_key].bytes
		_surface_cache.erase(oldest_surface_key)


static func _texture_bytes(material: StandardMaterial3D) -> int:
	if material == null:
		return 0
	var counted := {}
	var total_bytes := 0
	for texture in [material.albedo_texture, material.metallic_texture, material.roughness_texture, material.emission_texture]:
		if texture is ImageTexture and not counted.has(texture):
			counted[texture] = true
			total_bytes += texture.get_image().get_data().size()
	return total_bytes


# Build one material for a chunk that holds materials. Every other chunk keeps
# the shared material, so a document without materials renders as before.
func _build_material(surface_job: VoxelMeshBuilder) -> StandardMaterial3D:
	if surface_job.atlas_size.x == 0:
		return null
	var shared_material: Material = mesh.surface_get_material(0) if mesh and mesh.get_surface_count() > 0 else null
	if surface_job.atlas:
		return surface_job.atlas.create_material(shared_material as StandardMaterial3D)
	var material: StandardMaterial3D = shared_material.duplicate() if shared_material is StandardMaterial3D else StandardMaterial3D.new()
	var finish_texture := _atlas_texture(surface_job.atlas_size, surface_job.atlas_orm)
	material.albedo_texture = _atlas_texture(surface_job.atlas_size, surface_job.atlas_albedo)
	# A StandardMaterial3D ignores `orm_texture`. Bind the packed atlas to the
	# metallic and the roughness slot, and pick the blue and the green channel.
	material.metallic_texture = finish_texture
	material.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	material.roughness_texture = finish_texture
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	material.emission_texture = _atlas_texture(surface_job.atlas_size, surface_job.atlas_emission)
	# The default add operator sums the emission color and the emission texture.
	# A black color adds no light, so the texture alone carries the emission.
	material.emission_enabled = true
	material.emission = Color.BLACK
	material.emission_energy_multiplier = 1.0
	material.metallic = 1.0
	material.roughness = 1.0
	material.vertex_color_use_as_albedo = false
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return material


static func _atlas_texture(atlas_size: Vector2i, atlas_data: PackedByteArray) -> ImageTexture:
	var image := Image.create_from_data(atlas_size.x, atlas_size.y, false, Image.FORMAT_RGB8, atlas_data)
	return ImageTexture.create_from_image(image)


func _install(chunk_location: Vector3i, surface_key: String, entry: Dictionary) -> void:
	var chunk_surface: ArrayMesh = entry.surface
	if chunk_surface == null:
		_retire(chunk_location)
		_displayed_surface_keys[chunk_location] = surface_key
		return
	var chunk_instance: MeshInstance3D = _chunk_instances.get(chunk_location)
	if chunk_instance == null:
		chunk_instance = MeshInstance3D.new()
		chunk_instance.position = Vector3(chunk_location * CHUNK_SIZE)
		add_child(chunk_instance)
		_chunk_instances[chunk_location] = chunk_instance
	chunk_instance.mesh = chunk_surface
	chunk_instance.material_override = entry.material if entry.material else (mesh.surface_get_material(0) if mesh and mesh.get_surface_count() > 0 else null)
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
