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

static var _case_loops: Array = []
static var _case_loop_triangles: Array = []
static var _edge_faces: PackedInt32Array = PackedInt32Array()
static var _face_triangles: Array = []

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
var bridge_cells := 0
var per_material := false
var hard_boundaries := false
var material_groups: Array = []


static func _static_init() -> void:
	_case_loops.resize(256)
	_case_loop_triangles.resize(256)
	for bits in 256:
		var loops := _case_loops_for(bits)
		var triangles: Array[PackedInt32Array] = []
		for loop: PackedInt32Array in loops:
			triangles.append(_triangulate_loop(loop))
		_case_loops[bits] = loops
		_case_loop_triangles[bits] = triangles
	_edge_faces.resize(EDGE_CORNERS.size())
	for face in FACES.size():
		for edge: int in FACES[face][1]:
			_edge_faces[edge] |= 1 << face
	_face_triangles.resize(256)
	for bits in 256:
		var face_triangles: Array[PackedInt32Array] = []
		face_triangles.resize(FACES.size())
		for group: PackedInt32Array in _case_loop_triangles[bits]:
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
				face_triangles[face] = PackedInt32Array([group[index], group[index + 1], group[index + 2]])
		_face_triangles[bits] = face_triangles


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
	materials = _fill_bridges(occupancy, material_ids, materials)
	return [occupancy, material_ids, materials, present]


func _fill_bridges(occupancy: PackedByteArray, material_ids: PackedInt32Array, materials: PackedFloat32Array) -> PackedFloat32Array:
	var real := occupancy.duplicate()
	for z in range(1, SAMPLE_SIZE - 1):
		for y in range(1, SAMPLE_SIZE - 1):
			for x in range(1, SAMPLE_SIZE - 1):
				var index := x + SAMPLE_SIZE * (y + SAMPLE_SIZE * z)
				if real[index] != 0:
					continue
				var face_solids: Array[Vector4i] = []
				var edge_solids: Array[Vector4i] = []
				for offset: Vector3i in FACE_OFFSETS:
					var neighbor_index := index + offset.x + SAMPLE_SIZE * (offset.y + SAMPLE_SIZE * offset.z)
					if real[neighbor_index] != 0:
						face_solids.append(Vector4i(offset.x, offset.y, offset.z, material_ids[neighbor_index]))
				if face_solids.is_empty() or face_solids.size() == FACE_OFFSETS.size():
					continue
				for offset: Vector3i in EDGE_OFFSETS:
					var neighbor_index := index + offset.x + SAMPLE_SIZE * (offset.y + SAMPLE_SIZE * offset.z)
					if real[neighbor_index] != 0:
						edge_solids.append(Vector4i(offset.x, offset.y, offset.z, material_ids[neighbor_index]))
				var pair_first := 0
				for first in face_solids.size():
					for second in range(first + 1, face_solids.size()):
						var a: Vector4i = face_solids[first]
						var b: Vector4i = face_solids[second]
						if a.w != b.w:
							continue
						var differences := 0
						if a.x != b.x:
							differences += 1
						if a.y != b.y:
							differences += 1
						if a.z != b.z:
							differences += 1
						if differences != 2:
							continue
						var opposite := index + a.x + b.x + SAMPLE_SIZE * (a.y + b.y + SAMPLE_SIZE * (a.z + b.z))
						if real[opposite] == 0:
							pair_first = a.w
							break
					if pair_first != 0:
						break
				if pair_first == 0:
					for face: Vector4i in face_solids:
						for edge: Vector4i in edge_solids:
							if face.w != edge.w:
								continue
							var span := Vector3i(edge.x - face.x, edge.y - face.y, edge.z - face.z)
							if absi(span.x) != 1 or absi(span.y) != 1 or absi(span.z) != 1:
								continue
							if _box_clear(real, x + face.x, y + face.y, z + face.z, span):
								pair_first = face.w
								break
						if pair_first != 0:
							break
				if pair_first == 0:
					continue
				occupancy[index] = 1
				material_ids[index] = pair_first
				bridge_cells += 1
	return materials


static func _box_clear(real: PackedByteArray, corner_x: int, corner_y: int, corner_z: int, span: Vector3i) -> bool:
	for step_z in 2:
		for step_y in 2:
			for step_x in 2:
				if step_x == 0 and step_y == 0 and step_z == 0:
					continue
				if step_x == 1 and step_y == 1 and step_z == 1:
					continue
				var x := corner_x + step_x * span.x
				var y := corner_y + step_y * span.y
				var z := corner_z + step_z * span.z
				if real[x + SAMPLE_SIZE * (y + SAMPLE_SIZE * z)] != 0:
					return false
	return true


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
		merged = _merge_flats(built[0], built[1], built[2], built[3], built[4])
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
		var merged := _merge_flats(built[0], built[1], built[2], built[3], built[4])
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
	for z in range(-MESH_PADDING, CHUNK_SIZE + 1):
		for y in range(-MESH_PADDING, CHUNK_SIZE + 1):
			for x in range(-MESH_PADDING, CHUNK_SIZE + 1):
				var cell := Vector3i(x, y, z)
				var bits := 0
				for corner in 8:
					var sample := cell + CORNER_OFFSETS[corner] + Vector3i.ONE * SAMPLE_PADDING
					var sample_index := sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)
					if occupancy[sample_index] == 0:
						continue
					bits |= 1 << corner
				if bits == 0:
					continue
				var state_x := 0 if x <= 0 else (2 if x >= CHUNK_SIZE - 2 else 1)
				var state_y := 0 if y <= 0 else (2 if y >= CHUNK_SIZE - 2 else 1)
				var state_z := 0 if z <= 0 else (2 if z >= CHUNK_SIZE - 2 else 1)
				if owners[(state_x * 3 + state_y) * 3 + state_z] == 2:
					continue
				var loops: Array = _case_loops[bits]
				if loops.is_empty():
					continue
				var loop_triangles: Array = _case_loop_triangles[bits]
				for loop_index in loops.size():
					var triangle_edges: PackedInt32Array = loop_triangles[loop_index]
					for index in range(0, triangle_edges.size(), 3):
						var first_edge := triangle_edges[index]
						var second_edge := triangle_edges[index + 1]
						var third_edge := triangle_edges[index + 2]
						var first_point := _edge_point(cell, first_edge)
						var second_point := _edge_point(cell, second_edge)
						var third_point := _edge_point(cell, third_edge)
						if _mirror_on_face(cell, first_edge, second_edge, third_edge, occupancy):
							continue
						var first_material := _edge_material(cell, first_edge, occupancy, material_ids)
						var second_material := _edge_material(cell, second_edge, occupancy, material_ids)
						var third_material := _edge_material(cell, third_edge, occupancy, material_ids)
						if hard_boundaries:
							var chosen := first_material
							if second_material == third_material:
								chosen = second_material
							first_material = chosen
							second_material = chosen
							third_material = chosen
						_append_oriented_triangle(
							cell, bits,
							first_point, second_point, third_point,
							first_material,
							second_material,
							third_material,
							materials, positions, normals, vertex_colors, vertex_materials, indices
						)
	return [positions, normals, vertex_colors, vertex_materials, indices]


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
			var width := 1
			while complete.has(Vector2i(square.x + width * 2, square.y)):
				width += 1
			var height := 1
			var growing := true
			while growing:
				for offset in width:
					if not complete.has(Vector2i(square.x + offset * 2, square.y + height * 2)):
						growing = false
						break
				if growing:
					height += 1
			var area := width * height
			var perimeter := 2 * (width + height)
			for row in height:
				for column in width:
					complete.erase(Vector2i(square.x + column * 2, square.y + row * 2))
			if area * 2 <= perimeter:
				continue
			for row in height:
				for column in width:
					for triangle: int in entry.halves[Vector2i(square.x + column * 2, square.y + row * 2)]:
						consumed[triangle] = 1
			_emit_flat_fan(entry, Vector2(square) * 0.5, width, height, merged_positions, merged_normals, merged_colors, merged_materials, merged_indices)
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
		var position_key := Vector3i(roundi(position.x * 2.0), roundi(position.y * 2.0), roundi(position.z * 2.0))
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
	var face_triangles: Array = _face_triangles[neighbor_bits]
	var mirrored: PackedInt32Array = face_triangles[neighbor_face]
	if mirrored.is_empty():
		return false
	return _same_face_triangle(cell, [first_edge, second_edge, third_edge], neighbor, mirrored)


static func _same_face_triangle(first_cell: Vector3i, first_edges: Array, second_cell: Vector3i, second_edges: PackedInt32Array) -> bool:
	if first_edges.size() != second_edges.size():
		return false
	var first: Array[Vector3i] = []
	var second: Array[Vector3i] = []
	for edge: int in first_edges:
		var corners: Array = EDGE_CORNERS[edge]
		first.append(first_cell * 2 + CORNER_OFFSETS[corners[0]] + CORNER_OFFSETS[corners[1]])
	for edge: int in second_edges:
		var corners: Array = EDGE_CORNERS[edge]
		second.append(second_cell * 2 + CORNER_OFFSETS[corners[0]] + CORNER_OFFSETS[corners[1]])
	first.sort()
	second.sort()
	return first == second


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


static func _edge_material(cell: Vector3i, edge: int, occupancy: PackedByteArray, material_ids: PackedInt32Array) -> int:
	var corners: Array = EDGE_CORNERS[edge]
	for corner: int in corners:
		var sample := cell + CORNER_OFFSETS[corner] + Vector3i.ONE * SAMPLE_PADDING
		var sample_index := sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)
		if occupancy[sample_index] != 0:
			return material_ids[sample_index]
	return 0


static func _edge_point(cell: Vector3i, edge: int) -> Vector3:
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


static func _case_loops_for(bits: int) -> Array[PackedInt32Array]:
	var segments: Array[Vector2i] = []
	for face: Array in FACES:
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
		else:
			var corner: int = inside[0]
			segments.append(Vector2i(edges[(corner + 3) % 4], edges[corner]))
			segments.append(Vector2i(edges[(corner + 1) % 4], edges[(corner + 2) % 4]))
	var neighbors: Array = []
	neighbors.resize(12)
	for index in 12:
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


static func _triangulate_loop(loop: PackedInt32Array) -> PackedInt32Array:
	var triangles := PackedInt32Array()
	if loop.size() < 3:
		return triangles
	if loop.size() == 3:
		triangles.append_array(PackedInt32Array([loop[0], loop[1], loop[2]]))
		return triangles
	var points: Array[Vector3] = []
	for edge in loop:
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
	while order.size() > 3:
		var clipped := false
		for position in order.size():
			var previous := order[(position + order.size() - 1) % order.size()]
			var current := order[position]
			var next := order[(position + 1) % order.size()]
			if _is_ear(flat, order, previous, current, next, orientation):
				triangles.append_array(PackedInt32Array([loop[previous], loop[current], loop[next]]))
				order.remove_at(position)
				clipped = true
				break
		if not clipped:
			break
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
