extends RefCounted

# Frozen copy of the VoxelPreview outline builder, taken before the shared
# neighbor scan replaced it. It calls no production code, so a change to the
# live builder cannot change this reference. The parity test compares the two.
#
# The reference keeps the original shape: one five-element array per cell edge,
# grouped by line, then merged with a start-sorted comparator.


static func outline_vertices(selection: VoxelSelection, job: VoxelFrame.EditJob = null) -> PackedVector3Array:
	var boundary_edges := []
	var completed := 0
	for cell_position in selection.all_cells():
		boundary_edges.append_array(boundary_edges_of(cell_position, selection))
		completed += 1
		if job and completed % 4096 == 0 and not job.checkpoint(completed):
			return PackedVector3Array()
	return merged_outline(boundary_edges, job)


static func boundary_edges_of(cell_position: Vector3i, selection: VoxelSelection) -> Array:
	var boundary_edges := []
	for edge_axis in 3:
		var first_side_axis := (edge_axis + 1) % 3
		var second_side_axis := (edge_axis + 2) % 3
		for first_side_sign in [-1, 1]:
			for second_side_sign in [-1, 1]:
				var first_neighbor := shifted(cell_position, first_side_axis, first_side_sign)
				var second_neighbor := shifted(cell_position, second_side_axis, second_side_sign)
				if selection.contains(first_neighbor) and selection.contains(second_neighbor):
					continue
				var diagonal_neighbor := shifted(first_neighbor, second_side_axis, second_side_sign)
				if selection.contains(first_neighbor) != selection.contains(second_neighbor) and not selection.contains(diagonal_neighbor):
					continue
				boundary_edges.append([edge_axis, cell_position[first_side_axis] * 2 + first_side_sign, cell_position[second_side_axis] * 2 + second_side_sign, cell_position[edge_axis] * 2 - 1, cell_position[edge_axis] * 2 + 1])
	return boundary_edges


static func shifted(cell_position: Vector3i, axis: int, offset: int) -> Vector3i:
	var neighbor_position := cell_position
	neighbor_position[axis] += offset
	return neighbor_position


static func merged_outline(boundary_edges: Array, job: VoxelFrame.EditJob = null) -> PackedVector3Array:
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
				emit_run(outline_vertices, line_key.x, line_key.y, line_key.z, merged_run)
				merged_run = next_run
		emit_run(outline_vertices, line_key.x, line_key.y, line_key.z, merged_run)
	return outline_vertices


static func emit_run(outline_vertices: PackedVector3Array, edge_axis: int, first_side_coord: int, second_side_coord: int, merged_run: Vector2i) -> void:
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
