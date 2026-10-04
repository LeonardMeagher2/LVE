extends "res://Plugins/Selection/SelectionPreview.gd"

var _solid_revision := 0
var _solid_job: SolidJob
var _pending_colors := {}
var _pending_color := Color.WHITE
var _solid_operation_id := 0
var _box := BoxMesh.new()
var _solid_material := preload("res://VoxelMaterial.tres").duplicate()
var _box_material := preload("res://VoxelMaterial.tres").duplicate()
var _outline_material := preload("res://Plugins/cursor_material.tres").duplicate()

class SolidJob extends VoxelFrame.EditJob:
	var cell_colors := {}
	var brush_color := Color.WHITE
	var revision := 0
	var arrays := []

	func run() -> void:
		stage("Preparing solid preview", cell_colors.size())
		var colors := {}
		for cell_position in cell_colors:
			var color: Color = cell_colors[cell_position]
			colors[cell_position] = brush_color if color == Color.TRANSPARENT else color
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
			var job := VoxelRenderer.MeshJob.new()
			job.source_frame = frame
			job.chunk_location = chunk_location
			job.run()
			var vertex_offset := vertices.size()
			var chunk_origin := Vector3(chunk_location * VoxelFrame.CHUNK_SIZE)
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


func _ready() -> void:
	_solid_material.albedo_color = Color.WHITE
	_box_material.vertex_color_use_as_albedo = false
	material_override = _solid_material


func set_brush_color(color: Color) -> void:
	_box_material.albedo_color = color


func show_voxels(colors: Dictionary, color: Color, outline: bool = false, cube_diameter: int = 0) -> void:
	_clear_solid()
	if colors.is_empty():
		super.show_selection(null)
		return
	if outline:
		material_override = _outline_material
		var selection := VoxelSelection.new()
		selection.restore(colors)
		super.show_selection(selection)
		return
	var was_visible := visible
	super.show_selection(null)
	if cube_diameter > 0:
		_box.size = Vector3.ONE * cube_diameter
		_box_material.albedo_color = color
		material_override = _box_material
		mesh = _box
		position = Vector3.ONE * -0.5 if cube_diameter % 2 == 0 else Vector3.ZERO
		visible = true
		return
	visible = was_visible and mesh != null
	_pending_colors = colors
	_pending_color = color
	_solid_operation_id = State.begin_operation("Updating solid preview", colors.size(), false, self)
	_start_solid()


func show_selection(selection: VoxelSelection) -> void:
	_clear_solid()
	super.show_selection(selection)


func _clear_solid() -> void:
	_solid_revision += 1
	_pending_colors = {}
	if _solid_job:
		_solid_job.cancel()
	State.finish_operation(_solid_operation_id)
	_solid_operation_id = 0


func _start_solid() -> void:
	if _solid_job or _pending_colors.is_empty():
		return
	_solid_job = SolidJob.new()
	_solid_job.cell_colors = _pending_colors
	_solid_job.brush_color = _pending_color
	_solid_job.revision = _solid_revision
	_pending_colors = {}
	_solid_job.worker_task_id = WorkerThreadPool.add_task(_solid_job.run, false, "Solid brush preview")


func _process(delta: float) -> void:
	super._process(delta)
	if _solid_job and WorkerThreadPool.is_task_completed(_solid_job.worker_task_id):
		WorkerThreadPool.wait_for_task_completion(_solid_job.worker_task_id)
		if _solid_job.revision == _solid_revision and not _solid_job.arrays.is_empty():
			var surface := ArrayMesh.new()
			surface.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _solid_job.arrays)
			mesh = surface
			material_override = _solid_material
			position = Vector3.ZERO
			visible = true
		_solid_job = null
	_start_solid()
	if _solid_job == null and _pending_colors.is_empty():
		State.finish_operation(_solid_operation_id)
		_solid_operation_id = 0


func is_settled() -> bool:
	return super.is_settled() and _solid_job == null and _pending_colors.is_empty()


func _exit_tree() -> void:
	_clear_solid()
	if _solid_job:
		WorkerThreadPool.wait_for_task_completion(_solid_job.worker_task_id)
		_solid_job = null
	super._exit_tree()
