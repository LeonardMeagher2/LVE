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

# An inline outline runs inside the request on the main thread. The mask builder
# costs about 1.5 us per selected cell to build the selection masks once, then
# about 3 ms per touched chunk for the boundary scan. A small selection stays
# inside the 3000 us work slice. A larger outline goes to a worker and installs a
# frame later instead of stalling the frame that asked for it.
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
## The chunk edge length of the outline mask.
const OUTLINE_CHUNK := VoxelFrame.CHUNK_SIZE
## The cell bits of one mask row.
const OUTLINE_CELL_BITS := 0xFFFF

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
var _requested_masks := {}
var _requested_mask_hash := -1
var _requested_outline := false
var _requested_source: VoxelSelection
var _requested_source_revision := -1
var _requested_style := PreviewStyle.OUTLINE
var _requested_voxel_colors := false
var _requested_smooth_normals := false
var _requested_ao_strength := 0.0
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
# The opaque token of the newest request, or null. A cache hit and a worker
# install report the token of the request that asked for the surface, never the
# token of a cached entry, so a caller can attribute the visible cells even when
# an equal cached mesh holds a different cell dictionary.
var _requested_token: Variant = null
# The opaque token of the last installed surface, or null. A clear drops it.
var _installed_token: Variant = null
# The progressive selection path. The wand streams a growing selection, so a new
# snapshot must not cancel the outline that is already building. The path is
# opt-in, so the brush and cursor keep the strict latest-only behavior.
var _stream_job: PreviewJob
var _stream_source: VoxelSelection
var _stream_queued_source: VoxelSelection
var _stream_queued_revision := -1
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
# The instance override is this per-instance lit material, not the carrier. It
# lights like a voxel and wins the depth tie with the terrain through one
# clip-space step. The carrier keeps the same values for callers that read it.
var _lit_material := preload("res://Globals/Rendering/cursor_lit.tres").duplicate()
# True while the visible override mirrors the box carrier. The solid and
# prepared paths mirror the solid carrier, so a material change without a new
# submit can mirror the carrier that is on screen.
var _lit_from_box := false
var _brush_material := VoxelFrame.material(Color.WHITE)

## A prepared solid preview that a worker built off the main thread.
##
## It carries the read-only color dictionary, the format flag, the display color,
## and the hash of the cell keys. [method VoxelPreview.submit_prepared] formats
## the exact cache key from the live smooth setting, so the main thread never
## scans the values, hashes the keys, or copies the dictionary for a large batch.
##
## The values are immutable [Color] objects and the dictionary is read-only, so a
## worker and the main thread may share the payload. A caller must never change
## the payload or its dictionary.
class SolidPayload extends RefCounted:
	## The read-only color dictionary, keyed by cell position.
	var spots := {}
	## The number of cells.
	var cell_count := 0
	## Whether the frame reads a full material from each cell value.
	var use_voxel_colors := false
	## The color key of a transparent cell.
	var color_key := Color.WHITE
	## The display color of the material override.
	var display_color := Color.WHITE
	## The hash of the cell keys. A caller formats the exact cache key from it.
	var cell_hash := 0
	## The opaque request token of this payload, or null. A caller sets it before
	## [method VoxelPreview.submit_prepared] when it must attribute the installed
	## surface to its request. The token is never part of the cache key.
	var token: Variant = null


## Builds one solid preview payload from cells and the display color.
##
## It is pure: it reads no Node, no State, and no RenderingServer, so a worker may
## call it. The dictionary and the key hash are built once here, off the main
## thread. The payload holds one uniform color, which is the spray cursor case.
static func build_solid_payload(cells: Array[Vector3i], display_color: Color, use_voxel_colors := false) -> SolidPayload:
	var payload := SolidPayload.new()
	var spots := {}
	for cell in cells:
		spots[cell] = display_color
	spots.make_read_only()
	payload.spots = spots
	payload.cell_count = spots.size()
	payload.use_voxel_colors = use_voxel_colors
	payload.color_key = display_color if use_voxel_colors else Color.WHITE
	payload.display_color = display_color
	payload.cell_hash = _cell_hash(spots, use_voxel_colors)
	return payload


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
	## The ambient occlusion strength of a solid mesh, from 0 to 1.
	var ao_strength := 0.0
	## The color that replaces a transparent cell color.
	var color_key := Color.WHITE
	## The strict request id that the job belongs to.
	var revision := 0
	## The opaque request token that the job belongs to, or null. A caller reads
	## it from the installed surface, so an intermediate coalesced result keeps
	## the identity of the request that produced it.
	var token: Variant = null
	# The stream epoch of a progressive selection job. The strict `revision` above
	# is the request id of the strict path.
	## The stream epoch that the job belongs to.
	var stream_epoch := 0
	## The mesh cache key of the job.
	var cache_key := ""
	## The built mesh arrays, indexed by [enum Mesh.ArrayType].
	var arrays := []
	## The per-chunk build microseconds of the solid path.
	var build_us := 0
	## The vertex and index merge microseconds of the solid path.
	var merge_us := 0
	## The number of chunks the solid path built.
	var chunk_count := 0
	## The number of built chunks that emitted no vertex.
	var empty_chunks := 0
	## The number of chunks that took the enclosed shortcut and skipped the build.
	var culled_chunks := 0
	## The per-chunk atlas surfaces of a solid mesh.
	var atlas_surfaces: Array[VoxelMeshBuilder] = []
	## The estimated geometry byte count.
	var geometry_bytes := 0
	## The callable that builds an outline from a selection.
	var outline_builder: Callable
	## The callable that builds an outline from a mask snapshot.
	var mask_outline_builder: Callable
	## The per-chunk selection masks of an outline. A snapshot from the caller is
	## read on the worker, so no live selection is touched.
	var mask_chunks := {}

	## Builds the mesh arrays. This is the worker body.
	func run() -> void:
		if style == PreviewStyle.OUTLINE:
			var outline_vertices: PackedVector3Array
			if mask_chunks.is_empty():
				var selection := VoxelSelection.new()
				selection.restore(cells)
				stage("Building preview outline", cells.size())
				outline_vertices = outline_builder.call(selection, self)
			else:
				stage("Building preview outline", cells.size())
				outline_vertices = mask_outline_builder.call(mask_chunks, self)
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = outline_vertices
			geometry_bytes = outline_vertices.size() * 12
			return
		stage("Preparing solid preview", cells.size())
		var colors := {}
		var use_material_atlas := false
		# A batch whose cells all hold one material declares that material once. The
		# frame then fills a whole chunk in one write and skips its own per-cell
		# compare, and this loop allocates no material array per cell. A batch that
		# varies declares nothing, so the frame compares the cells itself.
		var uniform_material: PackedFloat32Array = PackedFloat32Array()
		var uniform_holds := true
		for cell_position in cells:
			var value = cells[cell_position]
			if use_voxel_colors and value is PackedFloat32Array:
				colors[cell_position] = value
				use_material_atlas = true
				uniform_holds = false
			else:
				var color: Color = value if value is Color else VoxelFrame.material_color(value)
				var cell_material: PackedFloat32Array
				if not use_voxel_colors:
					if uniform_material.is_empty():
						uniform_material = VoxelFrame.material(Color.WHITE)
					cell_material = uniform_material
				else:
					var wanted := color_key if color == Color.TRANSPARENT else color
					if uniform_holds and not uniform_material.is_empty() and VoxelFrame.material_color(uniform_material) == wanted:
						cell_material = uniform_material
					else:
						cell_material = VoxelFrame.material(wanted)
						if uniform_material.is_empty():
							uniform_material = cell_material
						else:
							uniform_holds = false
				colors[cell_position] = cell_material
			if colors.size() % 4096 == 0 and not checkpoint(colors.size()):
				return
		var frame := VoxelFrame.new()
		# Declare the shared material only when every cell really holds it, so a
		# varying batch is never treated as one material.
		frame.set_cells(colors, self, uniform_material if uniform_holds and not uniform_material.is_empty() else null)
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
			job.ao_strength = ao_strength
			job.texture_materials = use_material_atlas
			var build_started_us := Time.get_ticks_usec()
			job.run()
			build_us += Time.get_ticks_usec() - build_started_us
			chunk_count += 1
			if job.enclosed_culled:
				culled_chunks += 1
			if job.surface_arrays[Mesh.ARRAY_VERTEX].is_empty():
				empty_chunks += 1
				completed += 1
				continue
			var merge_started_us := Time.get_ticks_usec()
			var chunk_origin := Vector3(chunk_location * VoxelFrame.CHUNK_SIZE)
			if job.atlas_size.x > 0:
				var chunk_vertices: PackedVector3Array = job.surface_arrays[Mesh.ARRAY_VERTEX]
				for index in chunk_vertices.size():
					chunk_vertices[index] += chunk_origin
				job.surface_arrays[Mesh.ARRAY_VERTEX] = chunk_vertices
				atlas_surfaces.append(job)
				geometry_bytes += job.geometry_bytes + job.atlas_albedo.size() + job.atlas_orm.size() + job.atlas_emission.size()
				merge_us += Time.get_ticks_usec() - merge_started_us
				completed += 1
				continue
			var vertex_offset := vertices.size()
			for vertex in job.surface_arrays[Mesh.ARRAY_VERTEX]:
				vertices.append(vertex + chunk_origin)
			normals.append_array(job.surface_arrays[Mesh.ARRAY_NORMAL])
			vertex_colors.append_array(job.surface_arrays[Mesh.ARRAY_COLOR])
			for index in job.surface_arrays[Mesh.ARRAY_INDEX]:
				indices.append(index + vertex_offset)
			merge_us += Time.get_ticks_usec() - merge_started_us
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
		_request(_requested_cells, _requested_style, _requested_voxel_colors, _requested_color_key, _requested_token)
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
	# A caller can change the material without a new submit. Mirror the carrier
	# that the visible override uses, so the change reaches the cursor at once.
	if _lit_from_box:
		_sync_lit_material(_primitive_material)
	else:
		_sync_lit_material(_solid_material)


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


# Mirrors a carrier's values onto the per-instance lit material, so the visible
# override and the carrier always agree.
func _sync_lit_material(carrier: StandardMaterial3D) -> void:
	_lit_material.set_shader_parameter("cursor_color", carrier.albedo_color)
	_lit_material.set_shader_parameter("emission_color", carrier.emission)
	_lit_material.set_shader_parameter("metallic", carrier.metallic)
	_lit_material.set_shader_parameter("roughness", carrier.roughness)
	_lit_material.set_shader_parameter("use_vertex_color", carrier.vertex_color_use_as_albedo)


## Shows the brush cells. [param outline] draws a line outline. A
## [param cube_diameter] above zero uses one box mesh for a cube brush.
## [param use_voxel_colors] reads a full material from each cell value.
## [param token] is optional opaque metadata that the caller can read back from
## the installed surface through [method installed_token].
func show_voxels(colors: Dictionary, color: Color, outline: bool = false, cube_diameter: int = 0, use_voxel_colors: bool = true, token: Variant = null) -> void:
	if colors.is_empty():
		_clear_request()
		return
	if outline:
		material_override = _outline_material
		_request(colors, PreviewStyle.OUTLINE, false, Color.WHITE, token)
		return
	# A cube's voxels have the same six faces as a box, so above the caller's limit
	# the box is exact and costs nothing. A shape whose voxels are stepped has no
	# exact primitive, so it stays per-cell.
	if cube_diameter > 0:
		_clear_request()
		_box.size = Vector3.ONE * cube_diameter
		_primitive_material.albedo_color = color
		_lit_from_box = true
		_sync_lit_material(_primitive_material)
		material_override = _lit_material
		mesh = _box
		position = Vector3.ONE * -0.5 if cube_diameter % 2 == 0 else Vector3.ZERO
		visible = true
		return
	if use_voxel_colors:
		_apply_material(_solid_material, VoxelFrame.material(Color.WHITE))
	else:
		_apply_material(_solid_material, _brush_material)
		_solid_material.albedo_color = color
	_lit_from_box = false
	_sync_lit_material(_solid_material)
	# Full per-cell materials use the cached surfaces' atlas materials.
	material_override = _lit_material
	if use_voxel_colors:
		for cell in colors:
			if colors[cell] is PackedFloat32Array:
				material_override = null
				break
	_request(colors, PreviewStyle.SOLID, use_voxel_colors, color if use_voxel_colors else Color.WHITE, token)


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
		# A publish that did not change the cells queues nothing. The revision
		# makes that test one integer compare, not a full set compare.
		if selection == _stream_queued_source and selection.revision == _stream_queued_revision:
			return
		_stream_queued_source = selection
		_stream_queued_revision = selection.revision
		_queue_stream(selection)
		return
	# The same selection at the same revision needs no copy, hash, or rebuild. A
	# stream or a cell preview owns the surface in between, so the strict flag
	# must say this request still owns it.
	if selection == _requested_source and selection.revision == _requested_source_revision and _strict_alive and _requested_style == PreviewStyle.OUTLINE:
		return
	_requested_source = selection
	_requested_source_revision = selection.revision
	# `all_cells` hands out the live cells without marking the selection shared, so
	# the request copy below does not force a second copy on the next add.
	_request(selection.all_cells(), PreviewStyle.OUTLINE, false, Color.WHITE, null, selection.mask_snapshot(), selection)


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
	# The mask snapshot owns its grids, so the worker reads a set that no main
	# thread write can change. The cells are not copied: a stream job needs them
	# only when no mask snapshot exists, and the installed cells of a progressive
	# outline are not part of the selection tool path.
	job.mask_chunks = _stream_source.mask_snapshot()
	job.outline_builder = _outline_vertices
	job.mask_outline_builder = _outline_from_masks
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
	_stream_queued_source = null
	_stream_queued_revision = -1
	if _stream_job:
		_stream_job.cancel()


func _request(cells: Dictionary, style: PreviewStyle, use_voxel_colors: bool = false, color_key: Color = Color.WHITE, token: Variant = null, mask_chunks: Dictionary = {}, source: VoxelSelection = null) -> void:
	_cancel_stream()
	var colored := style == PreviewStyle.SOLID and use_voxel_colors
	var smooth_normals := style == PreviewStyle.SOLID and State.document.smooth_normals
	var ao_strength := State.document.ao_strength if style == PreviewStyle.SOLID else 0.0
	var outline := style == PreviewStyle.OUTLINE and not mask_chunks.is_empty()
	var mask_hash := _mask_hash(mask_chunks) if outline else 0
	# The dedupe trusts the requested set only while the strict request still owns
	# the preview. A stream publish clears that ownership, so a strict request
	# repeated after a stream reinstalls its exact result. A deduped request keeps
	# the token of the surface that is already installed. An outline compares the
	# mask hash, so it never hashes or scans the cell dictionary.
	if _strict_alive and style == _requested_style and use_voxel_colors == _requested_voxel_colors and smooth_normals == _requested_smooth_normals and is_equal_approx(ao_strength, _requested_ao_strength) and color_key == _requested_color_key:
		var same := (_requested_outline and mask_hash == _requested_mask_hash) if outline else _same_cells(_requested_cells, cells, colored)
		if same:
			return
	_request_revision += 1
	_strict_alive = true
	# A coalescing caller wants the newest snapshot, not a restart. It keeps the
	# running worker and installs its result in request order, so a continuous
	# change never starves. The strict default cancels, so its request wins alone.
	if _preview_job and not coalesce_requests:
		_preview_job.cancel()
	_requested_token = token
	_requested_style = style
	_requested_voxel_colors = use_voxel_colors
	_requested_smooth_normals = smooth_normals
	_requested_ao_strength = ao_strength
	_requested_color_key = color_key
	_requested_masks = mask_chunks if outline else {}
	_requested_mask_hash = mask_hash
	_requested_outline = outline
	_pending_cells = {}
	_request_due_ms = 0
	var cell_hash := mask_hash if outline else _cell_hash(cells, colored)
	var cache_key := _key_from_hash(style, colored, cell_hash, color_key, smooth_normals, "m" if outline else "", ao_strength)
	_requested_cache_key = cache_key
	var cached: Dictionary = _mesh_cache.get(cache_key, {})
	if not cached.is_empty() and cached.color_key == color_key and (outline or _same_cells(cached.cells, cells, colored)):
		# A dedupe compares the next request with `_requested_cells`, so a cache
		# hit must record the cells it installed. Otherwise a request that
		# alternates between two sets skips the second set after a hit.
		_requested_cells = cached.cells
		_install_cached(cache_key, cached)
		return
	# The request schedules a job. An outline shares the selection dictionary and
	# makes it read-only, so the next selection write copies it once. The other
	# paths copy the cell set now.
	_requested_cells = source.capture() if outline and source != null else (cells if cells.is_read_only() else cells.duplicate(true))
	_requested_cells.make_read_only()
	_pending_cells = _requested_cells
	_request_due_ms = Time.get_ticks_msec() + 100 if style == PreviewStyle.OUTLINE and cells.size() > OUTLINE_DELAY_LIMIT else 0
	_start_activity()
	_start_preview()


## Returns the content hash of one mask snapshot.
static func _mask_hash(masks: Dictionary) -> int:
	var combined := 0
	for location in masks:
		var grids: Array = masks[location]
		combined = hash([combined, location, hash(grids[0]), hash(grids[1]), hash(grids[2])])
	return combined


## Shows a solid preview from a payload that a worker built.
##
## The payload holds the read-only color dictionary, the format flag, and the cell
## hash, so this call never scans the values, hashes the keys, or copies the
## dictionary. It formats the exact cache key from the live smooth setting and
## reuses the shared mesh cache, the worker job, and the installed-cell contract of
## [method show_voxels]. The caller must submit its newest payload, because this
## path has no cell-set dedupe. The payload token, when set, is reported by the
## installed surface.
func submit_prepared(payload: SolidPayload) -> void:
	if payload == null or payload.cell_count == 0:
		_clear_request()
		return
	_cancel_stream()
	_requested_token = payload.token
	var colored := payload.use_voxel_colors
	var smooth_normals := State.document.smooth_normals
	var ao_strength := State.document.ao_strength
	# A uniform color payload uses the brush material, exactly like the default
	# solid path of `show_voxels`. A colored payload keeps the neutral material.
	if colored:
		_apply_material(_solid_material, VoxelFrame.material(Color.WHITE))
	else:
		_apply_material(_solid_material, _brush_material)
		_solid_material.albedo_color = payload.display_color
	_lit_from_box = false
	_sync_lit_material(_solid_material)
	material_override = _lit_material
	_request_revision += 1
	_strict_alive = true
	if _preview_job and not coalesce_requests:
		_preview_job.cancel()
	_requested_style = PreviewStyle.SOLID
	_requested_voxel_colors = colored
	_requested_smooth_normals = smooth_normals
	_requested_ao_strength = ao_strength
	_requested_color_key = payload.color_key
	_requested_cells = payload.spots
	_pending_cells = {}
	_request_due_ms = 0
	var cache_key := _key_from_hash(PreviewStyle.SOLID, colored, payload.cell_hash, payload.color_key, smooth_normals, "", ao_strength)
	_requested_cache_key = cache_key
	var cached: Dictionary = _mesh_cache.get(cache_key, {})
	if not cached.is_empty() and cached.color_key == payload.color_key and _same_cells(cached.cells, _requested_cells, colored):
		_install_cached(cache_key, cached)
		return
	_pending_cells = _requested_cells
	_start_activity()
	_start_preview()


# Installs one cached surface and records it as the newest result. Shared by the
# direct request and a prepared payload, so both install the exact same way.
func _install_cached(cache_key: String, cached: Dictionary) -> void:
	mesh = cached.surface
	position = Vector3.ZERO
	visible = true
	_cache_order.erase(cache_key)
	_cache_order.append(cache_key)
	_installed_revision = _request_revision
	# The cached entry holds the cells of the request that built it. The token
	# comes from the request that asked for the hit, so an equal cached surface
	# still reports the identity of the current request.
	_installed_cells = cached.cells
	_installed_token = _requested_token
	_finish_activity()


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


# The hash of the requested cells. A colored solid reads the values, so its hash
# covers them. Every other shape reads the keys alone.
static func _cell_hash(cells: Dictionary, colored: bool) -> int:
	return cells.hash() if colored else cells.keys().hash()


# The exact cache key from one cell hash and the flags that change the surface. A
# worker computes the cell hash, and the main thread formats the key with the live
# smooth setting, so a prepared payload needs no main-thread key hash.
static func _key_from_hash(style: int, colored: bool, cell_hash: int, color_key: Color, smooth_normals: bool, kind := "", ao_strength := 0.0) -> String:
	return "%s%d:%s:%d:%s:%s:%d" % [kind, style, colored, cell_hash, color_key, smooth_normals, roundi(ao_strength * 1000.0)]


func _clear_request() -> void:
	_request_revision += 1
	# A clear must not let an in-flight worker install after the hide. The
	# installed revision moves past every running job, so none can reappear.
	_installed_revision = _request_revision
	_installed_cells = {}
	_installed_token = null
	_requested_token = null
	_strict_alive = false
	_requested_cells = {}
	_requested_masks = {}
	_requested_mask_hash = -1
	_requested_outline = false
	_requested_source = null
	_requested_source_revision = -1
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
	# The selection keeps one dense mask per chunk, so the neighbor tests read
	# words instead of the cell dictionary. A worker receives a mask snapshot.
	return _outline_from_masks(selection.mask_chunks(), job)


## Returns the outline of one set of per-chunk selection masks. A worker calls
## this with a [method VoxelSelection.mask_snapshot].
static func _outline_from_masks(masks: Dictionary, job: VoxelFrame.EditJob = null) -> PackedVector3Array:
	if job and not job.checkpoint(0):
		return PackedVector3Array()
	var runs_by_line := {}
	for location: Vector3i in masks:
		if job and not job.checkpoint(0):
			return PackedVector3Array()
		_collect_chunk_runs(runs_by_line, masks, location)
	return _merged_outline(runs_by_line, job)


# Extracts the boundary runs of one chunk from its own masks. Each axis reads the
# cell row, the two side rows, and the diagonal row of a line, so the four edges
# of a line cost four word reads. A side or diagonal cell on a chunk border comes
# from the neighbor mask.
static func _collect_chunk_runs(runs_by_line: Dictionary, masks: Dictionary, location: Vector3i) -> void:
	var chunk_masks: Array = masks[location]
	var x_grid: PackedInt32Array = chunk_masks[0]
	var y_grid: PackedInt32Array = chunk_masks[1]
	var z_grid: PackedInt32Array = chunk_masks[2]
	var signs: Array[int] = [-1, 1]
	# The masks hold local coordinates. A line key and a run are in half units, so
	# one chunk step is 32 of them.
	var offset_x := location.x * 32
	var offset_y := location.y * 32
	var offset_z := location.z * 32
	# Edge axis 0 runs along x, so its side axes are y and z.
	for y in OUTLINE_CHUNK:
		var py := y + 1
		var row := y * OUTLINE_CHUNK
		var y_inner := py > 1 and py < OUTLINE_CHUNK
		for z in OUTLINE_CHUNK:
			var cell := x_grid[row + z]
			if cell == 0:
				continue
			var pz := z + 1
			var z_inner := pz > 1 and pz < OUTLINE_CHUNK
			for y_sign in signs:
				var first_y := py + y_sign
				for z_sign in signs:
					var second_z := pz + z_sign
					if y_inner and z_inner:
						_collect_mask_runs(runs_by_line, 0, offset_y + y * 2 + y_sign, offset_z + z * 2 + z_sign, offset_x, cell,
							x_grid[(first_y - 1) * OUTLINE_CHUNK + z],
							x_grid[row + second_z - 1],
							x_grid[(first_y - 1) * OUTLINE_CHUNK + second_z - 1])
					else:
						_collect_mask_runs(runs_by_line, 0, offset_y + y * 2 + y_sign, offset_z + z * 2 + z_sign, offset_x, cell,
							_mask_at(masks, location, 0, x_grid, first_y, pz, 1, 2),
							_mask_at(masks, location, 0, x_grid, py, second_z, 1, 2),
							_mask_at(masks, location, 0, x_grid, first_y, second_z, 1, 2))
	# Edge axis 1 runs along y, so its side axes are z and x.
	for z in OUTLINE_CHUNK:
		var pz := z + 1
		var row := z * OUTLINE_CHUNK
		var z_inner := pz > 1 and pz < OUTLINE_CHUNK
		for x in OUTLINE_CHUNK:
			var cell := y_grid[row + x]
			if cell == 0:
				continue
			var px := x + 1
			var x_inner := px > 1 and px < OUTLINE_CHUNK
			for z_sign in signs:
				var first_z := pz + z_sign
				for x_sign in signs:
					var second_x := px + x_sign
					if z_inner and x_inner:
						_collect_mask_runs(runs_by_line, 1, offset_z + z * 2 + z_sign, offset_x + x * 2 + x_sign, offset_y, cell,
							y_grid[(first_z - 1) * OUTLINE_CHUNK + x],
							y_grid[row + second_x - 1],
							y_grid[(first_z - 1) * OUTLINE_CHUNK + second_x - 1])
					else:
						_collect_mask_runs(runs_by_line, 1, offset_z + z * 2 + z_sign, offset_x + x * 2 + x_sign, offset_y, cell,
							_mask_at(masks, location, 1, y_grid, first_z, px, 2, 0),
							_mask_at(masks, location, 1, y_grid, pz, second_x, 2, 0),
							_mask_at(masks, location, 1, y_grid, first_z, second_x, 2, 0))
	# Edge axis 2 runs along z, so its side axes are x and y.
	for x in OUTLINE_CHUNK:
		var px := x + 1
		var row := x * OUTLINE_CHUNK
		var x_inner := px > 1 and px < OUTLINE_CHUNK
		for y in OUTLINE_CHUNK:
			var cell := z_grid[row + y]
			if cell == 0:
				continue
			var py := y + 1
			var y_inner := py > 1 and py < OUTLINE_CHUNK
			for x_sign in signs:
				var first_x := px + x_sign
				for y_sign in signs:
					var second_y := py + y_sign
					if x_inner and y_inner:
						_collect_mask_runs(runs_by_line, 2, offset_x + x * 2 + x_sign, offset_y + y * 2 + y_sign, offset_z, cell,
							z_grid[(first_x - 1) * OUTLINE_CHUNK + y],
							z_grid[row + second_y - 1],
							z_grid[(first_x - 1) * OUTLINE_CHUNK + second_y - 1])
					else:
						_collect_mask_runs(runs_by_line, 2, offset_x + x * 2 + x_sign, offset_y + y * 2 + y_sign, offset_z, cell,
							_mask_at(masks, location, 2, z_grid, first_x, py, 0, 1),
							_mask_at(masks, location, 2, z_grid, px, second_y, 0, 1),
							_mask_at(masks, location, 2, z_grid, first_x, second_y, 0, 1))


# Returns one row mask of one chunk in padded coordinates. A coordinate in 1
# through 16 reads the own grid. A 0 or 17 reads the border row of the neighbor
# chunk that holds that cell. A missing chunk reads empty.
static func _mask_at(masks: Dictionary, location: Vector3i, grid_index: int, own_grid: PackedInt32Array, first: int, second: int, first_axis: int, second_axis: int) -> int:
	if first > 0 and first <= OUTLINE_CHUNK and second > 0 and second <= OUTLINE_CHUNK:
		return own_grid[(first - 1) * OUTLINE_CHUNK + (second - 1)]
	var neighbor := location
	var first_own := first - 1
	var second_own := second - 1
	if first == 0:
		neighbor[first_axis] -= 1
		first_own = OUTLINE_CHUNK - 1
	elif first == OUTLINE_CHUNK + 1:
		neighbor[first_axis] += 1
		first_own = 0
	if second == 0:
		neighbor[second_axis] -= 1
		second_own = OUTLINE_CHUNK - 1
	elif second == OUTLINE_CHUNK + 1:
		neighbor[second_axis] += 1
		second_own = 0
	var chunk_masks = masks.get(neighbor)
	if chunk_masks == null:
		return 0
	var grid: PackedInt32Array = chunk_masks[grid_index]
	return grid[first_own * OUTLINE_CHUNK + second_own]


# Emits the runs of one line from its own cell mask, its two side masks, and its
# diagonal mask. An edge needs its cell set. A bit set in both sides hides the
# edge. With exactly one side set, the diagonal must be set, which is the same
# rule as the per-cell builder. [param run_offset] moves the local half-unit run
# to world coordinates.
static func _collect_mask_runs(runs_by_line: Dictionary, edge_axis: int, first_coord: int, second_coord: int, run_offset: int, cell: int, first: int, second: int, diagonal: int) -> void:
	var bits := cell & (~(first & second)) & ((~(first ^ second)) | diagonal) & OUTLINE_CELL_BITS
	if bits == 0:
		return
	var line_key := Vector3i(edge_axis, first_coord, second_coord)
	var line_runs = runs_by_line.get(line_key)
	if line_runs == null:
		line_runs = []
		runs_by_line[line_key] = line_runs
	var bit := 0
	while bit < OUTLINE_CHUNK:
		if bits & (1 << bit) == 0:
			bit += 1
			continue
		var run_start := bit
		while bit + 1 < OUTLINE_CHUNK and bits & (1 << (bit + 1)) != 0:
			bit += 1
		line_runs.append(Vector2i(run_offset + run_start * 2 - 1, run_offset + bit * 2 + 1))
		bit += 1


func _start_preview() -> void:
	if _preview_job or _pending_cells.is_empty() or Time.get_ticks_msec() < _request_due_ms:
		return
	_preview_job = _new_job()
	_preview_job.cells = _pending_cells
	_preview_job.mask_chunks = _requested_masks
	_preview_job.outline_builder = _outline_vertices
	_preview_job.mask_outline_builder = _outline_from_masks
	_preview_job.style = _requested_style
	_preview_job.use_voxel_colors = _requested_voxel_colors
	_preview_job.smooth_normals = _requested_smooth_normals
	_preview_job.ao_strength = _requested_ao_strength
	_preview_job.color_key = _requested_color_key
	_preview_job.revision = _request_revision
	_preview_job.token = _requested_token
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
	# [method installed_cells] to match a visible preview to a later click. The
	# token keeps the identity of the request that produced this result, so a
	# coalesced intermediate surface still names its own request.
	_installed_cells = job.cells
	_installed_token = job.token


## Returns the immutable cells of the last installed surface, or an empty
## dictionary when no preview is visible. The caller must not change the result.
func installed_cells() -> Dictionary:
	return _installed_cells


## Returns the opaque request token of the last installed surface, or null when
## no preview is visible or the caller gave no token. A caller reads it to
## attribute the visible surface to the request that produced it. A cache hit
## reports the token of the request that asked for the hit.
func installed_token() -> Variant:
	return _installed_token


static func _surface_material() -> StandardMaterial3D:
	var material: StandardMaterial3D = preload("res://VoxelMaterial.tres").duplicate()
	# Cached surfaces can also appear in reflected brush cursors.
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


static func _atlas_material(job: VoxelMeshBuilder) -> StandardMaterial3D:
	var material := _surface_material()
	if job.atlas:
		material = job.atlas.create_material(material)
	else:
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
	if job.ao_strength > 0.0:
		material.vertex_color_use_as_albedo = true
		material.vertex_color_is_srgb = false
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


# Runs on one line merge when the next start touches the open end. The native
# sort keeps the ascending start order. A run is a half-unit start and end.
static func _merged_outline(runs_by_line: Dictionary, job: VoxelFrame.EditJob = null) -> PackedVector3Array:
	var outline_vertices := PackedVector3Array()
	var completed := 0
	for line_key: Vector3i in runs_by_line:
		if job and not job.checkpoint(completed):
			return PackedVector3Array()
		var line_runs: Array = runs_by_line[line_key]
		completed += line_runs.size()
		line_runs.sort()
		var merged_run: Vector2i = line_runs[0]
		for run_index in range(1, line_runs.size()):
			var next_run: Vector2i = line_runs[run_index]
			if next_run.x <= merged_run.y:
				merged_run.y = maxi(merged_run.y, next_run.y)
			else:
				_emit_run(outline_vertices, line_key.x, line_key.y, line_key.z, merged_run)
				merged_run = next_run
		_emit_run(outline_vertices, line_key.x, line_key.y, line_key.z, merged_run)
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
