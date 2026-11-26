extends RefCounted


var host
var renderer
var positions := PackedVector3Array()
var normals := PackedVector3Array()
var colors := PackedColorArray()
var indices := PackedInt32Array()


func _init(test_host) -> void:
	host = test_host


func attach() -> void:
	renderer = host.editor_viewport().get_node("ViewportScene/VoxelRenderer")


func apply(cells: Dictionary, style := 1) -> void:
	State.get_current_voxel_frame().set_cells(cells)
	State.set_mesh_style(style, false)
	renderer = host.editor_viewport().get_node("ViewportScene/VoxelRenderer")
	State.frames_changed.emit()
	host.sync_viewport()
	host.camera_rig().center_active()


func settle() -> void:
	while not renderer.is_settled():
		await host.get_tree().process_frame
	for frame in 3:
		await host.get_tree().process_frame


func collect() -> void:
	positions = PackedVector3Array()
	normals = PackedVector3Array()
	colors = PackedColorArray()
	indices = PackedInt32Array()
	for location: Vector3i in renderer._chunk_instances:
		var instance: MeshInstance3D = renderer._chunk_instances[location]
		var mesh: Mesh = instance.mesh
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var arrays := mesh.surface_get_arrays(0)
		var offset := Vector3(location * VoxelFrame.CHUNK_SIZE)
		var first := positions.size()
		for position: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
			positions.append(position + offset)
		normals.append_array(arrays[Mesh.ARRAY_NORMAL])
		colors.append_array(arrays[Mesh.ARRAY_COLOR])
		for vertex: int in arrays[Mesh.ARRAY_INDEX]:
			indices.append(first + vertex)


func closed() -> bool:
	var canonical := weld()
	var edges := {}
	for offset in range(0, indices.size(), 3):
		for corner in 3:
			var start := canonical[indices[offset + corner]]
			var end := canonical[indices[offset + (corner + 1) % 3]]
			var key := Vector2i(start, end)
			edges[key] = edges.get(key, 0) + 1
	for key: Vector2i in edges:
		if not edges.has(Vector2i(key.y, key.x)):
			return false
		if edges[key] != edges[Vector2i(key.y, key.x)]:
			return false
	return not edges.is_empty()


func components() -> int:
	var canonical := weld()
	var vertex_triangles: Array = []
	vertex_triangles.resize(canonical.size())
	for index in canonical.size():
		vertex_triangles[index] = []
	var triangle_count := indices.size() / 3
	for triangle in triangle_count:
		for corner in 3:
			vertex_triangles[canonical[indices[triangle * 3 + corner]]].append(triangle)
	var visited := PackedByteArray()
	visited.resize(triangle_count)
	var components := 0
	for triangle in triangle_count:
		if visited[triangle] != 0:
			continue
		components += 1
		var stack: Array[int] = [triangle]
		visited[triangle] = 1
		while not stack.is_empty():
			var current: int = stack.pop_back()
			for corner in 3:
				for neighbor: int in vertex_triangles[canonical[indices[current * 3 + corner]]]:
					if visited[neighbor] == 0:
						visited[neighbor] = 1
						stack.append(neighbor)
	return components


func duplicates() -> int:
	var canonical := weld()
	var seen := {}
	var duplicates := 0
	for offset in range(0, indices.size(), 3):
		var corners := [canonical[indices[offset]], canonical[indices[offset + 1]], canonical[indices[offset + 2]]]
		corners.sort()
		var key := Vector3i(corners[0], corners[1], corners[2])
		seen[key] = seen.get(key, 0) + 1
		if seen[key] > 1:
			duplicates += 1
	return duplicates


func bounds() -> AABB:
	var box := AABB(positions[0], Vector3.ZERO)
	for position in positions:
		box = box.expand(position)
	return box


func volume() -> float:
	var total := 0.0
	for offset in range(0, indices.size(), 3):
		total += positions[indices[offset]].dot(positions[indices[offset + 1]].cross(positions[indices[offset + 2]])) / 6.0
	return absf(total)


func has_gap_face() -> bool:
	for offset in range(0, indices.size(), 3):
		var centroid := (positions[indices[offset]] + positions[indices[offset + 1]] + positions[indices[offset + 2]]) / 3.0
		if centroid.x > 0.3 and centroid.x < 0.7 and centroid.y > 0.3 and centroid.y < 0.7 and absf(centroid.z) > 0.25:
			return true
	return false


func fills_notch() -> bool:
	for position in positions:
		if position.x > 1.3 and position.y > 0.8 and position.y < 1.2:
			return true
	return false


func has_vertex(point: Vector3) -> bool:
	for position in positions:
		if position.is_equal_approx(point):
			return true
	return false


func weld() -> PackedInt32Array:
	var welded := {}
	var canonical := PackedInt32Array()
	canonical.resize(positions.size())
	for index in positions.size():
		var key := Vector3i(
			roundi(positions[index].x * 1024.0),
			roundi(positions[index].y * 1024.0),
			roundi(positions[index].z * 1024.0)
		)
		if not welded.has(key):
			welded[key] = welded.size()
		canonical[index] = welded[key]
	return canonical
