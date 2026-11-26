class_name VoxelMarchingMeshBuilder
extends RefCounted


const CHUNK_SIZE := VoxelFrame.CHUNK_SIZE
const SAMPLE_PADDING := 3
const MESH_PADDING := 2
const SAMPLE_SIZE := CHUNK_SIZE + SAMPLE_PADDING * 2
const FACE_OFFSETS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
const EDGE_OFFSETS: Array[Vector3i] = [
	Vector3i(1, 1, 0), Vector3i(1, -1, 0), Vector3i(-1, 1, 0), Vector3i(-1, -1, 0),
	Vector3i(1, 0, 1), Vector3i(1, 0, -1), Vector3i(-1, 0, 1), Vector3i(-1, 0, -1),
	Vector3i(0, 1, 1), Vector3i(0, 1, -1), Vector3i(0, -1, 1), Vector3i(0, -1, -1),
]
const CORNER_OFFSETS: Array[Vector3i] = [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0),
	Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(0, 1, 1), Vector3i(1, 1, 1),
]
const EDGE_CORNERS: Array = [
	[0, 1], [1, 3], [3, 2], [2, 0],
	[4, 5], [5, 7], [7, 6], [6, 4],
	[0, 4], [1, 5], [3, 7], [2, 6],
]
const FACES: Array = [
	[[0, 1, 3, 2], [0, 1, 2, 3]],
	[[4, 5, 7, 6], [4, 5, 6, 7]],
	[[0, 2, 6, 4], [3, 11, 7, 8]],
	[[1, 3, 7, 5], [1, 10, 5, 9]],
	[[0, 4, 5, 1], [8, 4, 9, 0]],
	[[2, 3, 7, 6], [2, 10, 6, 11]],
]
const FACE_AXES: Array[int] = [2, 0, 1]
const PRESENT_SELF := 13
const FIELD_RADIUS := 2

static var _case_cache: Dictionary = {}
static var _edge_faces: PackedInt32Array = PackedInt32Array()

var source_frame: VoxelFrame
var chunk_location := Vector3i.ZERO
var surface_arrays: Array = []
var atlas: RefCounted
var atlas_size := Vector2i.ZERO
var atlas_albedo := PackedByteArray()
var atlas_orm := PackedByteArray()
var atlas_emission := PackedByteArray()
var geometry_bytes := 0
var enclosed_culled := false
var worker_task_id := -1
var ao_strength := 0.0
var slice_axis := -1
var slice_index := 0
var slice_count := 1
var per_material := false
var hard_boundaries := false
var _pinned_seams: Dictionary = {}

var material_groups: Array = []


static func _static_init() -> void:
	_edge_faces.resize(EDGE_CORNERS.size() + FACES.size() * 2)
	for face in FACES.size():
		for edge: int in FACES[face][1]:
			_edge_faces[edge] |= 1 << face
		_edge_faces[EDGE_CORNERS.size() + face * 2] |= 1 << face
		_edge_faces[EDGE_CORNERS.size() + face * 2 + 1] |= 1 << face
	for bits in 256:
		_case_data(bits, 0)


static func _case_data(bits: int, mask: int) -> Dictionary:
	var key := (bits << 6) | mask
	if _case_cache.has(key):
		return _case_cache[key]
	var loops := _case_loops_for(bits, mask)
	var triangles: Array[PackedInt32Array] = []
	for loop: PackedInt32Array in loops:
		triangles.append(_triangulate_loop(loop))
	var face_triangles: Array = []
	face_triangles.resize(FACES.size())
	for face in FACES.size():
		face_triangles[face] = []
	for group: PackedInt32Array in triangles:
		for index in range(0, group.size(), 3):
			var common := 63
			for corner in 3:
				common &= _edge_faces[group[index + corner]]
			var face := -1
			for candidate in FACES.size():
				if common == 1 << candidate:
					face = candidate
					break
			if face < 0:
				continue
			face_triangles[face].append(PackedInt32Array([group[index], group[index + 1], group[index + 2]]))
	var data := {"loops": loops, "triangles": triangles, "face_triangles": face_triangles}
	_case_cache[key] = data
	return data


func run() -> void:
	var frame := source_frame
	source_frame = null
	var occupancy := PackedByteArray()
	var material_ids := PackedInt32Array()
	var materials := PackedFloat32Array()
	var present := PackedByteArray()
	if frame != null:
		var sampled := _sample(frame, chunk_location, slice_axis, slice_index, slice_count)
		occupancy = sampled[0]
		material_ids = sampled[1]
		materials = sampled[2]
		present = sampled[3]
	_build(occupancy, material_ids, materials, present)


func _sample(frame: VoxelFrame, location: Vector3i, slice_axis: int, slice_index: int, slice_count: int) -> Array:
	var cells := SAMPLE_SIZE * SAMPLE_SIZE * SAMPLE_SIZE
	var occupancy := PackedByteArray()
	occupancy.resize(cells)
	var material_ids := PackedInt32Array()
	material_ids.resize(cells)
	var materials := VoxelFrame.material(Color.TRANSPARENT)
	var material_table := {}
	var sample_origin := location * CHUNK_SIZE - Vector3i.ONE * SAMPLE_PADDING
	var present := PackedByteArray()
	present.resize(27)
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				if frame.chunks.has(location + Vector3i(x, y, z)):
					present[(x + 1) + 3 * ((y + 1) + 3 * (z + 1))] = 1
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				var neighbor: VoxelFrame.Chunk = frame.chunks.get(location + Vector3i(x, y, z))
				if neighbor == null:
					continue
				var origin_delta := neighbor.origin() - sample_origin
				var x_first := maxi(0, -origin_delta.x)
				var x_last := mini(CHUNK_SIZE, SAMPLE_SIZE - origin_delta.x)
				var y_first := maxi(0, -origin_delta.y)
				var y_last := mini(CHUNK_SIZE, SAMPLE_SIZE - origin_delta.y)
				var z_first := maxi(0, -origin_delta.z)
				var z_last := mini(CHUNK_SIZE, SAMPLE_SIZE - origin_delta.z)
				var rows := neighbor.occupancy_rows()
				var neighbor_materials := neighbor.materials
				var row_ids := {}
				var slice_last := slice_index + slice_count
				for row in rows.masks.size():
					var mask := rows.masks[row]
					if mask == 0:
						continue
					var local_y := row % CHUNK_SIZE
					var local_z := row / CHUNK_SIZE
					if local_y < y_first or local_y >= y_last or local_z < z_first or local_z >= z_last:
						continue
					var sample_y := origin_delta.y + local_y
					var sample_z := origin_delta.z + local_z
					while mask != 0:
						var local_x := VoxelFrame.Chunk.first_column(mask)
						mask &= mask - 1
						if local_x < x_first or local_x >= x_last:
							continue
						if slice_axis >= 0:
							var local_layer := local_x if slice_axis == 0 else (local_y if slice_axis == 1 else local_z)
							var layer := neighbor.location[slice_axis] * CHUNK_SIZE + local_layer
							if layer < slice_index or layer >= slice_last:
								continue
						var id := neighbor.cell_id_at_slot(row * CHUNK_SIZE + local_x)
						if id == 0:
							continue
						var sample_x := origin_delta.x + local_x
						var index := sample_x + SAMPLE_SIZE * (sample_y + SAMPLE_SIZE * sample_z)
						occupancy[index] = 1
						var base := (id - 1) * VoxelFrame.MATERIAL_STRIDE
						var cell_material := neighbor_materials.slice(base, base + VoxelFrame.MATERIAL_STRIDE)
						var material_id: int = row_ids.get(id, 0)
						if material_id == 0:
							material_id = material_table.get(cell_material, 0)
							if material_id == 0:
								material_id = materials.size() / VoxelFrame.MATERIAL_STRIDE
								material_table[cell_material] = material_id
								materials.append_array(cell_material)
							row_ids[id] = material_id
						material_ids[index] = material_id
	return [occupancy, material_ids, materials, present]


func _build(occupancy: PackedByteArray, material_ids: PackedInt32Array, materials: PackedFloat32Array, present: PackedByteArray) -> void:
	if present.is_empty() or present[PRESENT_SELF] == 0:
		_set_empty()
		return
	_pinned_seams.clear()
	var owners := _build_owners(present)
	var merged: Array
	if per_material:
		merged = _build_per_material(occupancy, material_ids, materials, owners)
	else:
		var built := _build_surfaces(occupancy, material_ids, materials, owners)
		merged = built
	var welded := _weld(merged[0], merged[1], merged[2], merged[3], merged[4])
	_pinch_material_seams(welded[0], welded[4], occupancy, material_ids, welded[3])
	welded[3] = _drop_degenerate_triangles(welded[0], welded[3])
	_flip_diagonals(welded[0], welded[3], welded[4])
	welded[3] = _drop_opposite_duplicate_triangles(welded[0], welded[3])
	_collapse_near_hole_vertices(welded[0], welded[3])
	welded[3] = _drop_degenerate_triangles(welded[0], welded[3])
	welded = _rebuild_flat_normals(welded[0], welded[1], welded[2], welded[4], welded[3], occupancy)
	welded = _fill_boundary_ears(welded[0], welded[1], welded[2], welded[3], welded[4], occupancy, material_ids, materials)
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays[Mesh.ARRAY_VERTEX] = welded[0]
	surface_arrays[Mesh.ARRAY_NORMAL] = welded[1]
	surface_arrays[Mesh.ARRAY_COLOR] = welded[2]
	surface_arrays[Mesh.ARRAY_INDEX] = welded[3]
	geometry_bytes = welded[0].size() * 40 + welded[3].size() * 4


func _set_empty() -> void:
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array()
	surface_arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array()
	surface_arrays[Mesh.ARRAY_COLOR] = PackedColorArray()
	surface_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array()


func _build_per_material(occupancy: PackedByteArray, material_ids: PackedInt32Array, materials: PackedFloat32Array, owners: PackedByteArray) -> Array:
	var material_set := {}
	for index in occupancy.size():
		if occupancy[index] != 0:
			material_set[material_ids[index]] = true
	var ids: Array = material_set.keys()
	ids.sort()
	var group_of_id := {}
	var group_count := 0
	var groups: Array = material_groups.duplicate(true)
	if groups.is_empty():
		for id: int in ids:
			group_of_id[id] = group_count
			group_count += 1
	else:
		for id: int in ids:
			var key := _material_key(id, materials)
			var group := -1
			for candidate in groups.size():
				var keys: Array = groups[candidate]
				if keys.has(key):
					group = candidate
					break
			if group < 0:
				group = group_count
				group_count += 1
				groups.append([key])
			group_of_id[id] = group
		group_count = groups.size()
	var masks: Array[PackedByteArray] = []
	masks.resize(group_count)
	for group in group_count:
		var mask := PackedByteArray()
		mask.resize(occupancy.size())
		masks[group] = mask
	for index in occupancy.size():
		if occupancy[index] == 0:
			continue
		masks[group_of_id[material_ids[index]]][index] = 1
	var all_positions := PackedVector3Array()
	var all_normals := PackedVector3Array()
	var all_colors := PackedColorArray()
	var all_materials := PackedInt32Array()
	var all_indices := PackedInt32Array()
	for group in group_count:
		var mask: PackedByteArray = masks[group]
		var built := _build_surfaces(mask, material_ids, materials, owners)
		var merged := built
		var offset := all_positions.size()
		all_positions.append_array(merged[0])
		all_normals.append_array(merged[1])
		all_colors.append_array(merged[2])
		all_materials.append_array(merged[3])
		for index: int in merged[4]:
			all_indices.append(offset + index)
	return [all_positions, all_normals, all_colors, all_materials, all_indices]


static func _material_key(id: int, materials: PackedFloat32Array) -> String:
	var base := id * VoxelFrame.MATERIAL_STRIDE
	var parts := PackedStringArray()
	for offset in VoxelFrame.MATERIAL_STRIDE:
		parts.append(String.num(materials[base + offset], 3))
	return ",".join(parts)


func _build_surfaces(occupancy: PackedByteArray, material_ids: PackedInt32Array, materials: PackedFloat32Array, owners: PackedByteArray) -> Array:
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var vertex_colors := PackedColorArray()
	var vertex_materials := PackedInt32Array()
	var indices := PackedInt32Array()
	var field := _union_field(occupancy)
	for z in range(-MESH_PADDING, CHUNK_SIZE + 1):
		for y in range(-MESH_PADDING, CHUNK_SIZE + 1):
			for x in range(-MESH_PADDING, CHUNK_SIZE + 1):
				var cell := Vector3i(x, y, z)
				var bits := 0
				var cell_material := -1
				var cell_mixed := false
				for corner in 8:
					var sample := cell + CORNER_OFFSETS[corner] + Vector3i.ONE * SAMPLE_PADDING
					var sample_index := sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)
					if occupancy[sample_index] == 0:
						continue
					bits |= 1 << corner
					var corner_material := material_ids[sample_index]
					if cell_material < 0:
						cell_material = corner_material
					elif corner_material != cell_material:
						cell_mixed = true
				if bits == 0:
					continue
				var state_x := 0 if x <= 0 else (2 if x >= CHUNK_SIZE - 2 else 1)
				var state_y := 0 if y <= 0 else (2 if y >= CHUNK_SIZE - 2 else 1)
				var state_z := 0 if z <= 0 else (2 if z >= CHUNK_SIZE - 2 else 1)
				if owners[(state_x * 3 + state_y) * 3 + state_z] == 2:
					continue
				var mask := _diagonal_faces(bits)
				var case_data := _case_data(bits, mask)
				if _opposite_pair(bits) and _append_antiprism(cell, bits, case_data, field, occupancy, material_ids, materials, positions, normals, vertex_colors, vertex_materials, indices):
					continue
				var loops: Array = case_data["loops"]
				var loop_triangles: Array = case_data["triangles"]
				for loop_index in loops.size():
					var loop: PackedInt32Array = loops[loop_index]
					var triangle_edges: PackedInt32Array = loop_triangles[loop_index]
					if cell_mixed and _append_material_corner(cell, bits, loop, triangle_edges, occupancy, material_ids, materials, field, positions, normals, vertex_colors, vertex_materials, indices):
						continue
					if cell_mixed:
						var material_diagonal := _material_diagonal(cell, loop, occupancy, material_ids)
						if not material_diagonal.is_empty():
							triangle_edges = material_diagonal
					for index in range(0, triangle_edges.size(), 3):
						var first_edge := triangle_edges[index]
						var second_edge := triangle_edges[index + 1]
						var third_edge := triangle_edges[index + 2]
						if _mirror_on_face(cell, first_edge, second_edge, third_edge, occupancy):
							continue
						var first_point := _field_point(cell, first_edge, field)
						var second_point := _field_point(cell, second_edge, field)
						var third_point := _field_point(cell, third_edge, field)
						if cell_mixed:
							var first_sample := _edge_sample(cell, first_edge, occupancy, material_ids)
							var second_sample := _edge_sample(cell, second_edge, occupancy, material_ids)
							var third_sample := _edge_sample(cell, third_edge, occupancy, material_ids)
							_append_material_triangle(
								cell, bits,
								PackedVector3Array([first_point, second_point, third_point]),
								PackedInt32Array([first_sample[1], second_sample[1], third_sample[1]]),
								PackedVector3Array([first_sample[0], second_sample[0], third_sample[0]]),
								materials, positions, normals, vertex_colors, vertex_materials, indices
							)
							continue
						_append_oriented_triangle(
							cell, bits,
							first_point, second_point, third_point,
							cell_material, cell_material, cell_material,
							materials, positions, normals, vertex_colors, vertex_materials, indices
						)
	return [positions, normals, vertex_colors, vertex_materials, indices]


func _union_field(occupancy: PackedByteArray) -> PackedFloat32Array:
	var field := PackedFloat32Array()
	field.resize(SAMPLE_SIZE * SAMPLE_SIZE * SAMPLE_SIZE)
	field.fill(4.0)
	for z in SAMPLE_SIZE:
		for y in SAMPLE_SIZE:
			for x in SAMPLE_SIZE:
				var closest := 4.0
				for offset_z in range(-FIELD_RADIUS, FIELD_RADIUS + 1):
					var zz := z + offset_z
					if zz < 0 or zz >= SAMPLE_SIZE:
						continue
					for offset_y in range(-FIELD_RADIUS, FIELD_RADIUS + 1):
						var yy := y + offset_y
						if yy < 0 or yy >= SAMPLE_SIZE:
							continue
						for offset_x in range(-FIELD_RADIUS, FIELD_RADIUS + 1):
							var xx := x + offset_x
							if xx < 0 or xx >= SAMPLE_SIZE:
								continue
							if occupancy[xx + SAMPLE_SIZE * (yy + SAMPLE_SIZE * zz)] == 0:
								continue
							var qx := absf(offset_x) - 0.5
							var qy := absf(offset_y) - 0.5
							var qz := absf(offset_z) - 0.5
							var outside_x := maxf(qx, 0.0)
							var outside_y := maxf(qy, 0.0)
							var outside_z := maxf(qz, 0.0)
							var distance := sqrt(outside_x * outside_x + outside_y * outside_y + outside_z * outside_z) + minf(maxf(qx, maxf(qy, qz)), 0.0)
							closest = minf(closest, distance)
				field[x + SAMPLE_SIZE * (y + SAMPLE_SIZE * z)] = closest
	return field


static func _field_point(cell: Vector3i, edge: int, field: PackedFloat32Array) -> Vector3:
	if edge >= EDGE_CORNERS.size():
		return _edge_point(cell, edge)
	var corners: Array = EDGE_CORNERS[edge]
	var first: Vector3i = CORNER_OFFSETS[corners[0]]
	var second: Vector3i = CORNER_OFFSETS[corners[1]]
	var first_sample := cell + first + Vector3i.ONE * SAMPLE_PADDING
	var second_sample := cell + second + Vector3i.ONE * SAMPLE_PADDING
	var first_index := first_sample.x + SAMPLE_SIZE * (first_sample.y + SAMPLE_SIZE * first_sample.z)
	var second_index := second_sample.x + SAMPLE_SIZE * (second_sample.y + SAMPLE_SIZE * second_sample.z)
	var first_value := field[first_index]
	var second_value := field[second_index]
	var difference := first_value - second_value
	var t := 0.5
	if absf(difference) > 0.0001:
		t = clampf(first_value / difference, 0.02, 0.98)
	return Vector3(cell) + Vector3(first) + Vector3(second - first) * t


func _append_material_corner(cell: Vector3i, bits: int, loop: PackedInt32Array, triangle_edges: PackedInt32Array, occupancy: PackedByteArray, material_ids: PackedInt32Array, materials: PackedFloat32Array, field: PackedFloat32Array, positions: PackedVector3Array, normals: PackedVector3Array, vertex_colors: PackedColorArray, vertex_materials: PackedInt32Array, indices: PackedInt32Array) -> bool:
	if loop.size() != 4 or triangle_edges.size() != 6:
		return false
	var labels := PackedInt32Array()
	var counts := {}
	var points := PackedVector3Array()
	var sites := PackedVector3Array()
	for edge: int in loop:
		var sample := _edge_sample(cell, edge, occupancy, material_ids)
		labels.append(sample[1])
		sites.append(sample[0])
		points.append(_field_point(cell, edge, field))
		counts[sample[1]] = counts.get(sample[1], 0) + 1
	if counts.size() != 2:
		return false
	var normal := (points[1] - points[0]).cross(points[2] - points[0])
	if normal.length_squared() < 0.0000000001:
		return false
	if absf(normal.dot(points[3] - points[0])) > 0.0001:
		return false
	for index in 4:
		var next_index := (index + 1) % 4
		var after_index := (index + 2) % 4
		if (points[next_index] - points[index]).cross(points[after_index] - points[next_index]).dot(normal) < 0.0:
			return false
	var outlier := -1
	var majority := -1
	for label: int in counts:
		if counts[label] == 1:
			outlier = labels.find(label)
		else:
			majority = label
	if outlier < 0 or majority < 0:
		return false
	var constant_axis := -1
	for axis in 3:
		if absf(points[0][axis] - points[1][axis]) < 0.0001 and absf(points[0][axis] - points[2][axis]) < 0.0001 and absf(points[0][axis] - points[3][axis]) < 0.0001:
			constant_axis = axis
			break
	if constant_axis < 0:
		return false
	var first_axis := (constant_axis + 1) % 3
	var second_axis := (constant_axis + 2) % 3
	var origin := Vector3i(roundi(sites[outlier].x), roundi(sites[outlier].y), roundi(sites[outlier].z))
	var opposite := (outlier + 2) % 4
	var first_step := signi(roundi(points[opposite][first_axis] - points[outlier][first_axis]))
	var second_step := signi(roundi(points[opposite][second_axis] - points[outlier][second_axis]))
	if first_step == 0 or second_step == 0:
		return false
	var beyond := origin
	beyond[first_axis] -= first_step
	beyond[second_axis] -= second_step
	var sample := beyond + Vector3i.ONE * SAMPLE_PADDING
	if sample.x < 0 or sample.y < 0 or sample.z < 0 or sample.x >= SAMPLE_SIZE or sample.y >= SAMPLE_SIZE or sample.z >= SAMPLE_SIZE:
		return false
	var index := sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)
	var capped := occupancy[index] != 0 and material_ids[index] == labels[outlier]
	if _mirror_on_face(cell, triangle_edges[0], triangle_edges[1], triangle_edges[2], occupancy):
		return false
	if _mirror_on_face(cell, triangle_edges[3], triangle_edges[4], triangle_edges[5], occupancy):
		return false
	var previous := (outlier + 3) % 4
	var next := (outlier + 1) % 4
	var previous_cut := _material_cut(points[outlier], sites[outlier], points[previous], sites[previous])
	var next_cut := _material_cut(points[outlier], sites[outlier], points[next], sites[next])
	_append_oriented_triangle(cell, bits, points[outlier], previous_cut, next_cut, labels[outlier], labels[outlier], labels[outlier], materials, positions, normals, vertex_colors, vertex_materials, indices)
	if capped:
		var centre := (points[0] + points[1] + points[2] + points[3]) * 0.25
		_pinned_seams[_position_key(previous_cut)] = true
		_pinned_seams[_position_key(next_cut)] = true
		_pinned_seams[_position_key(centre)] = true
		_append_oriented_triangle(cell, bits, centre, previous_cut, next_cut, labels[outlier], labels[outlier], labels[outlier], materials, positions, normals, vertex_colors, vertex_materials, indices)
		_append_oriented_triangle(cell, bits, centre, next_cut, points[next], majority, majority, majority, materials, positions, normals, vertex_colors, vertex_materials, indices)
		_append_oriented_triangle(cell, bits, centre, points[next], points[opposite], majority, majority, majority, materials, positions, normals, vertex_colors, vertex_materials, indices)
		_append_oriented_triangle(cell, bits, centre, points[opposite], points[previous], majority, majority, majority, materials, positions, normals, vertex_colors, vertex_materials, indices)
		_append_oriented_triangle(cell, bits, centre, points[previous], previous_cut, majority, majority, majority, materials, positions, normals, vertex_colors, vertex_materials, indices)
		return true
	_append_oriented_triangle(cell, bits, points[opposite], points[next], next_cut, majority, majority, majority, materials, positions, normals, vertex_colors, vertex_materials, indices)
	_append_oriented_triangle(cell, bits, points[opposite], next_cut, previous_cut, majority, majority, majority, materials, positions, normals, vertex_colors, vertex_materials, indices)
	_append_oriented_triangle(cell, bits, points[opposite], previous_cut, points[previous], majority, majority, majority, materials, positions, normals, vertex_colors, vertex_materials, indices)
	return true


func _append_material_triangle(cell: Vector3i, bits: int, points: PackedVector3Array, labels: PackedInt32Array, sites: PackedVector3Array, materials: PackedFloat32Array, positions: PackedVector3Array, normals: PackedVector3Array, vertex_colors: PackedColorArray, vertex_materials: PackedInt32Array, indices: PackedInt32Array, reference := Vector3.ZERO) -> void:
	if reference.length_squared() == 0.0:
		reference = _inside_gradient(bits, (points[0] + points[1] + points[2]) / 3.0 - Vector3(cell))
	var unique := -1
	for index in 3:
		if labels[index] != labels[(index + 1) % 3] and labels[index] != labels[(index + 2) % 3]:
			unique = index
			break
	if unique < 0:
		_append_oriented_triangle(cell, bits, points[0], points[1], points[2], labels[0], labels[0], labels[0], materials, positions, normals, vertex_colors, vertex_materials, indices, reference)
		return
	var first := (unique + 1) % 3
	var last := (unique + 2) % 3
	var first_cut := _material_cut(points[unique], sites[unique], points[first], sites[first])
	var last_cut := _material_cut(points[last], sites[last], points[unique], sites[unique])
	if labels[first] == labels[last]:
		_append_oriented_triangle(cell, bits, points[unique], first_cut, last_cut, labels[unique], labels[unique], labels[unique], materials, positions, normals, vertex_colors, vertex_materials, indices, reference)
		if first_cut.distance_squared_to(points[last]) <= points[first].distance_squared_to(last_cut):
			_append_oriented_triangle(cell, bits, first_cut, points[first], points[last], labels[first], labels[first], labels[first], materials, positions, normals, vertex_colors, vertex_materials, indices, reference)
			_append_oriented_triangle(cell, bits, first_cut, points[last], last_cut, labels[first], labels[first], labels[first], materials, positions, normals, vertex_colors, vertex_materials, indices, reference)
		else:
			_append_oriented_triangle(cell, bits, first_cut, points[first], last_cut, labels[first], labels[first], labels[first], materials, positions, normals, vertex_colors, vertex_materials, indices, reference)
			_append_oriented_triangle(cell, bits, points[first], points[last], last_cut, labels[first], labels[first], labels[first], materials, positions, normals, vertex_colors, vertex_materials, indices, reference)
		return
	var middle_cut := _material_cut(points[first], sites[first], points[last], sites[last])
	var centre := _triple_point(points, sites, (first_cut + middle_cut + last_cut) / 3.0)
	_append_oriented_triangle(cell, bits, points[unique], first_cut, centre, labels[unique], labels[unique], labels[unique], materials, positions, normals, vertex_colors, vertex_materials, indices, reference)
	_append_oriented_triangle(cell, bits, points[unique], centre, last_cut, labels[unique], labels[unique], labels[unique], materials, positions, normals, vertex_colors, vertex_materials, indices, reference)
	_append_oriented_triangle(cell, bits, points[first], middle_cut, centre, labels[first], labels[first], labels[first], materials, positions, normals, vertex_colors, vertex_materials, indices, reference)
	_append_oriented_triangle(cell, bits, points[first], centre, first_cut, labels[first], labels[first], labels[first], materials, positions, normals, vertex_colors, vertex_materials, indices, reference)
	_append_oriented_triangle(cell, bits, points[last], last_cut, centre, labels[last], labels[last], labels[last], materials, positions, normals, vertex_colors, vertex_materials, indices, reference)
	_append_oriented_triangle(cell, bits, points[last], centre, middle_cut, labels[last], labels[last], labels[last], materials, positions, normals, vertex_colors, vertex_materials, indices, reference)


static func _triple_point(points: PackedVector3Array, sites: PackedVector3Array, fallback: Vector3) -> Vector3:
	var first_axis := sites[1] - sites[0]
	var second_axis := sites[2] - sites[0]
	var normal := (points[1] - points[0]).cross(points[2] - points[0])
	var cross := first_axis.cross(second_axis)
	var determinant := normal.dot(cross)
	if absf(determinant) < 0.000001:
		return fallback
	var first_value := (sites[1].length_squared() - sites[0].length_squared()) * 0.5
	var second_value := (sites[2].length_squared() - sites[0].length_squared()) * 0.5
	var plane := normal.dot(points[0])
	var point := (second_axis.cross(normal) * first_value + normal.cross(first_axis) * second_value + cross * plane) / determinant
	var squared := normal.length_squared()
	var second_weight := (points[1] - points[0]).cross(point - points[0]).dot(normal) / squared
	var third_weight := -(points[2] - points[0]).cross(point - points[0]).dot(normal) / squared
	second_weight = clampf(second_weight, 0.0, 1.0)
	third_weight = clampf(third_weight, 0.0, 1.0)
	if second_weight + third_weight > 1.0:
		var scale := 1.0 / (second_weight + third_weight)
		second_weight *= scale
		third_weight *= scale
	return points[0] + (points[1] - points[0]) * second_weight + (points[2] - points[0]) * third_weight


static func _material_cut(first: Vector3, first_site: Vector3, second: Vector3, second_site: Vector3) -> Vector3:
	if first_site.x > 999998.0 or second_site.x > 999998.0:
		return first.lerp(second, 0.5)
	var middle := (first_site + second_site) * 0.5
	var normal := second_site - first_site
	var first_side := (first - middle).dot(normal)
	var second_side := (second - middle).dot(normal)
	var difference := first_side - second_side
	if absf(difference) > 0.0001:
		return first.lerp(second, clampf(first_side / difference, 0.05, 0.95))
	return first.lerp(second, 0.5)


func _straight_seam_keys(positions: PackedVector3Array, vertex_materials: PackedInt32Array, indices: PackedInt32Array) -> Dictionary:
	var keys: Array[Vector3i] = []
	keys.resize(positions.size())
	for index in positions.size():
		keys[index] = _position_key(positions[index])
	var edge_materials := {}
	for triangle in range(0, indices.size(), 3):
		var material := vertex_materials[indices[triangle]]
		for corner in 3:
			var first: Vector3i = keys[indices[triangle + corner]]
			var second: Vector3i = keys[indices[triangle + (corner + 1) % 3]]
			if first == second:
				continue
			var edge := _edge_key(first, second)
			var materials: Dictionary = edge_materials.get(edge, {})
			materials[material] = true
			edge_materials[edge] = materials
	var neighbors := {}
	for edge: String in edge_materials:
		if edge_materials[edge].size() < 2:
			continue
		var parts := edge.split("|")
		var first := _key_from_string(parts[0])
		var second := _key_from_string(parts[1])
		var first_list: Array = neighbors.get(first, [])
		first_list.append(second)
		neighbors[first] = first_list
		var second_list: Array = neighbors.get(second, [])
		second_list.append(first)
		neighbors[second] = second_list
	var straight := {}
	for key: Vector3i in neighbors:
		var around: Array = neighbors[key]
		if around.size() != 2:
			continue
		var first := (_key_point(around[0]) - _key_point(key)).normalized()
		var second := (_key_point(around[1]) - _key_point(key)).normalized()
		if first.dot(second) < -0.999:
			straight[key] = true
	return straight


func _pinch_material_seams(positions: PackedVector3Array, vertex_materials: PackedInt32Array, occupancy: PackedByteArray, material_ids: PackedInt32Array, indices: PackedInt32Array) -> void:
	var straight := _straight_seam_keys(positions, vertex_materials, indices)
	var seam_ids := {}
	for index in positions.size():
		var key := _position_key(positions[index])
		var ids: Dictionary = seam_ids.get(key, {})
		ids[vertex_materials[index]] = true
		seam_ids[key] = ids
	var targets := {}
	for key: Vector3i in seam_ids:
		if _pinned_seams.has(key):
			continue
		var ids: Dictionary = seam_ids[key]
		if ids.size() < 2:
			continue
		var position := Vector3(float(key.x) / 1024.0, float(key.y) / 1024.0, float(key.z) / 1024.0)
		var cell := Vector3i(floori(position.x), floori(position.y), floori(position.z))
		var cells := {}
		for x in range(-1, 2):
			for y in range(-1, 2):
				for z in range(-1, 2):
					var sample_cell := cell + Vector3i(x, y, z)
					var sample := sample_cell + Vector3i.ONE * SAMPLE_PADDING
					if sample.x < 0 or sample.y < 0 or sample.z < 0 or sample.x >= SAMPLE_SIZE or sample.y >= SAMPLE_SIZE or sample.z >= SAMPLE_SIZE:
						continue
					var index := sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)
					if occupancy[index] == 0:
						continue
					var material_id := material_ids[index]
					if not ids.has(material_id):
						continue
					var list: Array = cells.get(material_id, [])
					list.append(sample_cell)
					cells[material_id] = list
		var best := position
		var best_distance := INF
		for first_id: int in cells:
			for second_id: int in cells:
				if first_id == second_id:
					continue
				for first_cell: Vector3i in cells[first_id]:
					for second_cell: Vector3i in cells[second_id]:
						var difference := first_cell - second_cell
						if absi(difference.x) + absi(difference.y) + absi(difference.z) != 2:
							continue
						var target := _shared_edge_pull(Vector3(first_cell), Vector3(second_cell), position)
						var distance := target.distance_squared_to(position)
						if distance < best_distance:
							best_distance = distance
							best = target
		if best_distance == INF and not straight.has(key):
			for first_id: int in cells:
				for second_id: int in cells:
					if first_id == second_id:
						continue
					for first_cell: Vector3i in cells[first_id]:
						for second_cell: Vector3i in cells[second_id]:
							var difference := first_cell - second_cell
							if absi(difference.x) + absi(difference.y) + absi(difference.z) != 3:
								continue
							var between := true
							for axis in 3:
								var low := minf(float(first_cell[axis]), float(second_cell[axis]))
								var high := maxf(float(first_cell[axis]), float(second_cell[axis]))
								if position[axis] <= low + 0.0001 or position[axis] >= high - 0.0001:
									between = false
									break
							if not between:
								continue
							var target := (Vector3(first_cell) + Vector3(second_cell)) * 0.5
							var distance := target.distance_squared_to(position)
							if distance < best_distance:
								best_distance = distance
								best = target
		if best_distance < INF:
			targets[key] = best
	for index in positions.size():
		var key := _position_key(positions[index])
		if targets.has(key):
			positions[index] = targets[key]


func _collapse_near_hole_vertices(positions: PackedVector3Array, indices: PackedInt32Array) -> void:
	var keys: Array[Vector3i] = []
	keys.resize(positions.size())
	for index in positions.size():
		keys[index] = _position_key(positions[index])
	var uses := {}
	for triangle in range(0, indices.size(), 3):
		for corner in 3:
			var first: Vector3i = keys[indices[triangle + corner]]
			var second: Vector3i = keys[indices[triangle + (corner + 1) % 3]]
			if first == second:
				continue
			var edge := _edge_key(first, second)
			uses[edge] = uses.get(edge, 0) + 1
	var neighbors := {}
	for edge: String in uses:
		if uses[edge] != 1:
			continue
		var parts := edge.split("|")
		var first := _key_from_string(parts[0])
		var second := _key_from_string(parts[1])
		var first_list: Array = neighbors.get(first, [])
		first_list.append(second)
		neighbors[first] = first_list
		var second_list: Array = neighbors.get(second, [])
		second_list.append(first)
		neighbors[second] = second_list
	var slivers := {}
	for vertex: Vector3i in neighbors:
		var around: Array = neighbors[vertex]
		if around.size() != 2 or around[0] == around[1]:
			continue
		var key := _edge_key(around[0], around[1])
		var list: Array = slivers.get(key, [])
		list.append(vertex)
		slivers[key] = list
	var moves := {}
	for key: String in slivers:
		var list: Array = slivers[key]
		for first_index in list.size():
			if moves.has(list[first_index]):
				continue
			for second_index in range(first_index + 1, list.size()):
				if moves.has(list[second_index]):
					continue
				var first: Vector3i = list[first_index]
				var second: Vector3i = list[second_index]
				var gap := _key_distance(first, second)
				if gap > 0.3:
					continue
				var middle := (_key_point(first) + _key_point(second)) * 0.5
				moves[first] = middle
				moves[second] = middle
				break
	for index in positions.size():
		if moves.has(keys[index]):
			positions[index] = moves[keys[index]]


static func _key_point(key: Vector3i) -> Vector3:
	return Vector3(float(key.x) / 1024.0, float(key.y) / 1024.0, float(key.z) / 1024.0)


static func _key_distance(first: Vector3i, second: Vector3i) -> float:
	return _key_point(first).distance_to(_key_point(second))


func _drop_degenerate_triangles(positions: PackedVector3Array, indices: PackedInt32Array) -> PackedInt32Array:
	var kept := PackedInt32Array()
	for triangle in range(0, indices.size(), 3):
		var first := _position_key(positions[indices[triangle]])
		var second := _position_key(positions[indices[triangle + 1]])
		var third := _position_key(positions[indices[triangle + 2]])
		if first == second or second == third or first == third:
			continue
		kept.append(indices[triangle])
		kept.append(indices[triangle + 1])
		kept.append(indices[triangle + 2])
	return kept


func _rebuild_flat_normals(positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, materials: PackedInt32Array, indices: PackedInt32Array, occupancy: PackedByteArray) -> Array:
	var new_positions := PackedVector3Array()
	var new_normals := PackedVector3Array()
	var new_colors := PackedColorArray()
	var new_materials := PackedInt32Array()
	var new_indices := PackedInt32Array()
	for triangle in range(0, indices.size(), 3):
		var first := positions[indices[triangle]]
		var second := positions[indices[triangle + 1]]
		var third := positions[indices[triangle + 2]]
		var normal := normals[indices[triangle]]
		var winding := (second - first).cross(third - first)
		if winding.length_squared() >= 0.0000000001:
			var face := winding.normalized()
			var centre := (first + second + third) / 3.0
			var plus := Vector3i(roundi(centre.x + face.x * 0.3), roundi(centre.y + face.y * 0.3), roundi(centre.z + face.z * 0.3)) + Vector3i.ONE * SAMPLE_PADDING
			var minus := Vector3i(roundi(centre.x - face.x * 0.3), roundi(centre.y - face.y * 0.3), roundi(centre.z - face.z * 0.3)) + Vector3i.ONE * SAMPLE_PADDING
			if plus.x >= 0 and plus.y >= 0 and plus.z >= 0 and plus.x < SAMPLE_SIZE and plus.y < SAMPLE_SIZE and plus.z < SAMPLE_SIZE and minus.x >= 0 and minus.y >= 0 and minus.z >= 0 and minus.x < SAMPLE_SIZE and minus.y < SAMPLE_SIZE and minus.z < SAMPLE_SIZE:
				var plus_solid := occupancy[plus.x + SAMPLE_SIZE * (plus.y + SAMPLE_SIZE * plus.z)] != 0
				var minus_solid := occupancy[minus.x + SAMPLE_SIZE * (minus.y + SAMPLE_SIZE * minus.z)] != 0
				if plus_solid != minus_solid:
					normal = -face if plus_solid else face
		var vertex := new_positions.size()
		new_positions.append(first)
		new_positions.append(second)
		new_positions.append(third)
		new_normals.append(normal)
		new_normals.append(normal)
		new_normals.append(normal)
		var colour := colors[indices[triangle]]
		new_colors.append(colour)
		new_colors.append(colour)
		new_colors.append(colour)
		var material := materials[indices[triangle]]
		new_materials.append(material)
		new_materials.append(material)
		new_materials.append(material)
		new_indices.append(vertex)
		new_indices.append(vertex + 1)
		new_indices.append(vertex + 2)
	return _weld(new_positions, new_normals, new_colors, new_materials, new_indices)


func _drop_opposite_duplicate_triangles(positions: PackedVector3Array, indices: PackedInt32Array) -> PackedInt32Array:
	var groups := {}
	for triangle in range(0, indices.size(), 3):
		var parts := PackedStringArray()
		for corner in 3:
			var key := _position_key(positions[indices[triangle + corner]])
			parts.append("%d,%d,%d" % [key.x, key.y, key.z])
		parts.sort()
		var key := "|".join(parts)
		var list: Array = groups.get(key, [])
		list.append(triangle)
		groups[key] = list
	var removed := {}
	for key: String in groups:
		var list: Array = groups[key]
		if list.size() < 2:
			continue
		var first: int = list[0]
		var first_normal := _triangle_normal(positions, indices, first)
		for index in range(1, list.size()):
			var other: int = list[index]
			if first_normal.dot(_triangle_normal(positions, indices, other)) < 0.0:
				removed[first] = true
				removed[other] = true
			else:
				removed[other] = true
	var kept := PackedInt32Array()
	for triangle in range(0, indices.size(), 3):
		if removed.has(triangle):
			continue
		kept.append(indices[triangle])
		kept.append(indices[triangle + 1])
		kept.append(indices[triangle + 2])
	return kept


func _fill_boundary_ears(positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, materials_vertex: PackedInt32Array, occupancy: PackedByteArray, cell_material_ids: PackedInt32Array, palette: PackedFloat32Array) -> Array:
	var point_of := {}
	var keys: Array[Vector3i] = []
	keys.resize(positions.size())
	for index in positions.size():
		var key := _position_key(positions[index])
		keys[index] = key
		if not point_of.has(key):
			point_of[key] = positions[index]
	var edge_data := {}
	for triangle in range(0, indices.size(), 3):
		var material := materials_vertex[indices[triangle]]
		for corner in 3:
			var first := keys[indices[triangle + corner]]
			var second := keys[indices[triangle + (corner + 1) % 3]]
			var edge := _edge_key(first, second)
			var entry: Array = edge_data.get(edge, [0, material])
			entry[0] += 1
			edge_data[edge] = entry
	var neighbors := {}
	var edge_material := {}
	for edge: String in edge_data:
		if edge_data[edge][0] != 1:
			continue
		edge_material[edge] = edge_data[edge][1]
		var parts := edge.split("|")
		var first := _key_from_string(parts[0])
		var second := _key_from_string(parts[1])
		var first_list: Array = neighbors.get(first, [])
		first_list.append(second)
		neighbors[first] = first_list
		var second_list: Array = neighbors.get(second, [])
		second_list.append(first)
		neighbors[second] = second_list
	var new_positions := positions.duplicate()
	var new_normals := normals.duplicate()
	var new_colors := colors.duplicate()
	var new_materials := materials_vertex.duplicate()
	var new_indices := indices.duplicate()
	var handled := {}
	var filled := false
	for corner: Vector3i in neighbors:
		var around: Array = neighbors[corner]
		if around.size() != 2:
			continue
		var first_point: Vector3 = point_of[around[0]]
		var second_point: Vector3 = point_of[around[1]]
		var tip: Vector3 = point_of[corner]
		var constant_axis := -1
		for candidate in 3:
			if absf(first_point[candidate] - second_point[candidate]) < 0.001 and absf(first_point[candidate] - tip[candidate]) < 0.001:
				constant_axis = candidate
				break
		if constant_axis < 0:
			continue
		var first_axis := (constant_axis + 1) % 3
		var second_axis := (constant_axis + 2) % 3
		var chord_axis := -1
		var shared_axis := -1
		if absf(first_point[first_axis] - second_point[first_axis]) < 0.001:
			chord_axis = second_axis
			shared_axis = first_axis
		elif absf(first_point[second_axis] - second_point[second_axis]) < 0.001:
			chord_axis = first_axis
			shared_axis = second_axis
		if chord_axis < 0:
			continue
		if absf(tip[shared_axis] - first_point[shared_axis]) < 0.5:
			continue
		var low := minf(first_point[chord_axis], second_point[chord_axis])
		var high := maxf(first_point[chord_axis], second_point[chord_axis])
		if tip[chord_axis] <= low + 0.001 or tip[chord_axis] >= high - 0.001:
			continue
		var first_edge := _edge_key(around[0], corner)
		var second_edge := _edge_key(corner, around[1])
		if not edge_material.has(first_edge) or not edge_material.has(second_edge):
			continue
		if edge_material[first_edge] == edge_material[second_edge]:
			continue
		var middle := (first_point + second_point) * 0.5
		if not _is_half_grid(first_point) or not _is_half_grid(second_point) or not _is_half_grid(tip):
			continue
		if absf(first_point.distance_to(second_point) - 1.0) > 0.01:
			continue
		if not _is_half_grid(middle):
			continue
		var middle_key := _position_key(middle)
		if handled.has(middle_key) or point_of.has(middle_key):
			continue
		var centre := (first_point + second_point + tip) / 3.0
		var direction := Vector3.ZERO
		direction[constant_axis] = 1.0
		var plus := Vector3i(roundi(centre.x + direction.x * 0.3), roundi(centre.y + direction.y * 0.3), roundi(centre.z + direction.z * 0.3)) + Vector3i.ONE * SAMPLE_PADDING
		var minus := Vector3i(roundi(centre.x - direction.x * 0.3), roundi(centre.y - direction.y * 0.3), roundi(centre.z - direction.z * 0.3)) + Vector3i.ONE * SAMPLE_PADDING
		if plus.x < 0 or plus.y < 0 or plus.z < 0 or plus.x >= SAMPLE_SIZE or plus.y >= SAMPLE_SIZE or plus.z >= SAMPLE_SIZE:
			continue
		if minus.x < 0 or minus.y < 0 or minus.z < 0 or minus.x >= SAMPLE_SIZE or minus.y >= SAMPLE_SIZE or minus.z >= SAMPLE_SIZE:
			continue
		var plus_solid := occupancy[plus.x + SAMPLE_SIZE * (plus.y + SAMPLE_SIZE * plus.z)] != 0
		var minus_solid := occupancy[minus.x + SAMPLE_SIZE * (minus.y + SAMPLE_SIZE * minus.z)] != 0
		if plus_solid == minus_solid:
			continue
		var outward := direction if not plus_solid and minus_solid else -direction
		for triangle: Array in [[first_point, tip, middle], [middle, tip, second_point]]:
			var first := triangle[0] as Vector3
			var second := triangle[1] as Vector3
			var third := triangle[2] as Vector3
			var triangle_centre := (first + second + third) / 3.0
			var solid_point := triangle_centre - outward * 0.3
			var cell := Vector3i(roundi(solid_point.x), roundi(solid_point.y), roundi(solid_point.z)) + Vector3i.ONE * SAMPLE_PADDING
			if cell.x < 0 or cell.y < 0 or cell.z < 0 or cell.x >= SAMPLE_SIZE or cell.y >= SAMPLE_SIZE or cell.z >= SAMPLE_SIZE:
				continue
			var cell_index := cell.x + SAMPLE_SIZE * (cell.y + SAMPLE_SIZE * cell.z)
			if occupancy[cell_index] == 0:
				continue
			var material_id := cell_material_ids[cell_index]
			var base := material_id * VoxelFrame.MATERIAL_STRIDE
			if base + 3 >= palette.size():
				continue
			var colour := Color(palette[base], palette[base + 1], palette[base + 2], palette[base + 3])
			if (second - first).cross(third - first).dot(outward) > 0.0:
				var swap := second
				second = third
				third = swap
			var vertex := new_positions.size()
			new_positions.append(first)
			new_positions.append(second)
			new_positions.append(third)
			new_normals.append(outward)
			new_normals.append(outward)
			new_normals.append(outward)
			new_colors.append(colour)
			new_colors.append(colour)
			new_colors.append(colour)
			new_materials.append(material_id)
			new_materials.append(material_id)
			new_materials.append(material_id)
			new_indices.append(vertex)
			new_indices.append(vertex + 1)
			new_indices.append(vertex + 2)
			filled = true
		handled[middle_key] = true
	if not filled:
		return [positions, normals, colors, indices, materials_vertex]
	return _weld(new_positions, new_normals, new_colors, new_materials, new_indices)


static func _is_half_grid(point: Vector3) -> bool:
	return absf(point.x * 2.0 - roundf(point.x * 2.0)) < 0.001 and absf(point.y * 2.0 - roundf(point.y * 2.0)) < 0.001 and absf(point.z * 2.0 - roundf(point.z * 2.0)) < 0.001


static func _edge_key(first: Vector3i, second: Vector3i) -> String:
	var low := first
	var high := second
	if low.x > high.x or (low.x == high.x and (low.y > high.y or (low.y == high.y and low.z > high.z))):
		low = second
		high = first
	return "%d,%d,%d|%d,%d,%d" % [low.x, low.y, low.z, high.x, high.y, high.z]


static func _key_from_string(text: String) -> Vector3i:
	var parts := text.split(",")
	return Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))


func _flip_diagonals(positions: PackedVector3Array, indices: PackedInt32Array, materials: PackedInt32Array) -> void:
	var position_materials := {}
	for triangle in range(0, indices.size(), 3):
		var material := materials[indices[triangle]]
		for corner in 3:
			var key := _position_key(positions[indices[triangle + corner]])
			var ids: Dictionary = position_materials.get(key, {})
			ids[material] = true
			position_materials[key] = ids
	var seam_count := PackedInt32Array()
	seam_count.resize(positions.size())
	for index in positions.size():
		seam_count[index] = position_materials[_position_key(positions[index])].size()
	var edges := {}
	for triangle in range(0, indices.size(), 3):
		for corner in 3:
			var first := indices[triangle + corner]
			var second := indices[triangle + (corner + 1) % 3]
			var key := Vector2i(mini(first, second), maxi(first, second))
			var list: Array = edges.get(key, [])
			list.append(triangle)
			edges[key] = list
	var used := {}
	for key: Vector2i in edges:
		var triangles: Array = edges[key]
		if triangles.size() != 2:
			continue
		var first_triangle: int = triangles[0]
		var second_triangle: int = triangles[1]
		if used.has(first_triangle) or used.has(second_triangle):
			continue
		var first := key.x
		var second := key.y
		var first_opposite := _opposite_vertex(indices, first_triangle, first, second)
		var second_opposite := _opposite_vertex(indices, second_triangle, first, second)
		if first_opposite < 0 or second_opposite < 0 or first_opposite == second_opposite:
			continue
		var material := materials[first]
		if materials[second] != material or materials[first_opposite] != material or materials[second_opposite] != material:
			continue
		var old_squared := positions[first].distance_squared_to(positions[second])
		var new_squared := positions[first_opposite].distance_squared_to(positions[second_opposite])
		if new_squared >= old_squared - 0.0001:
			if absf(new_squared - old_squared) > 0.0001:
				continue
			var current_spread := absi(seam_count[first] - seam_count[second])
			var alternative_spread := absi(seam_count[first_opposite] - seam_count[second_opposite])
			if alternative_spread >= current_spread:
				continue
			var new_key := Vector2i(mini(first_opposite, second_opposite), maxi(first_opposite, second_opposite))
			if edges.has(new_key):
				continue
		var old_normal := _triangle_normal(positions, indices, first_triangle) + _triangle_normal(positions, indices, second_triangle)
		if old_normal.length_squared() < 0.00000001:
			continue
		var first_cross := (positions[second_opposite] - positions[first]).cross(positions[first_opposite] - positions[first])
		var second_cross := (positions[first_opposite] - positions[second]).cross(positions[second_opposite] - positions[second])
		if first_cross.length_squared() < 0.0000000001 or second_cross.length_squared() < 0.0000000001:
			continue
		if first_cross.dot(old_normal) < 0.0:
			_write_triangle(indices, first_triangle, first, first_opposite, second_opposite)
			_write_triangle(indices, second_triangle, second, second_opposite, first_opposite)
		else:
			_write_triangle(indices, first_triangle, first, second_opposite, first_opposite)
			_write_triangle(indices, second_triangle, second, first_opposite, second_opposite)
		used[first_triangle] = true
		used[second_triangle] = true


static func _opposite_vertex(indices: PackedInt32Array, triangle: int, first: int, second: int) -> int:
	for corner in 3:
		var vertex := indices[triangle + corner]
		if vertex != first and vertex != second:
			return vertex
	return -1


static func _triangle_normal(positions: PackedVector3Array, indices: PackedInt32Array, triangle: int) -> Vector3:
	return (positions[indices[triangle + 1]] - positions[indices[triangle]]).cross(positions[indices[triangle + 2]] - positions[indices[triangle]])


static func _write_triangle(indices: PackedInt32Array, triangle: int, first: int, second: int, third: int) -> void:
	indices[triangle] = first
	indices[triangle + 1] = second
	indices[triangle + 2] = third


static func _position_key(point: Vector3) -> Vector3i:
	return Vector3i(roundi(point.x * 1024.0), roundi(point.y * 1024.0), roundi(point.z * 1024.0))


static func _shared_edge_pull(first_site: Vector3, second_site: Vector3, point: Vector3) -> Vector3:
	var difference := second_site - first_site
	var changed := 0
	var free_axis := -1
	for axis in 3:
		var step := absf(difference[axis])
		if step > 0.5:
			if step > 1.5:
				return point
			changed += 1
		else:
			free_axis = axis
	if changed != 2 or free_axis < 0:
		return point
	if point[free_axis] < first_site[free_axis] - 0.0001 or point[free_axis] > first_site[free_axis] + 1.0001:
		return point
	var target := point
	for axis in 3:
		if absf(difference[axis]) > 0.5:
			var midpoint := (first_site[axis] + second_site[axis]) * 0.5
			if absf(point[axis] - midpoint) > 0.5:
				return point
			target[axis] = midpoint
	target[free_axis] = clampf(point[free_axis], first_site[free_axis] - 0.5, first_site[free_axis] + 0.5)
	return target


func _edge_sample(cell: Vector3i, edge: int, occupancy: PackedByteArray, material_ids: PackedInt32Array) -> Array:
	if edge >= EDGE_CORNERS.size():
		var point := _edge_point(cell, edge)
		var closest := INF
		var label := -1
		for corner in 8:
			var sample := cell + CORNER_OFFSETS[corner] + Vector3i.ONE * SAMPLE_PADDING
			var sample_index := sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)
			if occupancy[sample_index] == 0:
				continue
			var distance := (point - (Vector3(cell) + Vector3(CORNER_OFFSETS[corner]))).length_squared()
			if distance < closest - 0.000001 or (distance <= closest + 0.000001 and (label < 0 or material_ids[sample_index] < label)):
				closest = distance
				label = material_ids[sample_index]
		var site := Vector3.ZERO
		var tied := 0
		for corner in 8:
			var sample := cell + CORNER_OFFSETS[corner] + Vector3i.ONE * SAMPLE_PADDING
			var sample_index := sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)
			if occupancy[sample_index] == 0 or material_ids[sample_index] != label:
				continue
			var distance := (point - (Vector3(cell) + Vector3(CORNER_OFFSETS[corner]))).length_squared()
			if distance <= closest + 0.000001:
				site += Vector3(cell) + Vector3(CORNER_OFFSETS[corner])
				tied += 1
		if tied > 0:
			site /= float(tied)
		return [site, label]
	var corners: Array = EDGE_CORNERS[edge]
	for corner: int in corners:
		var sample := cell + CORNER_OFFSETS[corner] + Vector3i.ONE * SAMPLE_PADDING
		var sample_index := sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)
		if occupancy[sample_index] != 0:
			return [Vector3(cell + CORNER_OFFSETS[corner]), material_ids[sample_index]]
	return [Vector3(cell), 0]


func _material_diagonal(cell: Vector3i, loop: PackedInt32Array, occupancy: PackedByteArray, material_ids: PackedInt32Array) -> PackedInt32Array:
	if loop.size() != 4:
		return PackedInt32Array()
	var quad: Array[Vector3i] = []
	var labels := PackedInt32Array()
	for edge: int in loop:
		if edge >= EDGE_CORNERS.size():
			return PackedInt32Array()
		var sample := _edge_sample(cell, edge, occupancy, material_ids)
		var site: Vector3 = sample[0]
		quad.append(Vector3i(roundi(site.x), roundi(site.y), roundi(site.z)))
		labels.append(sample[1])
	if labels[0] != labels[2] or labels[1] != labels[3] or labels[0] == labels[1]:
		return PackedInt32Array()
	var constant_axis := -1
	for axis in 3:
		if quad[0][axis] == quad[1][axis] and quad[0][axis] == quad[2][axis] and quad[0][axis] == quad[3][axis]:
			constant_axis = axis
			break
	if constant_axis < 0:
		return PackedInt32Array()
	var first_axis := (constant_axis + 1) % 3
	var second_axis := (constant_axis + 2) % 3
	var first_low := mini(mini(quad[0][first_axis], quad[1][first_axis]), mini(quad[2][first_axis], quad[3][first_axis]))
	var second_low := mini(mini(quad[0][second_axis], quad[1][second_axis]), mini(quad[2][second_axis], quad[3][second_axis]))
	var first_high := maxi(maxi(quad[0][first_axis], quad[1][first_axis]), maxi(quad[2][first_axis], quad[3][first_axis]))
	var second_high := maxi(maxi(quad[0][second_axis], quad[1][second_axis]), maxi(quad[2][second_axis], quad[3][second_axis]))
	if first_high - first_low != 1 or second_high - second_low != 1:
		return PackedInt32Array()
	var components := _quad_components(quad, constant_axis, first_axis, second_axis, first_low - 1, second_low - 1, occupancy, material_ids)
	if components.is_empty():
		return PackedInt32Array()
	var component_sizes := {}
	for component_cell: Vector3i in components:
		var component: int = components[component_cell]
		component_sizes[component] = component_sizes.get(component, 0) + 1
	var first_component: int = components.get(quad[0], -1)
	var second_component: int = components.get(quad[1], -1)
	var third_component: int = components.get(quad[2], -1)
	var fourth_component: int = components.get(quad[3], -1)
	if first_component != third_component and second_component == fourth_component:
		return PackedInt32Array([loop[0], loop[1], loop[2], loop[0], loop[2], loop[3]])
	if second_component != fourth_component and first_component == third_component:
		return PackedInt32Array([loop[1], loop[2], loop[3], loop[1], loop[3], loop[0]])
	if first_component != third_component and second_component != fourth_component:
		var first_size: int = component_sizes.get(first_component, 0) + component_sizes.get(third_component, 0)
		var second_size: int = component_sizes.get(second_component, 0) + component_sizes.get(fourth_component, 0)
		if first_size < second_size:
			return PackedInt32Array([loop[0], loop[1], loop[2], loop[0], loop[2], loop[3]])
		if second_size < first_size:
			return PackedInt32Array([loop[1], loop[2], loop[3], loop[1], loop[3], loop[0]])
	return PackedInt32Array()


func _quad_components(quad: Array[Vector3i], constant_axis: int, first_axis: int, second_axis: int, first_low: int, second_low: int, occupancy: PackedByteArray, material_ids: PackedInt32Array) -> Dictionary:
	for second in 4:
		for first in 4:
			var cell := Vector3i.ZERO
			cell[constant_axis] = quad[0][constant_axis]
			cell[first_axis] = first_low + first
			cell[second_axis] = second_low + second
			var sample := cell + Vector3i.ONE * SAMPLE_PADDING
			if sample.x < 0 or sample.y < 0 or sample.z < 0 or sample.x >= SAMPLE_SIZE or sample.y >= SAMPLE_SIZE or sample.z >= SAMPLE_SIZE:
				return {}
	var filled := {}
	var component := 0
	for second in 4:
		for first in 4:
			var cell := Vector3i.ZERO
			cell[constant_axis] = quad[0][constant_axis]
			cell[first_axis] = first_low + first
			cell[second_axis] = second_low + second
			var sample := cell + Vector3i.ONE * SAMPLE_PADDING
			var index := sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)
			if occupancy[index] == 0 or filled.has(cell):
				continue
			var material := material_ids[index]
			var stack: Array[Vector3i] = [cell]
			filled[cell] = component
			while not stack.is_empty():
				var current: Vector3i = stack.pop_back()
				for axis: int in [first_axis, second_axis]:
					for direction in [-1, 1]:
						var neighbor := current
						neighbor[axis] += direction
						if neighbor[first_axis] < first_low or neighbor[first_axis] > first_low + 3:
							continue
						if neighbor[second_axis] < second_low or neighbor[second_axis] > second_low + 3:
							continue
						if filled.has(neighbor):
							continue
						var neighbor_sample := neighbor + Vector3i.ONE * SAMPLE_PADDING
						var neighbor_index := neighbor_sample.x + SAMPLE_SIZE * (neighbor_sample.y + SAMPLE_SIZE * neighbor_sample.z)
						if occupancy[neighbor_index] == 0 or material_ids[neighbor_index] != material:
							continue
						filled[neighbor] = component
						stack.append(neighbor)
			component += 1
	return filled


static func _opposite_pair(bits: int) -> bool:
	var solid: Array[int] = []
	for corner in 8:
		if bits & (1 << corner):
			solid.append(corner)
	if solid.size() != 2:
		return false
	return CORNER_OFFSETS[solid[0]] + CORNER_OFFSETS[solid[1]] == Vector3i.ONE


func _append_antiprism(cell: Vector3i, bits: int, case_data: Dictionary, field: PackedFloat32Array, occupancy: PackedByteArray, material_ids: PackedInt32Array, materials: PackedFloat32Array, positions: PackedVector3Array, normals: PackedVector3Array, vertex_colors: PackedColorArray, vertex_materials: PackedInt32Array, indices: PackedInt32Array) -> bool:
	var groups: Array = case_data["triangles"]
	if groups.size() != 2:
		return false
	var caps: Array = []
	var edges := PackedInt32Array()
	var points: Array[Vector3] = []
	for group: PackedInt32Array in groups:
		if group.size() != 3:
			return false
		var cap := PackedInt32Array([group[0], group[1], group[2]])
		cap.sort()
		caps.append(cap)
		for edge in group:
			edges.append(edge)
			points.append(_field_point(cell, edge, field))
	if edges.size() != 6:
		return false
	var centre := Vector3(cell) + Vector3(0.5, 0.5, 0.5)
	var sides: Array = []
	for first in 6:
		for second in range(first + 1, 6):
			for third in range(second + 1, 6):
				var a := points[first]
				var b := points[second]
				var c := points[third]
				var normal := (b - a).cross(c - a)
				if normal.length_squared() < 0.0000000001:
					continue
				var above := 0
				var below := 0
				for other in 6:
					if other == first or other == second or other == third:
						continue
					var side := normal.dot(points[other] - a)
					if side > 0.0001:
						above += 1
					elif side < -0.0001:
						below += 1
				if above > 0 and below > 0:
					continue
				var triple := PackedInt32Array([edges[first], edges[second], edges[third]])
				triple.sort()
				if triple == caps[0] or triple == caps[1]:
					continue
				sides.append([first, second, third])
	if sides.size() != 6:
		return false
	for side: Array in sides:
		var first: int = side[0]
		var second: int = side[1]
		var third: int = side[2]
		var face_centre := (points[first] + points[second] + points[third]) / 3.0
		var inside := centre - face_centre
		var order := [first, second, third]
		if (points[second] - points[first]).cross(points[third] - points[first]).dot(inside) > 0.0:
			order = [first, third, second]
		var labels := PackedInt32Array()
		var sites := PackedVector3Array()
		var triangle := PackedVector3Array()
		for index: int in order:
			var sample := _edge_sample(cell, edges[index], occupancy, material_ids)
			labels.append(sample[1])
			sites.append(sample[0])
			triangle.append(points[index])
		_append_material_triangle(cell, bits, triangle, labels, sites, materials, positions, normals, vertex_colors, vertex_materials, indices, inside)
	return true


static func _weld(positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, materials: PackedInt32Array, indices: PackedInt32Array) -> Array:
	var welded_positions := PackedVector3Array()
	var welded_normals := PackedVector3Array()
	var welded_colors := PackedColorArray()
	var welded_materials := PackedInt32Array()
	var welded_indices := PackedInt32Array()
	welded_indices.resize(indices.size())
	var by_position := {}
	for index in indices.size():
		var source := indices[index]
		var position := positions[source]
		var normal := normals[source]
		var position_key := Vector3i(roundi(position.x * 1024.0), roundi(position.y * 1024.0), roundi(position.z * 1024.0))
		var normal_key := Vector3i(roundi(normal.x * 1024.0), roundi(normal.y * 1024.0), roundi(normal.z * 1024.0))
		var material_id := materials[source]
		var by_normal: Dictionary = by_position.get(position_key, {})
		var by_material: Dictionary = by_normal.get(normal_key, {})
		var vertex: int = by_material.get(material_id, -1)
		if vertex < 0:
			vertex = welded_positions.size()
			welded_positions.append(position)
			welded_normals.append(normal)
			welded_colors.append(colors[source])
			welded_materials.append(material_id)
			by_material[material_id] = vertex
			by_normal[normal_key] = by_material
			by_position[position_key] = by_normal
		welded_indices[index] = vertex
	return [welded_positions, welded_normals, welded_colors, welded_indices, welded_materials]


func _mirror_on_face(cell: Vector3i, first_edge: int, second_edge: int, third_edge: int, occupancy: PackedByteArray) -> bool:
	var common := _edge_faces[first_edge] & _edge_faces[second_edge] & _edge_faces[third_edge]
	var face := -1
	for candidate in FACES.size():
		if common == 1 << candidate:
			face = candidate
			break
	if face < 0:
		return false
	var axis: int = FACE_AXES[face / 2]
	var neighbor := cell
	var neighbor_face := face + 1
	if face % 2 == 0:
		neighbor[axis] -= 1
	else:
		neighbor[axis] += 1
		neighbor_face = face - 1
	var neighbor_bits := 0
	for corner in 8:
		var sample := neighbor + CORNER_OFFSETS[corner] + Vector3i.ONE * SAMPLE_PADDING
		var index := sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)
		if occupancy[index] != 0:
			neighbor_bits |= 1 << corner
	var neighbor_mask := _diagonal_faces(neighbor_bits)
	var face_triangles: Array = _case_data(neighbor_bits, neighbor_mask)["face_triangles"]
	var candidates: Array = face_triangles[neighbor_face]
	for mirrored: PackedInt32Array in candidates:
		if _same_face_triangle(cell, [first_edge, second_edge, third_edge], neighbor, mirrored):
			return true
	return false


static func _diagonal_faces(bits: int) -> int:
	var mask := 0
	for face_index in FACES.size():
		var face_corners: Array = FACES[face_index][0]
		var solid_corners: Array[int] = []
		for index in 4:
			if bits & (1 << face_corners[index]):
				solid_corners.append(index)
		if solid_corners.size() != 2:
			continue
		if _face_corners_adjacent(solid_corners[0], solid_corners[1]):
			continue
		mask |= 1 << face_index
	return mask


static func _same_face_triangle(first_cell: Vector3i, first_edges: Array, second_cell: Vector3i, second_edges: PackedInt32Array) -> bool:
	if first_edges.size() != second_edges.size():
		return false
	var first: Array[Vector3i] = []
	var second: Array[Vector3i] = []
	for edge: int in first_edges:
		first.append(_vertex_key(first_cell, edge))
	for edge: int in second_edges:
		second.append(_vertex_key(second_cell, edge))
	first.sort()
	second.sort()
	return first == second


static func _vertex_key(cell: Vector3i, edge: int) -> Vector3i:
	if edge < EDGE_CORNERS.size():
		var corners: Array = EDGE_CORNERS[edge]
		return cell * 4 + (CORNER_OFFSETS[corners[0]] + CORNER_OFFSETS[corners[1]]) * 2
	var face := (edge - EDGE_CORNERS.size()) / 2
	var offsets := Vector3i.ZERO
	for corner: int in FACES[face][0]:
		offsets += CORNER_OFFSETS[corner]
	return cell * 4 + offsets


static func _build_owners(present: PackedByteArray) -> PackedByteArray:
	var owners := PackedByteArray()
	owners.resize(27)
	for state_x in 3:
		for state_y in 3:
			for state_z in 3:
				var winner := Vector3i.ZERO
				var found := false
				for offset_x in _axis_offsets(state_x):
					for offset_y in _axis_offsets(state_y):
						for offset_z in _axis_offsets(state_z):
							if found:
								continue
							var index := (offset_x + 1) + 3 * ((offset_y + 1) + 3 * (offset_z + 1))
							if present[index] != 0:
								winner = Vector3i(offset_x, offset_y, offset_z)
								found = true
				owners[(state_x * 3 + state_y) * 3 + state_z] = 1 if winner == Vector3i.ZERO else 2
	return owners


static func _axis_offsets(state: int) -> PackedInt32Array:
	if state == 0:
		return PackedInt32Array([-1, 0])
	if state == 2:
		return PackedInt32Array([0, 1])
	return PackedInt32Array([0])


func _append_oriented_triangle(cell: Vector3i, bits: int, first: Vector3, second: Vector3, third: Vector3, first_material: int, second_material: int, third_material: int, materials: PackedFloat32Array, positions: PackedVector3Array, normals: PackedVector3Array, vertex_colors: PackedColorArray, vertex_materials: PackedInt32Array, indices: PackedInt32Array, reference := Vector3.ZERO) -> void:
	var winding := (second - first).cross(third - first)
	if winding.length_squared() < 0.0000000001:
		return
	var inside := reference if reference.length_squared() > 0.0 else _inside_gradient(bits, (first + second + third) / 3.0 - Vector3(cell))
	if winding.dot(inside) < 0.0:
		var swap := second
		second = third
		third = swap
		var swap_material := second_material
		second_material = third_material
		third_material = swap_material
		winding = -winding
	var shading := -winding.normalized()
	var first_vertex := positions.size()
	positions.append(first)
	positions.append(second)
	positions.append(third)
	for material_id: int in [first_material, second_material, third_material]:
		var base := material_id * VoxelFrame.MATERIAL_STRIDE
		normals.append(shading)
		vertex_colors.append(Color(materials[base], materials[base + 1], materials[base + 2], materials[base + 3]))
		vertex_materials.append(material_id)
	indices.append(first_vertex)
	indices.append(first_vertex + 1)
	indices.append(first_vertex + 2)


static func _edge_point(cell: Vector3i, edge: int) -> Vector3:
	if edge >= EDGE_CORNERS.size():
		var face := (edge - EDGE_CORNERS.size()) / 2
		var offsets := Vector3i.ZERO
		for corner: int in FACES[face][0]:
			offsets += CORNER_OFFSETS[corner]
		return Vector3(cell) + Vector3(offsets) * 0.25
	var corners: Array = EDGE_CORNERS[edge]
	var first: Vector3i = CORNER_OFFSETS[corners[0]]
	var second: Vector3i = CORNER_OFFSETS[corners[1]]
	return Vector3(cell) + (Vector3(first) + Vector3(second)) * 0.5


static func _inside_gradient(bits: int, point: Vector3) -> Vector3:
	var gradient := Vector3.ZERO
	for corner in 8:
		if bits & (1 << corner) == 0:
			continue
		var offset: Vector3i = CORNER_OFFSETS[corner]
		var along_x := 1.0 if offset.x == 1 else -1.0
		var along_y := 1.0 if offset.y == 1 else -1.0
		var along_z := 1.0 if offset.z == 1 else -1.0
		var weight_x := point.x if offset.x == 1 else 1.0 - point.x
		var weight_y := point.y if offset.y == 1 else 1.0 - point.y
		var weight_z := point.z if offset.z == 1 else 1.0 - point.z
		gradient.x += along_x * weight_y * weight_z
		gradient.y += along_y * weight_x * weight_z
		gradient.z += along_z * weight_x * weight_y
	return gradient


static func _case_loops_for(bits: int, mask: int) -> Array[PackedInt32Array]:
	var segments: Array[Vector2i] = []
	for face_index in FACES.size():
		var face: Array = FACES[face_index]
		var corners: Array = face[0]
		var edges: Array = face[1]
		var face_bits := 0
		for index in 4:
			if bits & (1 << corners[index]):
				face_bits |= 1 << index
		if face_bits == 0 or face_bits == 15:
			continue
		var inside: Array[int] = []
		for index in 4:
			if face_bits & (1 << index):
				inside.append(index)
		if inside.size() == 1:
			var corner: int = inside[0]
			segments.append(Vector2i(edges[(corner + 3) % 4], edges[corner]))
		elif inside.size() == 3:
			var outside := 0
			for index in 4:
				if not (face_bits & (1 << index)):
					outside = index
			segments.append(Vector2i(edges[(outside + 3) % 4], edges[outside]))
		elif _face_corners_adjacent(inside[0], inside[1]):
			var corner: int = inside[0] if (inside[0] + 1) % 4 == inside[1] else inside[1]
			segments.append(Vector2i(edges[(corner + 3) % 4], edges[(corner + 1) % 4]))
		elif mask & (1 << face_index):
			var corner: int = inside[0]
			segments.append(Vector2i(edges[corner], edges[(corner + 1) % 4]))
			segments.append(Vector2i(edges[(corner + 2) % 4], edges[(corner + 3) % 4]))
		else:
			var corner: int = inside[0]
			segments.append(Vector2i(edges[(corner + 3) % 4], edges[corner]))
			segments.append(Vector2i(edges[(corner + 1) % 4], edges[(corner + 2) % 4]))
	var neighbors: Array = []
	neighbors.resize(EDGE_CORNERS.size() + FACES.size() * 2)
	for index in neighbors.size():
		neighbors[index] = []
	for segment in segments:
		neighbors[segment.x].append(segment.y)
		neighbors[segment.y].append(segment.x)
	var loops: Array[PackedInt32Array] = []
	var visited := {}
	for edge in 12:
		if visited.has(edge) or neighbors[edge].is_empty():
			continue
		var loop := PackedInt32Array()
		var previous := -1
		var current := edge
		while true:
			visited[current] = true
			loop.append(current)
			var options: Array = neighbors[current]
			if options.size() != 2:
				break
			var next: int = options[0] if options[0] != previous else options[1]
			previous = current
			current = next
			if current == edge:
				break
			if loop.size() > 12:
				break
		loops.append(loop)
	return loops


static func _face_corners_adjacent(first: int, second: int) -> bool:
	return (first + 1) % 4 == second or (second + 1) % 4 == first


static func _canonical_loop(loop: PackedInt32Array, points: Array[Vector3]) -> Array:
	var count := loop.size()
	var best_key := PackedFloat32Array()
	var best_edges := loop
	var best_points := points
	for reflected in 2:
		for direction in 2:
			for rotation in count:
				var key := PackedFloat32Array()
				var edges := PackedInt32Array()
				var ordered: Array[Vector3] = []
				for step in count:
					var index := (rotation + step) % count if direction == 0 else (rotation - step + count * count) % count
					var point := points[index]
					if reflected == 1:
						point = Vector3(1.0 - point.x, point.y, point.z)
					edges.append(loop[index])
					ordered.append(point)
					key.append(roundf(point.x * 1024.0) / 1024.0)
					key.append(roundf(point.y * 1024.0) / 1024.0)
					key.append(roundf(point.z * 1024.0) / 1024.0)
				if best_key.is_empty() or _key_before(key, best_key):
					best_key = key
					best_edges = edges
					best_points = ordered
	return [best_edges, best_points]


static func _key_before(first: PackedFloat32Array, second: PackedFloat32Array) -> bool:
	for index in mini(first.size(), second.size()):
		if first[index] < second[index] - 0.0000001:
			return true
		if first[index] > second[index] + 0.0000001:
			return false
	return first.size() < second.size()


static func _face_aligned(loop: PackedInt32Array) -> bool:
	var common := 63
	for edge in loop:
		common &= _edge_faces[edge]
	return common != 0


static func _triangulate_loop(loop: PackedInt32Array) -> PackedInt32Array:
	var triangles := PackedInt32Array()
	if loop.size() < 3:
		return triangles
	for index in loop.size():
		if loop[index] < EDGE_CORNERS.size():
			continue
		var previous := loop[(index + loop.size() - 1) % loop.size()]
		var following := loop[(index + 1) % loop.size()]
		triangles.append_array(PackedInt32Array([previous, loop[index], following]))
		var rest := PackedInt32Array()
		for other in loop.size():
			if other == index:
				continue
			rest.append(loop[other])
		triangles.append_array(_triangulate_loop(rest))
		return triangles
	if loop.size() == 3:
		triangles.append_array(PackedInt32Array([loop[0], loop[1], loop[2]]))
		return triangles
	var points: Array[Vector3] = []
	for edge in loop:
		if edge >= EDGE_CORNERS.size():
			var face := (edge - EDGE_CORNERS.size()) / 2
			var offsets := Vector3i.ZERO
			for corner: int in FACES[face][0]:
				offsets += CORNER_OFFSETS[corner]
			points.append(Vector3(offsets) * 0.25)
			continue
		var corners: Array = EDGE_CORNERS[edge]
		var first: Vector3 = Vector3(CORNER_OFFSETS[corners[0]])
		var second: Vector3 = Vector3(CORNER_OFFSETS[corners[1]])
		points.append((first + second) * 0.5)
	var canonical := _canonical_loop(loop, points)
	var canonical_edges: PackedInt32Array = canonical[0]
	var canonical_points: Array = canonical[1]
	loop = canonical_edges
	points = canonical_points
	var normal := Vector3.ZERO
	for index in points.size():
		var current := points[index]
		var next := points[(index + 1) % points.size()]
		normal.x += (current.y - next.y) * (current.z + next.z)
		normal.y += (current.z - next.z) * (current.x + next.x)
		normal.z += (current.x - next.x) * (current.y + next.y)
	var axis := Vector3.RIGHT
	if absf(normal.y) <= absf(normal.x) and absf(normal.y) <= absf(normal.z):
		axis = Vector3.UP
	elif absf(normal.z) <= absf(normal.x):
		axis = Vector3.FORWARD
	var across := normal.cross(axis)
	if across.length_squared() < 0.0000000001:
		for position in range(1, points.size() - 1):
			triangles.append_array(PackedInt32Array([loop[0], loop[position], loop[position + 1]]))
		return triangles
	across = across.normalized()
	var down := normal.normalized().cross(across)
	var flat: Array[Vector2] = []
	for point in points:
		flat.append(Vector2(point.dot(across), point.dot(down)))
	var area := 0.0
	for index in flat.size():
		var current := flat[index]
		var next := flat[(index + 1) % flat.size()]
		area += current.x * next.y - next.x * current.y
	var orientation := 1.0 if area >= 0.0 else -1.0
	var order: Array[int] = []
	for index in points.size():
		order.append(index)
	var longest := not _face_aligned(loop)
	while order.size() > 3:
		var clipped := -1
		var best_span := -INF
		var best_area := -INF
		var best_alignment := -INF
		var plane := normal.normalized()
		for position in order.size():
			var previous := order[(position + order.size() - 1) % order.size()]
			var current := order[position]
			var next := order[(position + 1) % order.size()]
			if not _is_ear(flat, order, previous, current, next, orientation):
				continue
			if not longest:
				clipped = position
				break
			var span := points[previous].distance_squared_to(points[next])
			var ear_area := absf((flat[current] - flat[previous]).cross(flat[next] - flat[previous]))
			var ear_normal := (points[current] - points[previous]).cross(points[next] - points[previous])
			var alignment := absf(ear_normal.normalized().dot(plane)) if ear_normal.length_squared() > 0.000000001 else 0.0
			if span > best_span + 0.000000001 or (absf(span - best_span) <= 0.000000001 and (ear_area > best_area + 0.000000001 or (absf(ear_area - best_area) <= 0.000000001 and alignment > best_alignment + 0.000000001))):
				best_span = span
				best_area = ear_area
				best_alignment = alignment
				clipped = position
		if clipped < 0:
			break
		var previous := order[(clipped + order.size() - 1) % order.size()]
		var current := order[clipped]
		var next := order[(clipped + 1) % order.size()]
		triangles.append_array(PackedInt32Array([loop[previous], loop[current], loop[next]]))
		order.remove_at(clipped)
	if order.size() == 3:
		triangles.append_array(PackedInt32Array([loop[order[0]], loop[order[1]], loop[order[2]]]))
	elif order.size() > 3:
		for position in range(1, order.size() - 1):
			triangles.append_array(PackedInt32Array([loop[order[0]], loop[order[position]], loop[order[position + 1]]]))
	return triangles


static func _is_ear(flat: Array[Vector2], order: Array[int], previous: int, current: int, next: int, orientation: float) -> bool:
	var first := flat[previous]
	var middle := flat[current]
	var last := flat[next]
	var turn := (middle - first).cross(last - middle)
	if turn * orientation <= 0.0:
		return false
	for index in order:
		if index == previous or index == current or index == next:
			continue
		if _point_in_triangle(flat[index], first, middle, last):
			return false
	return true


static func _point_in_triangle(point: Vector2, first: Vector2, second: Vector2, third: Vector2) -> bool:
	var first_side := (second - first).cross(point - first)
	var second_side := (third - second).cross(point - second)
	var third_side := (first - third).cross(point - third)
	return (first_side >= 0.0 and second_side >= 0.0 and third_side >= 0.0) or (first_side <= 0.0 and second_side <= 0.0 and third_side <= 0.0)
