extends MeshInstance3D

var _single_cell_outline: ArrayMesh
var _pending_selection: VoxelSelection
var _request_revision := 0
var _outline_due_ms := 0
var _outline_job: OutlineJob

class OutlineJob extends RefCounted:
	var selection_snapshot: VoxelSelection
	var outline_vertices := PackedVector3Array()
	var request_revision := 0
	var worker_task_id := -1

func show_selection(selection: VoxelSelection) -> void:
	_request_revision += 1
	if selection == null or selection.is_empty():
		_pending_selection = null
		visible = false
		return
	if selection.count() > 4096:
		_pending_selection = selection
		_outline_due_ms = Time.get_ticks_msec() + 100
		return
	_pending_selection = null
	mesh = outline_mesh(selection)
	position = Vector3.ZERO
	visible = true


func show_cell(cell_position: Vector3i) -> void:
	_request_revision += 1
	_pending_selection = null
	if cell_position == VoxelPicking.NONE:
		visible = false
		return
	if _single_cell_outline == null:
		var single_cell_selection := VoxelSelection.new()
		single_cell_selection.add(Vector3i.ZERO)
		_single_cell_outline = outline_mesh(single_cell_selection)
	mesh = _single_cell_outline
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


static func _outline_vertices(selection: VoxelSelection) -> PackedVector3Array:
	var boundary_edges := []
	for cell_position in selection.all_cells():
		boundary_edges.append_array(_boundary_edges(cell_position, selection))
	return _merged_outline(boundary_edges)


static func _build_outline(outline_job: OutlineJob) -> void:
	outline_job.outline_vertices = _outline_vertices(outline_job.selection_snapshot)


func _process(_delta: float) -> void:
	if _outline_job:
		if not WorkerThreadPool.is_task_completed(_outline_job.worker_task_id):
			return
		WorkerThreadPool.wait_for_task_completion(_outline_job.worker_task_id)
		if _outline_job.request_revision == _request_revision:
			mesh = _mesh_from_vertices(_outline_job.outline_vertices)
			position = Vector3.ZERO
			visible = true
		_outline_job = null
	if _pending_selection and Time.get_ticks_msec() >= _outline_due_ms:
		_outline_job = OutlineJob.new()
		_outline_job.selection_snapshot = VoxelSelection.new()
		_outline_job.selection_snapshot.restore(_pending_selection.capture())
		_outline_job.request_revision = _request_revision
		_outline_job.worker_task_id = WorkerThreadPool.add_task(_build_outline.bind(_outline_job), false, "Selection outline")
		_pending_selection = null


func _exit_tree() -> void:
	if _outline_job:
		WorkerThreadPool.wait_for_task_completion(_outline_job.worker_task_id)
		_outline_job = null


func is_settled() -> bool:
	return _pending_selection == null and _outline_job == null


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


static func _merged_outline(boundary_edges: Array) -> PackedVector3Array:
	var edge_runs_by_line := {}
	for edge in boundary_edges:
		var line_key := Vector3i(edge[0], edge[1], edge[2])
		if not edge_runs_by_line.has(line_key):
			edge_runs_by_line[line_key] = []
		edge_runs_by_line[line_key].append(Vector2i(edge[3], edge[4]))
	var outline_vertices := PackedVector3Array()
	for line_key in edge_runs_by_line:
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
