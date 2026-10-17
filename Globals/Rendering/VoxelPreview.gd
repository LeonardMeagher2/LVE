extends MeshInstance3D

enum PreviewStyle { OUTLINE, SOLID }

const INLINE_OUTLINE_LIMIT := 4096
const CACHE_LIMIT_BYTES := 64 * 1024 * 1024
const CACHE_LIMIT_ENTRIES := 16

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
var _box := BoxMesh.new()
var _outline_material: Material
var _solid_material := preload("res://VoxelMaterial.tres").duplicate()
var _box_material := preload("res://VoxelMaterial.tres").duplicate()
var _brush_material := VoxelFrame.material(Color.WHITE)

class PreviewJob extends VoxelFrame.EditJob:
	var cells := {}
	var style := PreviewStyle.OUTLINE
	var use_voxel_colors := false
	var smooth_normals := false
	var color_key := Color.WHITE
	var revision := 0
	var cache_key := ""
	var arrays := []
	var atlas_surfaces: Array[VoxelMeshBuilder] = []
	var geometry_bytes := 0
	var outline_builder: Callable

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


func _ready() -> void:
	_outline_material = material_override
	_solid_material.albedo_color = Color.WHITE
	_box_material.vertex_color_use_as_albedo = false


func set_brush_color(color: Color) -> void:
	set_brush_material(VoxelFrame.material(color))


func set_brush_material(cell_material: PackedFloat32Array) -> void:
	_brush_material = cell_material.duplicate()
	_apply_material(_box_material, cell_material)
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


func show_voxels(colors: Dictionary, color: Color, outline: bool = false, cube_diameter: int = 0, use_voxel_colors: bool = true) -> void:
	if colors.is_empty():
		_clear_request()
		return
	if outline:
		material_override = _outline_material
		_request(colors, PreviewStyle.OUTLINE)
		return
	if cube_diameter > 0:
		_clear_request()
		_box.size = Vector3.ONE * cube_diameter
		_box_material.albedo_color = color
		material_override = _box_material
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


func show_selection(selection: VoxelSelection) -> void:
	if selection == null or selection.is_empty():
		_clear_request()
		return
	material_override = _outline_material
	_request(selection.capture(), PreviewStyle.OUTLINE)


func _request(cells: Dictionary, style: PreviewStyle, use_voxel_colors: bool = false, color_key: Color = Color.WHITE) -> void:
	var colored := style == PreviewStyle.SOLID and use_voxel_colors
	var smooth_normals := style == PreviewStyle.SOLID and State.document.smooth_normals
	if style == _requested_style and use_voxel_colors == _requested_voxel_colors and smooth_normals == _requested_smooth_normals and color_key == _requested_color_key and _same_cells(_requested_cells, cells, colored):
		return
	_request_revision += 1
	if _preview_job:
		_preview_job.cancel()
	_requested_style = style
	_requested_voxel_colors = use_voxel_colors
	_requested_smooth_normals = smooth_normals
	_requested_color_key = color_key
	_requested_cells = cells if cells.is_read_only() else cells.duplicate(true)
	_requested_cells.make_read_only()
	_pending_cells = {}
	var cache_key := _cache_key(_requested_cells, style, colored, color_key, smooth_normals)
	_requested_cache_key = cache_key
	var cached: Dictionary = _mesh_cache.get(cache_key, {})
	if not cached.is_empty() and cached.color_key == color_key and _same_cells(cached.cells, _requested_cells, colored):
		mesh = cached.surface
		position = Vector3.ZERO
		visible = true
		_cache_order.erase(cache_key)
		_cache_order.append(cache_key)
		_finish_activity()
		return
	_pending_cells = _requested_cells
	_request_due_ms = Time.get_ticks_msec() + 100 if style == PreviewStyle.OUTLINE and cells.size() > INLINE_OUTLINE_LIMIT else 0
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
	_requested_cells = {}
	_pending_cells = {}
	if _preview_job:
		_preview_job.cancel()
	visible = false
	_finish_activity()


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
	var boundary_edges := []
	var completed := 0
	for cell_position in selection.all_cells():
		boundary_edges.append_array(_boundary_edges(cell_position, selection))
		completed += 1
		if job and completed % 4096 == 0 and not job.checkpoint(completed):
			return PackedVector3Array()
	return _merged_outline(boundary_edges, job)


func _start_preview() -> void:
	if _preview_job or _pending_cells.is_empty() or Time.get_ticks_msec() < _request_due_ms:
		return
	_preview_job = PreviewJob.new()
	_preview_job.cells = _pending_cells
	_preview_job.outline_builder = _outline_vertices
	_preview_job.style = _requested_style
	_preview_job.use_voxel_colors = _requested_voxel_colors
	_preview_job.smooth_normals = _requested_smooth_normals
	_preview_job.color_key = _requested_color_key
	_preview_job.revision = _request_revision
	_preview_job.cache_key = _requested_cache_key
	_pending_cells = {}
	if _preview_job.style == PreviewStyle.OUTLINE and _preview_job.cells.size() <= INLINE_OUTLINE_LIMIT:
		_preview_job.run()
		_finish_preview()
	else:
		_preview_job.worker_task_id = WorkerThreadPool.add_task(_preview_job.run, false, "Voxel preview")


func _process(_delta: float) -> void:
	var current_frame := Engine.get_process_frames()
	if _install_frame != current_frame:
		_install_frame = current_frame
		_install_time_us = 0
	if _preview_job:
		if WorkerThreadPool.is_task_completed(_preview_job.worker_task_id):
			if _preview_job.revision == _request_revision and _install_time_us >= State.WORK_SLICE_US:
				return
			WorkerThreadPool.wait_for_task_completion(_preview_job.worker_task_id)
			var started_us := Time.get_ticks_usec()
			_finish_preview()
			_install_time_us += Time.get_ticks_usec() - started_us
		else:
			var progress := _preview_job.progress()
			State.update_operation(_operation_id, progress[1], progress[2], progress[0])
	_start_preview()
	if is_settled():
		_finish_activity()


func _finish_preview() -> void:
	var job := _preview_job
	_preview_job = null
	if job.revision != _request_revision or not job.checkpoint(0):
		return
	var surface := ArrayMesh.new()
	if not job.arrays[Mesh.ARRAY_VERTEX].is_empty():
		var primitive := Mesh.PRIMITIVE_LINES if job.style == PreviewStyle.OUTLINE else Mesh.PRIMITIVE_TRIANGLES
		surface.add_surface_from_arrays(primitive, job.arrays)
		if job.style == PreviewStyle.SOLID:
			surface.surface_set_material(0, _surface_material())
	for chunk_job in job.atlas_surfaces:
		surface.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, chunk_job.surface_arrays)
		surface.surface_set_material(surface.get_surface_count() - 1, _atlas_material(chunk_job))
	_cache_mesh(job, surface)
	mesh = surface
	position = Vector3.ZERO
	visible = surface.get_surface_count() > 0
	_finish_activity()


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
	_preview_count -= 1
	if _preview_count == 0:
		_mesh_cache.clear()
		_cache_order.clear()
		_cache_bytes = 0


func _start_activity() -> void:
	if not State.has_operation(_operation_id):
		_operation_id = State.begin_operation("Updating voxel preview", -1, false, self)


func _finish_activity() -> void:
	State.finish_operation(_operation_id)
	_operation_id = 0


func is_settled() -> bool:
	return _pending_cells.is_empty() and _preview_job == null


static func _boundary_edges(cell_position: Vector3i, selection: VoxelSelection) -> Array:
	var boundary_edges := []
	for edge_axis in 3:
		var first_side_axis := (edge_axis + 1) % 3
		var second_side_axis := (edge_axis + 2) % 3
		for first_side_sign in [-1, 1]:
			for second_side_sign in [-1, 1]:
				var first_neighbor := _shifted(cell_position, first_side_axis, first_side_sign)
				var second_neighbor := _shifted(cell_position, second_side_axis, second_side_sign)
				if selection.contains(first_neighbor) and selection.contains(second_neighbor):
					continue
				var diagonal_neighbor := _shifted(first_neighbor, second_side_axis, second_side_sign)
				if selection.contains(first_neighbor) != selection.contains(second_neighbor) and not selection.contains(diagonal_neighbor):
					continue
				boundary_edges.append([edge_axis, cell_position[first_side_axis] * 2 + first_side_sign, cell_position[second_side_axis] * 2 + second_side_sign, cell_position[edge_axis] * 2 - 1, cell_position[edge_axis] * 2 + 1])
	return boundary_edges


static func _shifted(cell_position: Vector3i, axis: int, offset: int) -> Vector3i:
	var neighbor_position := cell_position
	neighbor_position[axis] += offset
	return neighbor_position


static func _merged_outline(boundary_edges: Array, job: VoxelFrame.EditJob = null) -> PackedVector3Array:
	var edge_runs_by_line := {}
	var completed := 0
	for edge in boundary_edges:
		var line_key := Vector3i(edge[0], edge[1], edge[2])
		if not edge_runs_by_line.has(line_key):
			edge_runs_by_line[line_key] = []
		edge_runs_by_line[line_key].append(Vector2i(edge[3], edge[4]))
		completed += 1
		if job and completed % 4096 == 0 and not job.checkpoint(completed):
			return PackedVector3Array()
	var outline_vertices := PackedVector3Array()
	for line_key in edge_runs_by_line:
		if job and not job.checkpoint(completed):
			return PackedVector3Array()
		var line_runs: Array = edge_runs_by_line[line_key]
		line_runs.sort_custom(func(first_run, second_run): return first_run.x < second_run.x)
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
