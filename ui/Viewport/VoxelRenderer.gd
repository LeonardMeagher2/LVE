class_name VoxelRenderer
extends Node3D

## Draws the chunk meshes of one frame.
##
## Each renderer builds a chunk surface on the worker pool and caches it. All
## renderers share one surface cache and one job map. A hidden workspace still
## finishes its surface work.

## The chunk edge length in cells.
const CHUNK_SIZE := VoxelFrame.CHUNK_SIZE
## The shared surface cache size limit in bytes.
const SURFACE_CACHE_LIMIT_BYTES := 64 * 1024 * 1024
## The shared surface cache entry limit.
const SURFACE_CACHE_LIMIT_ENTRIES := 1024
## The minimum concurrent surface job count.
const SURFACE_JOB_LIMIT_MIN := 2
## The maximum concurrent surface job count.
const SURFACE_JOB_LIMIT_MAX := 8

# All viewports share meshes and jobs. Workers own their input and output arrays.
static var _surface_cache: Dictionary = {}
static var _surface_use_order: Array[PackedInt64Array] = []
static var _surface_cache_bytes := 0
static var _surface_jobs: Dictionary = {}
static var _active_renderer_count := 0
static var _surface_job_limit := 0


# Chunk surfaces are independent. Run them on most of the worker threads and
# leave room for brush, fill, and wand jobs.
static func _job_limit() -> int:
	if _surface_job_limit == 0:
		_surface_job_limit = clampi(OS.get_processor_count() - 1, SURFACE_JOB_LIMIT_MIN, SURFACE_JOB_LIMIT_MAX)
	return _surface_job_limit


## The frame index to draw, or -1 to follow the editor frame.
@export_range(-1, 100, 1, "or_greater") var frame: int = -1:
	set(value):
		if value == frame:
			return
		frame = value
		if is_inside_tree():
			_rebuild()

# Keep the scene's shared voxel material as the source of render settings.
## The shared voxel material. Its surface material is the fallback.
@export var mesh: Mesh
## Whether the renderer reports a Rendering operation.
@export var report_activity := true
## Whether this view records its surface phase counters. A test turns it on to
## attribute the cost of one update. The default off path records nothing.
@export var profile_surfaces := false
## The frame to draw. A null value follows [member frame] or the editor frame.
var source_frame: VoxelFrame:
	set(value):
		if value == source_frame:
			return
		source_frame = value
		if is_inside_tree():
			_rebuild()
## The world axis of the slice, or -1 to draw every layer.
var slice_axis := -1:
	set(value):
		if value == slice_axis:
			return
		slice_axis = value
		if is_inside_tree() and not _slice_setting:
			_rebuild()
## The first cell index of the slice along [member slice_axis].
var slice_index := 0:
	set(value):
		if value == slice_index:
			return
		slice_index = value
		if is_inside_tree() and not _slice_setting:
			_rebuild()
## The number of slice layers from [member slice_index].
var slice_count := 1:
	set(value):
		value = maxi(value, 1)
		if value == slice_count:
			return
		slice_count = value
		if is_inside_tree() and not _slice_setting:
			_rebuild()
# Whether one slice request is assigning its three values. A batch request
# rebuilds once, so a layer-count drag pays one rebuild per step.
var _slice_setting := false


## Applies one slice in one rebuild. The three values are one request, so a
## layer-count drag pays one rebuild per step, not one per property.
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
var _pending_surface_keys: Dictionary = {}
# The one surface key this renderer may install from a completed build for each
# chunk. A chunk holds at most one in-flight key, so the installs of one chunk
# follow the request order and an older result can never replace a newer one.
# A context change drops every entry, so a result built before the change is
# never installed.
var _inflight_surface_keys: Dictionary = {}
var _retired_chunk_instances: Array[MeshInstance3D] = []
var _displayed_frame: VoxelFrame
var _operation_id := 0
var _reported_remaining := -1
# The one frame snapshot shared by every surface build launched in the current
# update. `copy_frame()` marks the live chunks shared, so a later write copies a
# chunk before it mutates and the snapshot stays frozen. One snapshot per update
# replaces one dictionary copy per chunk launch. It is dropped at the start of
# the next update, so it never outlives the pass it serves.
var _launch_snapshot: VoxelFrame
# The per-instance surface phase counters of `profile_surfaces`. The microseconds
# are totals since the last `reset_profile`. `material_us` is the build of a
# finished chunk material and `cache_us` is the cache write of that result,
# including the atlas readback that `_texture_bytes` counts. The counts name the
# number of reaped, empty, consumed, launched, lost, and slice-truncated events.
var _profile := {
	"reaped": 0, "empty": 0, "culled": 0, "consume": 0, "launch": 0, "lost": 0, "truncated": 0,
	"material_us": 0, "cache_us": 0, "install_us": 0, "snapshot_us": 0, "snapshots": 0,
}


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
	_launch_snapshot = null


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
	# A rebuild follows a context change: a document, a frame, a shading mode, a
	# history restore, or a refresh. Every result built before it belongs to the
	# previous context, so it leaves the install set.
	_inflight_surface_keys.clear()
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
	# A changed cell rebuilds its own chunk and each neighbor that reads it.
	var affected_chunks := {}
	for cell_position in affected_cells:
		var chunk_location := VoxelFrame.chunk_position(cell_position)
		affected_chunks[chunk_location] = true
		for offset in VoxelFrame.crosstalk_chunks(cell_position):
			affected_chunks[chunk_location + offset] = true
	for chunk_location in affected_chunks:
		_request(active_frame, chunk_location)
	_report_activity()


func _request(active_frame: VoxelFrame, chunk_location: Vector3i) -> void:
	if not active_frame.chunks.has(chunk_location):
		_pending_surface_keys.erase(chunk_location)
		_inflight_surface_keys.erase(chunk_location)
		_retire(chunk_location)
		return
	if slice_axis >= 0:
		# A slice holds a range of layers, so only the chunk rows that cross the
		# range can emit a face. Requesting the other rows would build empty
		# surfaces.
		var first_row := VoxelFrame.chunk_position(Vector3i(slice_index, slice_index, slice_index))[slice_axis]
		var last_row := VoxelFrame.chunk_position(Vector3i(slice_index + slice_count - 1, slice_index + slice_count - 1, slice_index + slice_count - 1))[slice_axis]
		if chunk_location[slice_axis] < first_row or chunk_location[slice_axis] > last_row:
			_pending_surface_keys.erase(chunk_location)
			_inflight_surface_keys.erase(chunk_location)
			_retire(chunk_location)
			return
	var surface_key := _signature(active_frame, chunk_location, State.document.smooth_normals, slice_axis, slice_index, slice_count, State.document.ao_strength)
	if _displayed_surface_keys.get(chunk_location) == surface_key:
		# The exact wanted surface is already on screen, so no result may replace
		# it. Drop the newest request and any in-flight eligibility with it.
		_pending_surface_keys.erase(chunk_location)
		_inflight_surface_keys.erase(chunk_location)
		if _chunk_instances.has(chunk_location):
			_chunk_instances[chunk_location].visible = true
	else:
		_pending_surface_keys[chunk_location] = surface_key
		# Keep the completed mesh visible until the replacement is ready.


# The edit reports each changed chunk and each neighbor that meshes across a
# changed face, so no neighbor expansion is needed here. A large edit lists a
# shared neighbor once per changed chunk, so request each chunk once.
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
	_report_activity()


# The exact surface identity of one chunk, as a packed integer key. Element zero
# is the shading mode. Each later pair is one neighbor in `neighbor_offsets`
# order: its instance id and its voxel revision. A missing neighbor writes the
# pair (0, 0), and a live instance id is never zero. The key holds every value
# that changes the surface, so a content-equal key matches exactly.
#
# A packed array passes by reference. Never write to a key after a dictionary
# holds it, or the key's hash and content disagree.
static func _signature(active_frame: VoxelFrame, chunk_location: Vector3i, smooth_normals: bool, slice_axis := -1, slice_index := 0, slice_count := 1, ao_strength := 0.0) -> PackedInt64Array:
	# AO reads the corner neighbors for every face vertex, so the key must watch
	# the diagonal chunks too.
	var ao_enabled := ao_strength > 0.0
	var offsets := VoxelMeshBuilder.neighbor_offsets(smooth_normals or ao_enabled)
	var surface_key := PackedInt64Array()
	# A slice build appends its layers, so a normal key keeps its exact length.
	var tail := 4 if slice_axis >= 0 else 0
	# The strength is appended only when AO is on, so a build without AO keeps the
	# original key length.
	var extra := 1 if ao_enabled else 0
	surface_key.resize(1 + offsets.size() * 2 + tail + extra)
	surface_key[0] = (1 if smooth_normals else 0) | (2 if ao_enabled else 0)
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


## Returns the work slice of one update in microseconds. A test can shorten it to
## prove the phase ordering without a slow native bake.
func _work_slice_us() -> int:
	return State.WORK_SLICE_US


func _update_surfaces() -> void:
	var update_started_us := Time.get_ticks_usec()
	var slice_us := _work_slice_us()
	var active_frame := _get_frame()
	# The launches of this update share one frame snapshot, made on the first
	# launch. Dropping it here bounds its life to this pass.
	_launch_snapshot = null
	# A completed in-flight result that this view already holds in the shared cache
	# installs before the finished builds are reaped and baked. One atlas bake can
	# spend the whole work slice, so without this pass a ready result would wait
	# for a later frame even though it is fully available. A consume follows the
	# same in-flight rules as the loop below, so the install order and the request
	# order are unchanged.
	for chunk_location in _inflight_surface_keys.keys():
		if _consume_inflight(chunk_location):
			_launch_surface(chunk_location, active_frame)
		if Time.get_ticks_usec() - update_started_us >= slice_us:
			if profile_surfaces:
				_profile.truncated += 1
			return
	for surface_key in _surface_jobs.keys():
		var surface_job: VoxelMeshBuilder = _surface_jobs[surface_key]
		if WorkerThreadPool.is_task_completed(surface_job.worker_task_id):
			var reap_started_us := Time.get_ticks_usec()
			WorkerThreadPool.wait_for_task_completion(surface_job.worker_task_id)
			var chunk_surface: ArrayMesh = null
			if not surface_job.surface_arrays[Mesh.ARRAY_VERTEX].is_empty():
				chunk_surface = ArrayMesh.new()
				chunk_surface.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_job.surface_arrays)
			var material := _build_material(surface_job)
			var cache_started_us := Time.get_ticks_usec()
			_cache_surface(surface_key, chunk_surface, surface_job.geometry_bytes, material)
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
	# One chunk owns at most one in-flight key. Consume a completed in-flight
	# result before the newest request for that chunk is launched, so a newer
	# result is never replaced by an older one. A consumed result may be older
	# than the newest request, and it still installs: it is a true state of the
	# model, and the newest request follows it in the same frame.
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


# Installs this renderer's in-flight result for one chunk when the shared cache
# holds it. Returns true when it consumed one. The shared cache is keyed by the
# exact surface identity, so a hit is always the surface of that exact state.
func _consume_inflight(chunk_location: Vector3i) -> bool:
	if not _inflight_surface_keys.has(chunk_location):
		return false
	# Only a chunk the renderer still requests is installed. A chunk the frame no
	# longer holds leaves the request set first, and its result must not appear.
	if not _pending_surface_keys.has(chunk_location):
		_inflight_surface_keys.erase(chunk_location)
		return false
	var surface_key: PackedInt64Array = _inflight_surface_keys[chunk_location]
	if not _surface_cache.has(surface_key):
		if _surface_jobs.has(surface_key):
			# The build still runs. Wait for its result.
			return false
		# The key left the cache and the job map. Another view reaped the build and
		# the cache then evicted the result, so it can never install. Drop this
		# eligibility, so the newest request is scheduled against the current
		# frame. The retired key is never rebuilt.
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


# Asks for one chunk's newest wanted surface. It installs a cached result at
# once, adopts a result another renderer already builds, or starts one job while
# the global job limit allows. A chunk that already owns an in-flight key waits
# for that key, so the newest request stays pending until it is launched.
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
		# Another renderer builds this exact surface already. Adopt it, so this
		# renderer installs the shared result without a second build.
		_inflight_surface_keys[chunk_location] = surface_key
		return
	if active_frame == null or not active_frame.chunks.has(chunk_location):
		_pending_surface_keys.erase(chunk_location)
		return
	if _surface_jobs.size() >= _job_limit():
		return
	var surface_job := VoxelMeshBuilder.new()
	surface_job.source_frame = _snapshot_for_launch(active_frame)
	surface_job.chunk_location = chunk_location
	surface_job.smooth_normals = State.document.smooth_normals
	surface_job.ao_strength = State.document.ao_strength
	surface_job.slice_axis = slice_axis
	surface_job.slice_index = slice_index
	surface_job.slice_count = slice_count
	surface_job.worker_task_id = WorkerThreadPool.add_task(surface_job.run, false, "Voxel surface")
	_surface_jobs[surface_key] = surface_job
	_inflight_surface_keys[chunk_location] = surface_key
	if profile_surfaces:
		_profile.launch += 1


# Returns the read-only frame snapshot for the launches of this update. The first
# launch makes it and every later launch in the same update shares it. The live
# frame does not change during one update, so one snapshot gives exactly what a
# copy per launch gave, without one dictionary copy per chunk. `copy_frame()`
# marks the live chunks shared, so a later write copies a chunk before it mutates
# and every worker keeps reading the frozen chunk.
func _snapshot_for_launch(active_frame: VoxelFrame) -> VoxelFrame:
	if _launch_snapshot == null:
		var started_us := Time.get_ticks_usec()
		_launch_snapshot = active_frame.copy_frame()
		if profile_surfaces:
			_profile.snapshot_us += Time.get_ticks_usec() - started_us
			_profile.snapshots += 1
	return _launch_snapshot


# Marks one installed or cached surface as the most recently used entry.
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
	var total_bytes := geometry_bytes + _texture_bytes(material)
	_surface_cache[surface_key] = {"surface": chunk_surface, "material": material, "bytes": total_bytes}
	_surface_use_order.append(surface_key)
	_surface_cache_bytes += total_bytes
	while (_surface_cache_bytes > SURFACE_CACHE_LIMIT_BYTES or _surface_cache.size() > SURFACE_CACHE_LIMIT_ENTRIES) and _surface_use_order.size() > 1:
		var oldest_surface_key: PackedInt64Array = _surface_use_order.pop_front()
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
	var material: StandardMaterial3D
	if surface_job.atlas:
		material = surface_job.atlas.create_material(shared_material as StandardMaterial3D)
	else:
		material = shared_material.duplicate() if shared_material is StandardMaterial3D else StandardMaterial3D.new()
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
	if surface_job.ao_strength > 0.0:
		# The vertex color is a linear AO multiplier on the atlas albedo.
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
	chunk_instance.material_override = entry.material if entry.material else (mesh.surface_get_material(0) if mesh and mesh.get_surface_count() > 0 else null)
	chunk_instance.visible = true
	_displayed_surface_keys[chunk_location] = surface_key
	if profile_surfaces:
		_profile.install_us += Time.get_ticks_usec() - install_started_us


func _retire(chunk_location: Vector3i) -> void:
	if _chunk_instances.has(chunk_location):
		var chunk_instance: MeshInstance3D = _chunk_instances[chunk_location]
		chunk_instance.visible = false
		_retired_chunk_instances.append(chunk_instance)
		_chunk_instances.erase(chunk_location)
	_displayed_surface_keys.erase(chunk_location)
	# A retired chunk owns no surface, so a result still building for it must not
	# appear later.
	_inflight_surface_keys.erase(chunk_location)


## Returns [code]true[/code] when no surface request is pending.
func is_settled() -> bool:
	return _pending_surface_keys.is_empty()


## Clears the surface phase counters of [member profile_surfaces].
func reset_profile() -> void:
	_profile = {
		"reaped": 0, "empty": 0, "culled": 0, "consume": 0, "launch": 0, "lost": 0, "truncated": 0,
		"material_us": 0, "cache_us": 0, "install_us": 0, "snapshot_us": 0, "snapshots": 0,
	}


## Returns the surface phase counters with the current queue sizes added. The
## microseconds attribute one update: `cache_us` holds the bake of a finished
## build, including the atlas readback, `material_us` holds the build of its
## material, and `install_us` holds the installs. `truncated` counts the updates
## that stopped at the work slice with work still queued.
func profile_snapshot() -> Dictionary:
	var snapshot: Dictionary = _profile.duplicate()
	snapshot["pending"] = _pending_surface_keys.size()
	snapshot["inflight"] = _inflight_surface_keys.size()
	snapshot["jobs"] = _surface_jobs.size()
	return snapshot


## Rebuilds every displayed chunk surface.
func refresh() -> void:
	_rebuild()
