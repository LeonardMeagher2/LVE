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

var merge_flats := true
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
	var owners := _build_owners(present)
	var merged: Array
	if per_material:
		merged = _build_per_material(occupancy, material_ids, materials, owners)
	else:
		var built := _build_surfaces(occupancy, material_ids, materials, owners)
		merged = _merge_flats(built[0], built[1], built[2], built[3], built[4]) if merge_flats else built
	var welded := _weld(merged[0], merged[1], merged[2], merged[3], merged[4])
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
		var merged := _merge_flats(built[0], built[1], built[2], built[3], built[4]) if merge_flats else built
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
				var loops: Array = case_data["loops"]
				var loop_triangles: Array = case_data["triangles"]
				for loop_index in loops.size():
					var triangle_edges: PackedInt32Array = loop_triangles[loop_index]
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
							var first_site := _edge_sample(cell, first_edge, occupancy, material_ids)
							var second_site := _edge_sample(cell, second_edge, occupancy, material_ids)
							var third_site := _edge_sample(cell, third_edge, occupancy, material_ids)
							_append_material_triangle(
								cell, bits,
								PackedVector3Array([first_point, second_point, third_point]),
								PackedInt32Array([
									material_ids[_sample_index(first_site)],
									material_ids[_sample_index(second_site)],
									material_ids[_sample_index(third_site)],
								]),
								PackedVector3Array([Vector3(first_site), Vector3(second_site), Vector3(third_site)]),
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


func _append_material_triangle(cell: Vector3i, bits: int, points: PackedVector3Array, labels: PackedInt32Array, sites: PackedVector3Array, materials: PackedFloat32Array, positions: PackedVector3Array, normals: PackedVector3Array, vertex_colors: PackedColorArray, vertex_materials: PackedInt32Array, indices: PackedInt32Array) -> void:
	var unique := -1
	for index in 3:
		if labels[index] != labels[(index + 1) % 3] and labels[index] != labels[(index + 2) % 3]:
			unique = index
			break
	if unique < 0:
		_append_oriented_triangle(cell, bits, points[0], points[1], points[2], labels[0], labels[0], labels[0], materials, positions, normals, vertex_colors, vertex_materials, indices)
		return
	var first := (unique + 1) % 3
	var last := (unique + 2) % 3
	var first_cut := _material_cut(points[unique], sites[unique], points[first], sites[first])
	var last_cut := _material_cut(points[last], sites[last], points[unique], sites[unique])
	if labels[first] == labels[last]:
		_append_oriented_triangle(cell, bits, points[unique], first_cut, last_cut, labels[unique], labels[unique], labels[unique], materials, positions, normals, vertex_colors, vertex_materials, indices)
		_append_oriented_triangle(cell, bits, first_cut, points[first], points[last], labels[first], labels[first], labels[first], materials, positions, normals, vertex_colors, vertex_materials, indices)
		_append_oriented_triangle(cell, bits, first_cut, points[last], last_cut, labels[first], labels[first], labels[first], materials, positions, normals, vertex_colors, vertex_materials, indices)
		return
	var middle_cut := _material_cut(points[first], sites[first], points[last], sites[last])
	var centre := _triple_point(points, sites, (first_cut + middle_cut + last_cut) / 3.0)
	_append_oriented_triangle(cell, bits, points[unique], first_cut, centre, labels[unique], labels[unique], labels[unique], materials, positions, normals, vertex_colors, vertex_materials, indices)
	_append_oriented_triangle(cell, bits, points[unique], centre, last_cut, labels[unique], labels[unique], labels[unique], materials, positions, normals, vertex_colors, vertex_materials, indices)
	_append_oriented_triangle(cell, bits, points[first], middle_cut, centre, labels[first], labels[first], labels[first], materials, positions, normals, vertex_colors, vertex_materials, indices)
	_append_oriented_triangle(cell, bits, points[first], centre, first_cut, labels[first], labels[first], labels[first], materials, positions, normals, vertex_colors, vertex_materials, indices)
	_append_oriented_triangle(cell, bits, points[last], last_cut, centre, labels[last], labels[last], labels[last], materials, positions, normals, vertex_colors, vertex_materials, indices)
	_append_oriented_triangle(cell, bits, points[last], centre, middle_cut, labels[last], labels[last], labels[last], materials, positions, normals, vertex_colors, vertex_materials, indices)


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
	var first_weight := (points[1] - points[0]).cross(point - points[0]).dot(normal)
	var second_weight := (points[2] - points[0]).cross(point - points[0]).dot(normal)
	var squared := normal.length_squared()
	if first_weight / squared < -0.001 or second_weight / squared < -0.001:
		return fallback
	if first_weight / squared + second_weight / squared > 1.001:
		return fallback
	return point


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


static func _sample_index(site: Vector3i) -> int:
	var sample := site + Vector3i.ONE * SAMPLE_PADDING
	return sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)


func _edge_sample(cell: Vector3i, edge: int, occupancy: PackedByteArray, material_ids: PackedInt32Array) -> Vector3i:
	if edge >= EDGE_CORNERS.size():
		var point := _edge_point(cell, edge)
		var closest := INF
		var closest_site := Vector3i.ZERO
		var closest_material := 0
		for corner in 8:
			var sample := cell + CORNER_OFFSETS[corner] + Vector3i.ONE * SAMPLE_PADDING
			var sample_index := sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)
			if occupancy[sample_index] == 0:
				continue
			var distance := (point - (Vector3(cell) + Vector3(CORNER_OFFSETS[corner]))).length_squared()
			if distance < closest - 0.000001 or (distance <= closest + 0.000001 and material_ids[sample_index] < closest_material):
				closest = distance
				closest_site = cell + CORNER_OFFSETS[corner]
				closest_material = material_ids[sample_index]
		return closest_site
	var corners: Array = EDGE_CORNERS[edge]
	for corner: int in corners:
		var sample := cell + CORNER_OFFSETS[corner] + Vector3i.ONE * SAMPLE_PADDING
		var sample_index := sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)
		if occupancy[sample_index] != 0:
			return cell + CORNER_OFFSETS[corner]
	return Vector3i.ZERO


static func _merge_flats(positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, materials: PackedInt32Array, indices: PackedInt32Array) -> Array:
	var triangle_count := indices.size() / 3
	var consumed := PackedByteArray()
	consumed.resize(triangle_count)
	var buckets := {}
	for triangle in triangle_count:
		var first := indices[triangle * 3]
		var second := indices[triangle * 3 + 1]
		var third := indices[triangle * 3 + 2]
		var normal := normals[first]
		var axis := -1
		for candidate in 3:
			if absf(normal[candidate]) > 0.999:
				axis = candidate
		if axis < 0:
			continue
		if materials[first] != materials[second] or materials[first] != materials[third]:
			continue
		var sign := 1 if normal[axis] > 0.0 else 0
		var plane := roundi(positions[first][axis] * 2.0)
		var key := ((axis * 2 + sign) << 34) | ((plane + 32768) << 18) | materials[first]
		var entry: Dictionary = buckets.get(key, {})
		if entry.is_empty():
			entry = {
				"normal": normal,
				"color": colors[first],
				"material": materials[first],
				"axis": axis,
				"plane": positions[first][axis],
				"u_axis": (axis + 1) % 3,
				"v_axis": (axis + 2) % 3,
				"squares": {},
				"halves": {},
			}
			buckets[key] = entry
		var u_axis: int = entry.u_axis
		var v_axis: int = entry.v_axis
		var first_u := roundi(positions[first][u_axis] * 2.0)
		var first_v := roundi(positions[first][v_axis] * 2.0)
		var second_u := roundi(positions[second][u_axis] * 2.0)
		var second_v := roundi(positions[second][v_axis] * 2.0)
		var third_u := roundi(positions[third][u_axis] * 2.0)
		var third_v := roundi(positions[third][v_axis] * 2.0)
		var square := Vector2i(
			mini(first_u, mini(second_u, third_u)),
			mini(first_v, mini(second_v, third_v))
		)
		var has_low := false
		var has_high := false
		var has_right := false
		var has_up := false
		var on_square := true
		for point in [[first_u, first_v], [second_u, second_v], [third_u, third_v]]:
			if point[0] == square.x and point[1] == square.y:
				has_low = true
			elif point[0] == square.x + 2 and point[1] == square.y + 2:
				has_high = true
			elif point[0] == square.x + 2 and point[1] == square.y:
				has_right = true
			elif point[0] == square.x and point[1] == square.y + 2:
				has_up = true
			else:
				on_square = false
		if not on_square:
			continue
		var squares: Dictionary = entry.squares
		var mask: int = squares.get(square, 0)
		if not has_high:
			mask |= 1
		elif not has_low:
			mask |= 2
		elif not has_right:
			mask |= 4
		elif not has_up:
			mask |= 8
		squares[square] = mask
		var halves: Dictionary = entry.halves
		var list: Array = halves.get(square, [])
		list.append(triangle)
		halves[square] = list
	var merged_positions := PackedVector3Array()
	var merged_normals := PackedVector3Array()
	var merged_colors := PackedColorArray()
	var merged_materials := PackedInt32Array()
	var merged_indices := PackedInt32Array()
	for key in buckets:
		var entry: Dictionary = buckets[key]
		var squares: Dictionary = entry.squares
		var complete := {}
		for square: Vector2i in squares:
			var mask: int = squares[square]
			if (mask & 3) == 3 or (mask & 12) == 12:
				complete[square] = true
		var order: Array = complete.keys()
		order.sort_custom(_square_before)
		for square: Vector2i in order:
			if not complete.has(square):
				continue
			var left := square.x
			while complete.has(Vector2i(left - 2, square.y)):
				left -= 2
			var right := square.x
			while complete.has(Vector2i(right + 2, square.y)):
				right += 2
			var width := (right - left) / 2 + 1
			var bottom := square.y
			var growing := true
			while growing:
				for offset in width:
					if not complete.has(Vector2i(left + offset * 2, bottom - 2)):
						growing = false
						break
				if growing:
					bottom -= 2
			var top := square.y
			growing = true
			while growing:
				for offset in width:
					if not complete.has(Vector2i(left + offset * 2, top + 2)):
						growing = false
						break
				if growing:
					top += 2
			var height := (top - bottom) / 2 + 1
			var area := width * height
			var perimeter := 2 * (width + height)
			for row in height:
				for column in width:
					complete.erase(Vector2i(left + column * 2, bottom + row * 2))
			if area * 2 <= perimeter:
				continue
			for row in height:
				for column in width:
					for triangle: int in entry.halves[Vector2i(left + column * 2, bottom + row * 2)]:
						consumed[triangle] = 1
			_emit_flat_fan(entry, Vector2(left, bottom) * 0.5, width, height, merged_positions, merged_normals, merged_colors, merged_materials, merged_indices)
	for triangle in triangle_count:
		if consumed[triangle] != 0:
			continue
		var first_vertex := merged_positions.size()
		for corner in 3:
			var source := indices[triangle * 3 + corner]
			merged_positions.append(positions[source])
			merged_normals.append(normals[source])
			merged_colors.append(colors[source])
			merged_materials.append(materials[source])
		merged_indices.append(first_vertex)
		merged_indices.append(first_vertex + 1)
		merged_indices.append(first_vertex + 2)
	return [merged_positions, merged_normals, merged_colors, merged_materials, merged_indices]


static func _square_before(first: Vector2i, second: Vector2i) -> bool:
	if first.y != second.y:
		return first.y < second.y
	return first.x < second.x


static func _emit_flat_fan(entry: Dictionary, corner: Vector2, width: int, height: int, positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, materials: PackedInt32Array, indices: PackedInt32Array) -> void:
	var normal: Vector3 = entry.normal
	var color: Color = entry.color
	var material: int = entry.material
	var axis: int = entry.axis
	var u_axis: int = entry.u_axis
	var v_axis: int = entry.v_axis
	var plane: float = entry.plane
	var centre := _plane_point(axis, plane, u_axis, v_axis, corner.x + width * 0.5, corner.y + height * 0.5)
	var loop: Array[Vector3] = []
	for column in width:
		loop.append(_plane_point(axis, plane, u_axis, v_axis, corner.x + column, corner.y))
	for row in height:
		loop.append(_plane_point(axis, plane, u_axis, v_axis, corner.x + width, corner.y + row))
	for column in range(width, 0, -1):
		loop.append(_plane_point(axis, plane, u_axis, v_axis, corner.x + column, corner.y + height))
	for row in range(height, 0, -1):
		loop.append(_plane_point(axis, plane, u_axis, v_axis, corner.x, corner.y + row))
	for index in loop.size():
		var first := loop[index]
		var second := loop[(index + 1) % loop.size()]
		if (first - centre).cross(second - centre).dot(normal) > 0.0:
			var swap := first
			first = second
			second = swap
		var first_vertex := positions.size()
		positions.append(centre)
		positions.append(first)
		positions.append(second)
		for vertex in 3:
			normals.append(normal)
			colors.append(color)
			materials.append(material)
		indices.append(first_vertex)
		indices.append(first_vertex + 1)
		indices.append(first_vertex + 2)


static func _plane_point(axis: int, plane: float, u_axis: int, v_axis: int, u: float, v: float) -> Vector3:
	var point := Vector3.ZERO
	point[axis] = plane
	point[u_axis] = u
	point[v_axis] = v
	return point


static func _weld(positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, materials: PackedInt32Array, indices: PackedInt32Array) -> Array:
	var welded_positions := PackedVector3Array()
	var welded_normals := PackedVector3Array()
	var welded_colors := PackedColorArray()
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
			by_material[material_id] = vertex
			by_normal[normal_key] = by_material
			by_position[position_key] = by_normal
		welded_indices[index] = vertex
	return [welded_positions, welded_normals, welded_colors, welded_indices]


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


func _append_oriented_triangle(cell: Vector3i, bits: int, first: Vector3, second: Vector3, third: Vector3, first_material: int, second_material: int, third_material: int, materials: PackedFloat32Array, positions: PackedVector3Array, normals: PackedVector3Array, vertex_colors: PackedColorArray, vertex_materials: PackedInt32Array, indices: PackedInt32Array) -> void:
	var winding := (second - first).cross(third - first)
	if winding.length_squared() < 0.0000000001:
		return
	var inside := _inside_gradient(bits, (first + second + third) / 3.0 - Vector3(cell))
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
