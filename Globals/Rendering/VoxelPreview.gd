extends MeshInstance3D

## Draws the tool cursor and the selection outline in the viewport.
##
## The preview builds its mesh on a worker for a large request, so it installs
## a frame later instead of stalling the frame that asked for it. It caches
## built surfaces up to a byte and entry limit. A progressive selection keeps
## the running outline and queues only the newest snapshot.

## The shape that the preview draws.
enum PreviewStyle {
	## A line outline around the cells.
	OUTLINE,
	## A solid surface of the cells.
	SOLID,
}

# An inline outline runs inside the request on the main thread. The measured scan
# costs about 2 us per selected cell on a dense shape and about 12 us on a
# scattered one. The shared work slice is 3000 us, so the conservative limit is
# about 250 cells. A larger outline goes to a worker and installs a frame later
# instead of stalling the frame that asked for it.
## The largest outline that builds inline on the main thread.
const INLINE_OUTLINE_LIMIT := 256
# The delay that debounces a large outline is separate from the inline budget. A
# mid-size outline still starts at once, on a worker.
## The cell count above which a large outline waits one debounce delay.
const OUTLINE_DELAY_LIMIT := 4096
## The mesh cache size limit in bytes.
const CACHE_LIMIT_BYTES := 64 * 1024 * 1024
## The mesh cache entry limit.
const CACHE_LIMIT_ENTRIES := 16

## Whether a new request keeps the running worker instead of cancelling it. A
## live cursor opts in, so it installs a bounded-latency snapshot in request
## order instead of starving when the pointer changes the request every frame.
## The strict default cancels, so Line, Paste, and the selection stay
## latest-only.
@export var coalesce_requests := false

static var _mesh_cache := {}
static var _cache_order: Array[String] = []
static var _cache_bytes := 0
static var _preview_count := 0
static var _install_frame := -1
static var _install_time_us := 0

var _single_cell_outline: ArrayMesh
var _requested_cells := {}
var _requested_style := PreviewStyle.OUTLINE
var _requested_voxel_colors := false
var _requested_smooth_normals := false
var _requested_color_key := Color.WHITE
var _requested_cache_key := ""
var _request_revision := 0
var _pending_cells := {}
var _request_due_ms := 0
var _preview_job: PreviewJob
var _operation_id := 0
# The request revision of the last installed strict surface. The opt-in
# coalescing path installs a completed snapshot only when its revision is newer,
# so an older worker can never overwrite a newer exact or cached surface.
var _installed_revision := 0
# The immutable cells of the last installed surface. A coalescing caller reads
# them to match a visible preview to the sample that a click will paint. A clear
# empties the set, so a hidden preview never offers stale cells.
var _installed_cells := {}
# The progressive selection path. The wand streams a growing selection, so a new
# snapshot must not cancel the outline that is already building. The path is
# opt-in, so the brush and cursor keep the strict latest-only behavior.
var _stream_job: PreviewJob
var _stream_source: VoxelSelection
var _stream_has_pending := false
# Bumped when a clear or a strict request supersedes the stream. A running stream
# outline installs only while its epoch still matches.
var _stream_epoch := 0
# True while the latest strict request still owns the preview. A stream publish
# clears it, so a strict request repeated after a stream reinstalls its exact
# result instead of trusting the stale requested set and leaving the stream on
# screen.
var _strict_alive := false
var _box := BoxMesh.new()
var _outline_material: Material
var _solid_material := preload("res://VoxelMaterial.tres").duplicate()
var _primitive_material := preload("res://VoxelMaterial.tres").duplicate()
var _brush_material := VoxelFrame.material(Color.WHITE)

## One cancellable preview job that runs on the worker pool.
##
## The job holds a snapshot of the cells and builds the outline or the solid
## mesh. [method VoxelFrame.EditJob.run] is the worker body.
class PreviewJob extends VoxelFrame.EditJob:
	## The cells to draw, keyed by cell position.
	var cells := {}
	## The shape to build.
	var style := PreviewStyle.OUTLINE
	## Whether a solid mesh reads the per-cell voxel colors.
	var use_voxel_colors := false
	## Whether a solid mesh uses smooth normals.
	var smooth_normals := false
	## The color that replaces a transparent cell color.
	var color_key := Color.WHITE
	## The strict request id that the job belongs to.
	var revision := 0
	# The stream epoch of a progressive selection job. The strict `revision` above
	# is the request id of the strict path.
	## The stream epoch that the job belongs to.
	var stream_epoch := 0
	## The mesh cache key of the job.
	var cache_key := ""
	## The built mesh arrays, indexed by [enum Mesh.ArrayType].
	var arrays := []
	## The per-chunk atlas surfaces of a solid mesh.
	var atlas_surfaces: Array[VoxelMeshBuilder] = []
	## The estimated geometry byte count.
	var geometry_bytes := 0
	## The callable that builds an outline from a selection.
	var outline_builder: Callable

	## Builds the mesh arrays. This is the worker body.
	func run() -> void:
		if style == PreviewStyle.OUTLINE:
			var selection := VoxelSelection.new()
			selection.restore(cells)
			stage("Building preview outline", cells.size())
			var outline_vertices: PackedVector3Array = outline_builder.call(selection, self)
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = outline_vertices
			geometry_bytes = outline_vertices.size() * 12
			return
		stage("Preparing solid preview", cells.size())
		var colors := {}
		var use_material_atlas := false
		for cell_position in cells:
			var value = cells[cell_position]
			if use_voxel_colors and value is PackedFloat32Array:
				colors[cell_position] = value
				use_material_atlas = true
			else:
				var color: Color = value if value is Color else VoxelFrame.material_color(value)
				colors[cell_position] = VoxelFrame.material((color_key if color == Color.TRANSPARENT else color) if use_voxel_colors else Color.WHITE)
			if colors.size() % 4096 == 0 and not checkpoint(colors.size()):
				return
		var frame := VoxelFrame.new()
		frame.set_cells(colors, self)
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		var vertex_colors := PackedColorArray()
		var indices := PackedInt32Array()
		stage("Building solid preview", frame.chunks.size())
		var completed := 0
		for chunk_location: Vector3i in frame.chunks:
			if not checkpoint(completed):
				return
			var job := VoxelMeshBuilder.new()
			job.source_frame = frame
			job.chunk_location = chunk_location
			job.smooth_normals = smooth_normals
			job.texture_materials = use_material_atlas
			job.run()
			if job.surface_arrays[Mesh.ARRAY_VERTEX].is_empty():
				completed += 1
				continue
			var chunk_origin := Vector3(chunk_location * VoxelFrame.CHUNK_SIZE)
			if job.atlas_size.x > 0:
				var chunk_vertices: PackedVector3Array = job.surface_arrays[Mesh.ARRAY_VERTEX]
				for index in chunk_vertices.size():
					chunk_vertices[index] += chunk_origin
				job.surface_arrays[Mesh.ARRAY_VERTEX] = chunk_vertices
				atlas_surfaces.append(job)
				geometry_bytes += job.geometry_bytes + job.atlas_albedo.size() + job.atlas_orm.size() + job.atlas_emission.size()
				completed += 1
				continue
			var vertex_offset := vertices.size()
			for vertex in job.surface_arrays[Mesh.ARRAY_VERTEX]:
				vertices.append(vertex + chunk_origin)
			normals.append_array(job.surface_arrays[Mesh.ARRAY_NORMAL])
			vertex_colors.append_array(job.surface_arrays[Mesh.ARRAY_COLOR])
			for index in job.surface_arrays[Mesh.ARRAY_INDEX]:
				indices.append(index + vertex_offset)
			completed += 1
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = vertex_colors
		arrays[Mesh.ARRAY_INDEX] = indices
		geometry_bytes += vertices.size() * 40 + indices.size() * 4


func _enter_tree() -> void:
	_preview_count += 1
	State.model_settings_changed.connect(_on_model_settings_changed)
	State.document_changed.connect(_on_model_settings_changed)


func _on_model_settings_changed() -> void:
	if _requested_style == PreviewStyle.SOLID and not _requested_cells.is_empty():
		_request(_requested_cells, _requested_style, _requested_voxel_colors, _requested_color_key)
		# A coalescing caller keeps its running worker. When the settings really
		# changed, that worker holds the old shading, so cancel it now. A job that
		# `_request` just started, or a deduped request, is already current.
		if _preview_job and _preview_job.revision != _request_revision:
			_preview_job.cancel()


func _ready() -> void:
	_outline_material = material_override
	_solid_material.albedo_color = Color.WHITE
	_primitive_material.vertex_color_use_as_albedo = false


## Sets the brush cursor color.
func set_brush_color(color: Color) -> void:
	set_brush_material(VoxelFrame.material(color))


## Sets the full brush cursor material. The material carries the color, the
## emission, the metallic, and the roughness.
func set_brush_material(cell_material: PackedFloat32Array) -> void:
	_brush_material = cell_material.duplicate()
	_apply_material(_primitive_material, cell_material)
	if not _requested_voxel_colors:
		_apply_material(_solid_material, cell_material)


static func _apply_material(target: StandardMaterial3D, cell_material: PackedFloat32Array) -> void:
	target.albedo_color = VoxelFrame.material_color(cell_material)
	var base := VoxelFrame.MATERIAL_EMISSION
	target.emission = Color(cell_material[base], cell_material[base + 1], cell_material[base + 2])
	target.emission_enabled = target.emission != Color.BLACK
	target.emission_energy_multiplier = 1.0
	target.metallic = cell_material[VoxelFrame.MATERIAL_METALLIC]
	target.roughness = cell_material[VoxelFrame.MATERIAL_ROUGHNESS]
	target.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	target.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX


## Shows the brush cells. [param outline] draws a line outline. A
## [param cube_diameter] above zero uses one box mesh for a cube brush.
## [param use_voxel_colors] reads a full material from each cell value.
func show_voxels(colors: Dictionary, color: Color, outline: bool = false, cube_diameter: int = 0, use_voxel_colors: bool = true) -> void:
	if colors.is_empty():
		_clear_request()
		return
	if outline:
		material_override = _outline_material
		_request(colors, PreviewStyle.OUTLINE)
		return
	# A cube's voxels have the same six faces as a box, so above the caller's limit
	# the box is exact and costs nothing. A shape whose voxels are stepped has no
	# exact primitive, so it stays per-cell.
	if cube_diameter > 0:
		_clear_request()
		_box.size = Vector3.ONE * cube_diameter
		_primitive_material.albedo_color = color
		material_override = _primitive_material
		mesh = _box
		position = Vector3.ONE * -0.5 if cube_diameter % 2 == 0 else Vector3.ZERO
		visible = true
		return
	if use_voxel_colors:
		_apply_material(_solid_material, VoxelFrame.material(Color.WHITE))
	else:
		_apply_material(_solid_material, _brush_material)
		_solid_material.albedo_color = color
	# Full per-cell materials use the cached surfaces' atlas materials.
	material_override = _solid_material
	if use_voxel_colors:
		for cell in colors:
			if colors[cell] is PackedFloat32Array:
				material_override = null
				break
	_request(colors, PreviewStyle.SOLID, use_voxel_colors, color if use_voxel_colors else Color.WHITE)


# Show a selection outline. A progressive request keeps the running outline job
# alive and queues only the newest snapshot, so an in-flight intermediate outline
# can finish and install. A strict request cancels the stream and takes over.
## Shows a selection outline. [param progressive] keeps the running outline and
## queues only the newest snapshot. A null or empty selection hides the preview.
func show_selection(selection: VoxelSelection, progressive := false) -> void:
	if selection == null or selection.is_empty():
		_clear_request()
		return
	material_override = _outline_material
	if progressive:
		_queue_stream(selection)
		return
	# `all_cells` hands out the live cells without marking the selection shared, so
	# the request copy below does not force a second copy on the next add.
	_request(selection.all_cells(), PreviewStyle.OUTLINE)


# Queue the newest snapshot for the progressive path. The stream takes over the
# preview: the pending strict request is dropped and the running strict job is
# cancelled, so a delayed strict request cannot revive and overwrite the stream.
# The running stream job is not cancelled. The snapshot is read when a job starts,
# so many publishes between two outlines cost nothing and no stale snapshot is built.
func _queue_stream(selection: VoxelSelection) -> void:
	_request_revision += 1
	_strict_alive = false
	_pending_cells = {}
	_request_due_ms = 0
	if _preview_job:
		_preview_job.cancel()
	_stream_source = selection
	_stream_has_pending = true
	_start_activity()
	_start_stream()


func _start_stream() -> void:
	if _stream_job or not _stream_has_pending or _stream_source == null:
		return
	if _preview_job:
		# A strict job still winds down. Keep the newest snapshot until the strict
		# job is joined and discarded, so the stream result is not lost.
		return
	var job := _new_job()
	# Snapshot the live selection now, so the worker reads a stable set. The copy
	# happens once per started outline, not once per publish.
	job.cells = _stream_source.all_cells().duplicate()
	job.outline_builder = _outline_vertices
	job.style = PreviewStyle.OUTLINE
	job.stream_epoch = _stream_epoch
	_stream_has_pending = false
	_stream_source = null
	_stream_job = job
	job.worker_task_id = WorkerThreadPool.add_task(job.run, false, "Voxel preview")


func _finish_stream() -> void:
	var job := _stream_job
	_stream_job = null
	# A clear or a strict request superseded the stream while the outline built, so
	# its stale surface must not appear.
	if job.stream_epoch == _stream_epoch and job.checkpoint(0):
		_install_surface(job, false)
	_start_stream()


# Drop the queued snapshot and cancel the running stream outline. A clear or a
# strict request supersedes the stream, so a later stream install is discarded.
func _cancel_stream() -> void:
	_stream_epoch += 1
	_stream_has_pending = false
	_stream_source = null
	if _stream_job:
		_stream_job.cancel()


func _request(cells: Dictionary, style: PreviewStyle, use_voxel_colors: bool = false, color_key: Color = Color.WHITE) -> void:
	_cancel_stream()
	var colored := style == PreviewStyle.SOLID and use_voxel_colors
	var smooth_normals := style == PreviewStyle.SOLID and State.document.smooth_normals
	# The dedupe trusts the requested set only while the strict request still owns
	# the preview. A stream publish clears that ownership, so a strict request
	# repeated after a stream reinstalls its exact result.
	if _strict_alive and style == _requested_style and use_voxel_colors == _requested_voxel_colors and smooth_normals == _requested_smooth_normals and color_key == _requested_color_key and _same_cells(_requested_cells, cells, colored):
		return
	_request_revision += 1
	_strict_alive = true
	# A coalescing caller wants the newest snapshot, not a restart. It keeps the
	# running worker and installs its result in request order, so a continuous
	# change never starves. The strict default cancels, so its request wins alone.
	if _preview_job and not coalesce_requests:
		_preview_job.cancel()
	_requested_style = style
	_requested_voxel_colors = use_voxel_colors
	_requested_smooth_normals = smooth_normals
	_requested_color_key = color_key
	_requested_cells = cells if cells.is_read_only() else cells.duplicate(true)
	_requested_cells.make_read_only()
	_pending_cells = {}
	_request_due_ms = 0
	var cache_key := _cache_key(_requested_cells, style, colored, color_key, smooth_normals)
	_requested_cache_key = cache_key
	var cached: Dictionary = _mesh_cache.get(cache_key, {})
	if not cached.is_empty() and cached.color_key == color_key and _same_cells(cached.cells, _requested_cells, colored):
		mesh = cached.surface
		position = Vector3.ZERO
		visible = true
		_cache_order.erase(cache_key)
		_cache_order.append(cache_key)
		_installed_revision = _request_revision
		_installed_cells = cached.cells
		_finish_activity()
		return
	_pending_cells = _requested_cells
	_request_due_ms = Time.get_ticks_msec() + 100 if style == PreviewStyle.OUTLINE and cells.size() > OUTLINE_DELAY_LIMIT else 0
	_start_activity()
	_start_preview()


static func _same_cells(first: Dictionary, second: Dictionary, colored: bool) -> bool:
	if is_same(first, second):
		return true
	if colored:
		return first == second
	if first.size() != second.size():
		return false
	for cell_position in first:
		if not second.has(cell_position):
			return false
	return true


static func _cache_key(cells: Dictionary, style: PreviewStyle, colored: bool, color_key: Color, smooth_normals: bool) -> String:
	var cell_hash := cells.hash() if colored else cells.keys().hash()
	return "%d:%s:%d:%s:%s" % [style, colored, cell_hash, color_key, smooth_normals]


func _clear_request() -> void:
	_request_revision += 1
	# A clear must not let an in-flight worker install after the hide. The
	# installed revision moves past every running job, so none can reappear.
	_installed_revision = _request_revision
	_installed_cells = {}
	_strict_alive = false
	_requested_cells = {}
	_pending_cells = {}
	_request_due_ms = 0
	if _preview_job:
		_preview_job.cancel()
	_cancel_stream()
	visible = false
	_finish_activity()


## Shows the single-cell cursor at one cell. [constant VoxelPicking.NONE] hides
## it.
func show_cell(cell_position: Vector3i) -> void:
	_clear_request()
	if cell_position == VoxelPicking.NONE:
		visible = false
		return
	if _single_cell_outline == null:
		var single_cell_selection := VoxelSelection.new()
		single_cell_selection.add(Vector3i.ZERO)
		_single_cell_outline = outline_mesh(single_cell_selection)
	mesh = _single_cell_outline
	material_override = _outline_material
	position = Vector3(cell_position)
	visible = true


## Returns a line mesh for one selection.
static func outline_mesh(selection: VoxelSelection) -> ArrayMesh:
	return _mesh_from_vertices(_outline_vertices(selection))


static func _mesh_from_vertices(outline_vertices: PackedVector3Array) -> ArrayMesh:
	var outline_surface := ArrayMesh.new()
	var surface_arrays := Array()
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays[Mesh.ARRAY_VERTEX] = outline_vertices
	outline_surface.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, surface_arrays)
	return outline_surface


static func _outline_vertices(selection: VoxelSelection, job: VoxelFrame.EditJob = null) -> PackedVector3Array:
	# Each cell edge goes straight onto the line it lies on. The old scan built one
	# array of five-element arrays, then grouped it again. The run on a line is the
	# edge start alone, because an edge is always two units long.
	var runs_by_line := {}
	var completed := 0
	for cell_position in selection.all_cells():
		_collect_boundary_runs(runs_by_line, cell_position, selection)
		completed += 1
		if job and completed % 4096 == 0 and not job.checkpoint(completed):
			return PackedVector3Array()
	return _merged_outline(runs_by_line, job)


func _start_preview() -> void:
	if _preview_job or _pending_cells.is_empty() or Time.get_ticks_msec() < _request_due_ms:
		return
	_preview_job = _new_job()
	_preview_job.cells = _pending_cells
	_preview_job.outline_builder = _outline_vertices
	_preview_job.style = _requested_style
	_preview_job.use_voxel_colors = _requested_voxel_colors
	_preview_job.smooth_normals = _requested_smooth_normals
	_preview_job.color_key = _requested_color_key
	_preview_job.revision = _request_revision
	_preview_job.cache_key = _requested_cache_key
	_pending_cells = {}
	_start_activity()
	if _preview_job.style == PreviewStyle.OUTLINE and _preview_job.cells.size() <= INLINE_OUTLINE_LIMIT:
		_preview_job.run()
		_finish_preview()
	else:
		_preview_job.worker_task_id = WorkerThreadPool.add_task(_preview_job.run, false, "Voxel preview")


## Returns a new preview job. A test replaces it with a gated job.
func _new_job() -> PreviewJob:
	return PreviewJob.new()


func _process(_delta: float) -> void:
	var current_frame := Engine.get_process_frames()
	if _install_frame != current_frame:
		_install_frame = current_frame
		_install_time_us = 0
	if _preview_job:
		if WorkerThreadPool.is_task_completed(_preview_job.worker_task_id):
			# A coalescing caller installs a completed snapshot in request order,
			# so an intermediate result still reaches the screen. The strict path
			# installs only the newest request.
			var ready := _preview_job.revision == _request_revision
			if coalesce_requests and not ready and _strict_alive and _preview_job.revision > _installed_revision:
				ready = true
			if ready and _install_time_us >= State.WORK_SLICE_US:
				return
			WorkerThreadPool.wait_for_task_completion(_preview_job.worker_task_id)
			var started_us := Time.get_ticks_usec()
			_finish_preview()
			_install_time_us += Time.get_ticks_usec() - started_us
		else:
			var progress := _preview_job.progress()
			State.update_operation(_operation_id, progress[1], progress[2], progress[0])
	# A streamed outline installs as soon as it is ready, so a growing selection
	# shows its intermediate outline instead of waiting for the exact final one. It
	# shares the strict install budget: a completed outline waits for the next frame
	# when the current frame is already spent.
	if _stream_job:
		if WorkerThreadPool.is_task_completed(_stream_job.worker_task_id):
			if _stream_job.stream_epoch == _stream_epoch and _install_time_us >= State.WORK_SLICE_US:
				pass
			else:
				WorkerThreadPool.wait_for_task_completion(_stream_job.worker_task_id)
				var started_us := Time.get_ticks_usec()
				_finish_stream()
				_install_time_us += Time.get_ticks_usec() - started_us
		else:
			var progress := _stream_job.progress()
			State.update_operation(_operation_id, progress[1], progress[2], progress[0])
	_start_preview()
	_start_stream()
	if is_settled():
		_finish_activity()


func _finish_preview() -> void:
	var job := _preview_job
	_preview_job = null
	if not job.checkpoint(0):
		return
	var latest := job.revision == _request_revision
	# A coalescing caller installs an intermediate snapshot only when it is newer
	# than the last installed surface and the strict request still owns the
	# preview. A clear, a stream, or a newer exact result then wins.
	var usable := latest
	if not usable and coalesce_requests and _strict_alive and job.revision > _installed_revision:
		usable = true
	if not usable:
		return
	_install_surface(job, latest)
	_installed_revision = maxi(_installed_revision, job.revision)
	_finish_activity()


# Build and install the surface of a finished job. A streamed outline skips the
# mesh cache, because its intermediate snapshots are throwaway and would evict the
# exact outlines the tools reuse.
func _install_surface(job: PreviewJob, cache: bool) -> void:
	var surface := ArrayMesh.new()
	if not job.arrays[Mesh.ARRAY_VERTEX].is_empty():
		var primitive := Mesh.PRIMITIVE_LINES if job.style == PreviewStyle.OUTLINE else Mesh.PRIMITIVE_TRIANGLES
		surface.add_surface_from_arrays(primitive, job.arrays)
		if job.style == PreviewStyle.SOLID:
			surface.surface_set_material(0, _surface_material())
	for chunk_job in job.atlas_surfaces:
		surface.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, chunk_job.surface_arrays)
		surface.surface_set_material(surface.get_surface_count() - 1, _atlas_material(chunk_job))
	if cache:
		_cache_mesh(job, surface)
	mesh = surface
	position = Vector3.ZERO
	visible = surface.get_surface_count() > 0
	# Record the exact cells that this surface draws. A caller reads them through
	# [method installed_cells] to match a visible preview to a later click.
	_installed_cells = job.cells


## Returns the immutable cells of the last installed surface, or an empty
## dictionary when no preview is visible. The caller must not change the result.
func installed_cells() -> Dictionary:
	return _installed_cells


static func _surface_material() -> StandardMaterial3D:
	var material: StandardMaterial3D = preload("res://VoxelMaterial.tres").duplicate()
	# Cached surfaces can also appear in reflected brush cursors.
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


static func _atlas_material(job: VoxelMeshBuilder) -> StandardMaterial3D:
	var material := _surface_material()
	if job.atlas:
		return job.atlas.create_material(material)
	material.vertex_color_use_as_albedo = false
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.albedo_texture = _atlas_texture(job.atlas_size, job.atlas_albedo)
	var material_texture := _atlas_texture(job.atlas_size, job.atlas_orm)
	# StandardMaterial3D reads separate metallic and roughness texture slots.
	material.metallic_texture = material_texture
	material.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	material.roughness_texture = material_texture
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	material.metallic = 1.0
	material.roughness = 1.0
	material.emission_enabled = true
	material.emission = Color.BLACK
	material.emission_texture = _atlas_texture(job.atlas_size, job.atlas_emission)
	return material


static func _atlas_texture(size: Vector2i, data: PackedByteArray) -> ImageTexture:
	return ImageTexture.create_from_image(Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGB8, data))


static func _cache_mesh(job: PreviewJob, surface: ArrayMesh) -> void:
	var bytes := job.geometry_bytes + job.cells.size() * 64
	if bytes > CACHE_LIMIT_BYTES:
		return
	if _mesh_cache.has(job.cache_key):
		_cache_bytes -= _mesh_cache[job.cache_key].bytes
		_cache_order.erase(job.cache_key)
	_mesh_cache[job.cache_key] = {"cells": job.cells, "color_key": job.color_key, "surface": surface, "bytes": bytes}
	_cache_order.append(job.cache_key)
	_cache_bytes += bytes
	while _cache_bytes > CACHE_LIMIT_BYTES or _cache_order.size() > CACHE_LIMIT_ENTRIES:
		var oldest: String = _cache_order.pop_front()
		_cache_bytes -= _mesh_cache[oldest].bytes
		_mesh_cache.erase(oldest)


func _exit_tree() -> void:
	State.model_settings_changed.disconnect(_on_model_settings_changed)
	State.document_changed.disconnect(_on_model_settings_changed)
	_clear_request()
	if _preview_job:
		_preview_job.cancel()
		WorkerThreadPool.wait_for_task_completion(_preview_job.worker_task_id)
		_preview_job = null
	if _stream_job:
		_stream_job.cancel()
		WorkerThreadPool.wait_for_task_completion(_stream_job.worker_task_id)
		_stream_job = null
	_preview_count -= 1
	if _preview_count == 0:
		_mesh_cache.clear()
		_cache_order.clear()
		_cache_bytes = 0


func _start_activity() -> void:
	if not State.has_operation(_operation_id):
		_operation_id = State.begin_operation("Updating preview", -1, false, self)


func _finish_activity() -> void:
	State.finish_operation(_operation_id)
	_operation_id = 0


## Returns [code]true[/code] when no preview job or request is pending.
func is_settled() -> bool:
	return _pending_cells.is_empty() and _preview_job == null and _stream_job == null and not _stream_has_pending


# One lookup per face neighbor, shared by the four edge tests of an axis. The old
# scan read the same neighbor up to four times. The diagonal is read only when
# exactly one side face is present, which is the only case that needs it.
static func _collect_boundary_runs(runs_by_line: Dictionary, cell_position: Vector3i, selection: VoxelSelection) -> void:
	var x := cell_position.x
	var y := cell_position.y
	var z := cell_position.z
	var x_before := selection.contains(Vector3i(x - 1, y, z))
	var x_after := selection.contains(Vector3i(x + 1, y, z))
	var y_before := selection.contains(Vector3i(x, y - 1, z))
	var y_after := selection.contains(Vector3i(x, y + 1, z))
	var z_before := selection.contains(Vector3i(x, y, z - 1))
	var z_after := selection.contains(Vector3i(x, y, z + 1))
	# A cell with every face neighbor present has no boundary edge. The shared
	# interior of a large model is most of the scan, so skip it before any edge test.
	if x_before and x_after and y_before and y_after and z_before and z_after:
		return
	# Two present side faces hide the edge between them, so that test never runs.
	# Edge axis 0 runs along x, so its side axes are y and z.
	if not (y_before and z_before):
		_append_boundary_edge(runs_by_line, 0, cell_position, 1, -1, 2, -1, y_before, z_before, selection)
	if not (y_before and z_after):
		_append_boundary_edge(runs_by_line, 0, cell_position, 1, -1, 2, 1, y_before, z_after, selection)
	if not (y_after and z_before):
		_append_boundary_edge(runs_by_line, 0, cell_position, 1, 1, 2, -1, y_after, z_before, selection)
	if not (y_after and z_after):
		_append_boundary_edge(runs_by_line, 0, cell_position, 1, 1, 2, 1, y_after, z_after, selection)
	# Edge axis 1 runs along y, so its side axes are z and x.
	if not (z_before and x_before):
		_append_boundary_edge(runs_by_line, 1, cell_position, 2, -1, 0, -1, z_before, x_before, selection)
	if not (z_before and x_after):
		_append_boundary_edge(runs_by_line, 1, cell_position, 2, -1, 0, 1, z_before, x_after, selection)
	if not (z_after and x_before):
		_append_boundary_edge(runs_by_line, 1, cell_position, 2, 1, 0, -1, z_after, x_before, selection)
	if not (z_after and x_after):
		_append_boundary_edge(runs_by_line, 1, cell_position, 2, 1, 0, 1, z_after, x_after, selection)
	# Edge axis 2 runs along z, so its side axes are x and y.
	if not (x_before and y_before):
		_append_boundary_edge(runs_by_line, 2, cell_position, 0, -1, 1, -1, x_before, y_before, selection)
	if not (x_before and y_after):
		_append_boundary_edge(runs_by_line, 2, cell_position, 0, -1, 1, 1, x_before, y_after, selection)
	if not (x_after and y_before):
		_append_boundary_edge(runs_by_line, 2, cell_position, 0, 1, 1, -1, x_after, y_before, selection)
	if not (x_after and y_after):
		_append_boundary_edge(runs_by_line, 2, cell_position, 0, 1, 1, 1, x_after, y_after, selection)


# One cell edge, keyed by the line it lies on. The caller already dropped the
# tests whose two side faces are both present. A single present side face keeps
# the edge only when the diagonal is present.
static func _append_boundary_edge(runs_by_line: Dictionary, edge_axis: int, cell_position: Vector3i, first_side_axis: int, first_side_sign: int, second_side_axis: int, second_side_sign: int, first_side: bool, second_side: bool, selection: VoxelSelection) -> void:
	if first_side != second_side:
		var diagonal_neighbor := _shifted(_shifted(cell_position, first_side_axis, first_side_sign), second_side_axis, second_side_sign)
		if not selection.contains(diagonal_neighbor):
			return
	var line_key := Vector3i(edge_axis, cell_position[first_side_axis] * 2 + first_side_sign, cell_position[second_side_axis] * 2 + second_side_sign)
	if not runs_by_line.has(line_key):
		runs_by_line[line_key] = []
	runs_by_line[line_key].append(cell_position[edge_axis] * 2 - 1)


static func _shifted(cell_position: Vector3i, axis: int, offset: int) -> Vector3i:
	var neighbor_position := cell_position
	neighbor_position[axis] += offset
	return neighbor_position


# Runs on one line merge when the next start touches the open end. An edge is
# always two units long, so the end is the start plus two. The native sort keeps
# the ascending start order the old comparator produced.
static func _merged_outline(runs_by_line: Dictionary, job: VoxelFrame.EditJob = null) -> PackedVector3Array:
	var outline_vertices := PackedVector3Array()
	var completed := 0
	for line_key: Vector3i in runs_by_line:
		if job and not job.checkpoint(completed):
			return PackedVector3Array()
		var line_runs: Array = runs_by_line[line_key]
		completed += line_runs.size()
		line_runs.sort()
		var merged_start: int = line_runs[0]
		var merged_end := merged_start + 2
		for run_index in range(1, line_runs.size()):
			var next_start: int = line_runs[run_index]
			if next_start <= merged_end:
				merged_end = next_start + 2
			else:
				_emit_run(outline_vertices, line_key.x, line_key.y, line_key.z, Vector2i(merged_start, merged_end))
				merged_start = next_start
				merged_end = next_start + 2
		_emit_run(outline_vertices, line_key.x, line_key.y, line_key.z, Vector2i(merged_start, merged_end))
	return outline_vertices


static func _emit_run(outline_vertices: PackedVector3Array, edge_axis: int, first_side_coord: int, second_side_coord: int, merged_run: Vector2i) -> void:
	var first_side_axis := (edge_axis + 1) % 3
	var second_side_axis := (edge_axis + 2) % 3
	var start_position := Vector3.ZERO
	var end_position := Vector3.ZERO
	start_position[edge_axis] = merged_run.x * 0.5
	end_position[edge_axis] = merged_run.y * 0.5
	start_position[first_side_axis] = first_side_coord * 0.5
	end_position[first_side_axis] = first_side_coord * 0.5
	start_position[second_side_axis] = second_side_coord * 0.5
	end_position[second_side_axis] = second_side_coord * 0.5
	outline_vertices.append(start_position)
	outline_vertices.append(end_position)
