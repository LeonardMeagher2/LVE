class_name VoxelMarchingMeshBuilder
extends RefCounted


const CHUNK_SIZE := VoxelFrame.CHUNK_SIZE
const ATLAS := preload("./VoxelAtlas.gd")
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
const COMPONENT_STEPS: Array[int] = [-1, 1, -4, 4]
const CORNER_STEPS := [
	0,
	1,
	SAMPLE_SIZE,
	SAMPLE_SIZE + 1,
	SAMPLE_SIZE * SAMPLE_SIZE,
	SAMPLE_SIZE * SAMPLE_SIZE + 1,
	SAMPLE_SIZE * SAMPLE_SIZE + SAMPLE_SIZE,
	SAMPLE_SIZE * SAMPLE_SIZE + SAMPLE_SIZE + 1,
]
const PRESENT_SELF := 13
const FIELD_RADIUS := 2
const DEGENERATE_NORMAL_KEY := -999999
const DISSOLVE_LINK_LIMIT := 9
const DISSOLVE_CREASE_COSINE := 0.9063077870366499
const DISSOLVE_NORMAL_COSINE := 0.9902680687415704
const DISSOLVE_COLOUR_LIMIT := 0.02
const DISSOLVE_PLANAR_LIMIT := 0.2
const DISSOLVE_QUALITY_LIMIT := 0.022
const DISSOLVE_AREA_LIMIT := 0.000001
const FIELD_SIZE := SAMPLE_SIZE + FIELD_RADIUS * 2
const FIELD_PADDING := SAMPLE_PADDING + FIELD_RADIUS
const FIELD_CORNER_STEPS := [
	0,
	1,
	FIELD_SIZE,
	FIELD_SIZE + 1,
	FIELD_SIZE * FIELD_SIZE,
	FIELD_SIZE * FIELD_SIZE + 1,
	FIELD_SIZE * FIELD_SIZE + FIELD_SIZE,
	FIELD_SIZE * FIELD_SIZE + FIELD_SIZE + 1,
]

static var _case_loops: Array = []
static var _case_triangles: Array = []
static var _case_face_triangles: Array = []
static var _diagonal_masks: PackedInt32Array = PackedInt32Array()
static var _opposite_pairs: PackedByteArray = PackedByteArray()
static var _field_distances: PackedFloat32Array = PackedFloat32Array()
static var _corner_points: PackedVector3Array = PackedVector3Array()
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
var build_started_us := 0
var profile := false
var sample_us := 0
var field_us := 0
var cells_us := 0
var drop_us := 0
var normals_us := 0
var merge_us := 0
var dissolve_us := 0
var atlas_us := 0
var smooth_normals := false
var ao_strength := 0.0
var merge_coplanar := true
var dissolve_limited := true
var dissolve_link_limit := DISSOLVE_LINK_LIMIT
var skip_atlas := false
var vertex_materials := PackedInt32Array()
var material_table := PackedFloat32Array()
var slice_axis := -1
var slice_index := 0
var slice_count := 1
var per_material := false
var hard_boundaries := false
var _pinned_seams: Dictionary = {}
var _edge_site := Vector3.ZERO
var _edge_label := 0
var _merge_next := PackedInt32Array()
var _merge_next_stamp := PackedInt32Array()
var _merge_previous_stamp := PackedInt32Array()
var _merge_stamp := 0
var _dissolve_next := PackedInt32Array()
var _dissolve_next_stamp := PackedInt32Array()
var _dissolve_previous_stamp := PackedInt32Array()
var _dissolve_stamp := 0
var _dissolve_points := PackedVector3Array()
var _dissolve_normals := PackedVector3Array()
var _dissolve_colours := PackedColorArray()
var _dissolve_flat := PackedVector2Array()
var _dissolve_outward := Vector3.ZERO
var _dissolve_removed_position := Vector3.ZERO
var _dissolve_flat_point := Vector2.ZERO
var _dissolve_removed_normal := Vector3.ZERO
var _dissolve_removed_colour := Color.WHITE
var _dissolve_edge_set: Dictionary = {}
var _triangle_spread := 0.0
var _triangle_quality := 0.0
var _triangle_covers := false

var material_groups: Array = []


static func _static_init() -> void:
	_edge_faces.resize(EDGE_CORNERS.size() + FACES.size() * 2)
	for face in FACES.size():
		for edge: int in FACES[face][1]:
			_edge_faces[edge] |= 1 << face
		_edge_faces[EDGE_CORNERS.size() + face * 2] |= 1 << face
		_edge_faces[EDGE_CORNERS.size() + face * 2 + 1] |= 1 << face
	_diagonal_masks.resize(256)
	_opposite_pairs.resize(256)
	_case_loops.resize(256)
	_case_triangles.resize(256)
	_case_face_triangles.resize(256)
	for bits in 256:
		_diagonal_masks[bits] = _diagonal_faces(bits)
		_opposite_pairs[bits] = 1 if _opposite_pair_for(bits) else 0
		var case_data := _build_case_data(bits, _diagonal_masks[bits])
		_case_loops[bits] = case_data["loops"]
		_case_triangles[bits] = case_data["triangles"]
		_case_face_triangles[bits] = case_data["face_triangles"]
	for offset_z in range(-FIELD_RADIUS, FIELD_RADIUS + 1):
		for offset_y in range(-FIELD_RADIUS, FIELD_RADIUS + 1):
			for offset_x in range(-FIELD_RADIUS, FIELD_RADIUS + 1):
				_field_distances.append(_field_distance(offset_x, offset_y, offset_z))
	_corner_points.resize(CORNER_OFFSETS.size())
	for corner in CORNER_OFFSETS.size():
		_corner_points[corner] = Vector3(CORNER_OFFSETS[corner])


static func _build_case_data(bits: int, mask: int) -> Dictionary:
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
	return {"loops": loops, "triangles": triangles, "face_triangles": face_triangles}


func run() -> void:
	var frame := source_frame
	source_frame = null
	var occupancy := PackedByteArray()
	var material_ids := PackedInt32Array()
	var materials := PackedFloat32Array()
	var present := PackedByteArray()
	var occupied := -1
	if frame != null:
		var sample_started := Time.get_ticks_usec() if profile else 0
		var sampled := _sample(frame, chunk_location, slice_axis, slice_index, slice_count)
		if profile:
			sample_us = Time.get_ticks_usec() - sample_started
		occupancy = sampled[0]
		material_ids = sampled[1]
		materials = sampled[2]
		present = sampled[3]
		occupied = sampled[4]
	_build(occupancy, material_ids, materials, present, occupied)


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
	var occupied := 0
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				var neighbor_location := location + Vector3i(x, y, z)
				if slice_axis >= 0:
					var first_layer := neighbor_location[slice_axis] * CHUNK_SIZE
					if first_layer + CHUNK_SIZE <= slice_index or first_layer >= slice_index + slice_count:
						continue
				if frame.chunks.has(neighbor_location):
					present[(x + 1) + 3 * ((y + 1) + 3 * (z + 1))] = 1
	var slice_last := slice_index + slice_count
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
						occupied += 1
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
	return [occupancy, material_ids, materials, present, occupied]


func _build(occupancy: PackedByteArray, material_ids: PackedInt32Array, materials: PackedFloat32Array, present: PackedByteArray, occupied := -1) -> void:
	if present.is_empty() or present[PRESENT_SELF] == 0:
		_set_empty()
		return
	if occupied == 0 or occupied == occupancy.size():
		enclosed_culled = occupied == occupancy.size()
		_set_empty()
		return
	enclosed_culled = false
	_pinned_seams.clear()
	var owners := _build_owners(present)
	var merged: Array
	if per_material:
		merged = _build_per_material(occupancy, material_ids, materials, owners)
	else:
		var built := _build_surfaces(occupancy, material_ids, materials, owners)
		merged = built
	var welded := [merged[0], merged[1], merged[2], merged[4], merged[3]]
	var drop_started := Time.get_ticks_usec() if profile else 0
	var position_ids := _position_ids(welded[0])
	welded[3] = _drop_degenerate_triangles(position_ids, welded[3])
	welded[3] = _drop_opposite_duplicate_triangles(welded[0], position_ids, welded[3])
	if profile:
		drop_us = Time.get_ticks_usec() - drop_started
	var normals_started := Time.get_ticks_usec() if profile else 0
	welded = _rebuild_flat_normals(welded[0], welded[1], welded[2], welded[4], welded[3], occupancy, smooth_normals)
	if profile:
		normals_us = Time.get_ticks_usec() - normals_started
	if ao_strength > 0.0:
		_apply_edge_ambient_occlusion(welded[0], welded[2], welded[3], ao_strength)
	var merge_started := Time.get_ticks_usec() if profile else 0
	if merge_coplanar:
		welded = _merge_coplanar_fans(welded[0], welded[1], welded[2], welded[4], welded[3])
	if profile:
		merge_us = Time.get_ticks_usec() - merge_started
	var dissolve_started := Time.get_ticks_usec() if profile else 0
	if smooth_normals and merge_coplanar and dissolve_limited:
		welded = _dissolve_smooth_vertices(welded[0], welded[1], welded[2], welded[4], welded[3])
	if profile:
		dissolve_us = Time.get_ticks_usec() - dissolve_started
	var atlas_started := Time.get_ticks_usec() if profile else 0
	var uvs := _build_atlas_uvs(welded[4], materials) if not skip_atlas else PackedVector2Array()
	if profile:
		atlas_us = Time.get_ticks_usec() - atlas_started
	vertex_materials = welded[4]
	material_table = materials
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays[Mesh.ARRAY_VERTEX] = welded[0]
	surface_arrays[Mesh.ARRAY_NORMAL] = welded[1]
	surface_arrays[Mesh.ARRAY_COLOR] = welded[2]
	surface_arrays[Mesh.ARRAY_INDEX] = welded[3]
	surface_arrays[Mesh.ARRAY_TEX_UV] = uvs
	geometry_bytes = welded[0].size() * (48 if not uvs.is_empty() else 40) + welded[3].size() * 4


func _set_empty() -> void:
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array()
	surface_arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array()
	surface_arrays[Mesh.ARRAY_COLOR] = PackedColorArray()
	surface_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array()
	surface_arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array()
	atlas = null
	atlas_size = Vector2i.ZERO
	atlas_albedo = PackedByteArray()
	atlas_orm = PackedByteArray()
	atlas_emission = PackedByteArray()
	geometry_bytes = 0
	vertex_materials = PackedInt32Array()
	material_table = PackedFloat32Array()
	merge_us = 0
	dissolve_us = 0


func _apply_edge_ambient_occlusion(positions: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, strength: float) -> void:
	var canonical_of := PackedInt32Array()
	canonical_of.resize(positions.size())
	var canonical := {}
	var points := PackedVector3Array()
	for vertex in positions.size():
		var key := Vector3i(roundi(positions[vertex].x * 1024.0), roundi(positions[vertex].y * 1024.0), roundi(positions[vertex].z * 1024.0))
		var position_index: int = canonical.get(key, -1)
		if position_index < 0:
			position_index = points.size()
			canonical[key] = position_index
			points.append(positions[vertex])
		canonical_of[vertex] = position_index
	var triangle_normals := PackedVector3Array()
	var triangle_count := indices.size() / 3
	triangle_normals.resize(triangle_count)
	var edges := {}
	for triangle in triangle_count:
		var first := positions[indices[triangle * 3]]
		var normal := (positions[indices[triangle * 3 + 1]] - first).cross(positions[indices[triangle * 3 + 2]] - first)
		if normal.length_squared() < 0.0000000001:
			continue
		triangle_normals[triangle] = -normal.normalized()
		for corner in 3:
			var from := canonical_of[indices[triangle * 3 + corner]]
			var to := canonical_of[indices[triangle * 3 + (corner + 1) % 3]]
			var key := Vector2i(mini(from, to), maxi(from, to))
			var edge_triangles: Array = edges.get(key, [])
			if edge_triangles.size() < 3:
				edge_triangles.append(triangle)
				edges[key] = edge_triangles
	var occlusion := {}
	for key: Vector2i in edges:
		var edge_triangles: Array = edges[key]
		if edge_triangles.size() != 2:
			continue
		var first_triangle: int = edge_triangles[0]
		var second_triangle: int = edge_triangles[1]
		var first_normal := triangle_normals[first_triangle]
		var second_normal := triangle_normals[second_triangle]
		var midpoint := (points[key.x] + points[key.y]) * 0.5
		var first_third := _edge_third(first_triangle, key, positions, indices, canonical_of)
		var second_third := _edge_third(second_triangle, key, positions, indices, canonical_of)
		if first_normal.dot(second_third - midpoint) <= 0.0 or second_normal.dot(first_third - midpoint) <= 0.0:
			continue
		var normal_angle := acos(clampf(first_normal.dot(second_normal), -1.0, 1.0))
		var value := clampf(normal_angle / PI, 0.0, 1.0)
		occlusion[key.x] = maxf(occlusion.get(key.x, 0.0), value)
		occlusion[key.y] = maxf(occlusion.get(key.y, 0.0), value)
	for vertex in positions.size():
		var value: float = occlusion.get(canonical_of[vertex], 0.0)
		var ao := 1.0 - strength * value
		colors[vertex] = Color(ao, ao, ao, 1.0)


func _edge_third(triangle: int, key: Vector2i, positions: PackedVector3Array, indices: PackedInt32Array, canonical_of: PackedInt32Array) -> Vector3:
	for corner in 3:
		var vertex := indices[triangle * 3 + corner]
		var position_index := canonical_of[vertex]
		if position_index != key.x and position_index != key.y:
			return positions[vertex]
	return Vector3.ZERO


func _build_atlas_uvs(vertex_materials: PackedInt32Array, materials: PackedFloat32Array) -> PackedVector2Array:
	atlas = null
	atlas_size = Vector2i.ZERO
	atlas_albedo = PackedByteArray()
	atlas_orm = PackedByteArray()
	atlas_emission = PackedByteArray()
	if vertex_materials.is_empty():
		return PackedVector2Array()
	var used := {}
	for id: int in vertex_materials:
		used[id] = true
	var ids: Array = used.keys()
	ids.sort()
	var bake := ATLAS.new()
	var checkpoint := func(_index: int) -> bool: return true
	var patch_of := {}
	for id: int in ids:
		var base := id * VoxelFrame.MATERIAL_STRIDE
		var patch: int = bake.add_patch(materials.slice(base, base + VoxelFrame.MATERIAL_STRIDE), Vector2i.ONE, checkpoint)
		if patch < 0:
			return PackedVector2Array()
		patch_of[id] = patch
	if bake.bake(checkpoint) != OK or bake.albedo == null:
		return PackedVector2Array()
	var centre_of := {}
	for id: int in ids:
		var corners: PackedVector2Array = bake.patch_uvs(patch_of[id])
		centre_of[id] = (corners[0] + corners[2]) * 0.5
	var uvs := PackedVector2Array()
	uvs.resize(vertex_materials.size())
	for index in vertex_materials.size():
		uvs[index] = centre_of[vertex_materials[index]]
	atlas = bake
	atlas_size = bake.size
	atlas_albedo = bake.albedo.get_data()
	atlas_orm = bake.orm.get_data()
	atlas_emission = bake.emission.get_data()
	return uvs
	surface_arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array()


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
	var field_started := Time.get_ticks_usec() if profile else 0
	var field := _union_field(occupancy)
	if profile:
		field_us += Time.get_ticks_usec() - field_started
	var cells_started := Time.get_ticks_usec() if profile else 0
	var corner_steps := PackedInt32Array()
	corner_steps.resize(8)
	for corner in 8:
		corner_steps[corner] = CORNER_STEPS[corner]
	for z in range(-MESH_PADDING, CHUNK_SIZE + 1):
		for y in range(-MESH_PADDING, CHUNK_SIZE + 1):
			for x in range(-MESH_PADDING, CHUNK_SIZE + 1):
				var origin := (x + SAMPLE_PADDING) + SAMPLE_SIZE * ((y + SAMPLE_PADDING) + SAMPLE_SIZE * (z + SAMPLE_PADDING))
				var bits := 0
				var cell_material := -1
				var cell_mixed := false
				for corner in 8:
					var sample := origin + corner_steps[corner]
					if occupancy[sample] == 0:
						continue
					bits |= 1 << corner
					var corner_material := material_ids[sample]
					if cell_material < 0:
						cell_material = corner_material
					elif corner_material != cell_material:
						cell_mixed = true
				if bits == 0 or bits == 255:
					continue
				var cell := Vector3i(x, y, z)
				var state_x := 0 if x <= 0 else (2 if x >= CHUNK_SIZE - 2 else 1)
				var state_y := 0 if y <= 0 else (2 if y >= CHUNK_SIZE - 2 else 1)
				var state_z := 0 if z <= 0 else (2 if z >= CHUNK_SIZE - 2 else 1)
				if owners[(state_x * 3 + state_y) * 3 + state_z] == 2:
					continue
				if _opposite_pairs[bits] != 0 and _append_antiprism(cell, bits, _case_triangles[bits], field, occupancy, material_ids, materials, positions, normals, vertex_colors, vertex_materials, indices):
					continue
				var loops: Array = _case_loops[bits]
				var loop_triangles: Array = _case_triangles[bits]
				for loop_index in loops.size():
					var loop: PackedInt32Array = loops[loop_index]
					var triangle_edges: PackedInt32Array = loop_triangles[loop_index]
					var loop_points: Array[Vector3] = []
					if loop.size() == 4:
						var loop_data := _loop_data(cell, loop, field, occupancy, material_ids)
						loop_points = loop_data["points"]
						if cell_mixed and _append_two_two_face_partition(cell, bits, loop, loop_data, occupancy, material_ids, materials, positions, normals, vertex_colors, vertex_materials, indices):
							continue
						if cell_mixed and _append_material_corner(cell, bits, loop, triangle_edges, loop_data, occupancy, material_ids, materials, positions, normals, vertex_colors, vertex_materials, indices):
							continue
						if loop_data["uniform"] and _quad_fan_ambiguous(loop_data):
							_append_quad_fan(cell, bits, loop, loop_data, materials, positions, normals, vertex_colors, vertex_materials, indices, false)
							continue
						var flat_diagonal := _canonical_flat_quad(loop, loop_data)
						if not flat_diagonal.is_empty():
							triangle_edges = flat_diagonal
						elif cell_mixed:
							var material_diagonal := _material_diagonal(loop, loop_data)
							if not material_diagonal.is_empty():
								triangle_edges = material_diagonal
					else:
						for edge: int in loop:
							loop_points.append(_field_point(cell, edge, field))
					var range_start := positions.size()
					for index in range(0, triangle_edges.size(), 3):
						var first_edge := triangle_edges[index]
						var second_edge := triangle_edges[index + 1]
						var third_edge := triangle_edges[index + 2]
						if _mirror_on_face(cell, first_edge, second_edge, third_edge, occupancy):
							continue
						var first_point := _loop_point(loop, loop_points, first_edge, cell, field)
						var second_point := _loop_point(loop, loop_points, second_edge, cell, field)
						var third_point := _loop_point(loop, loop_points, third_edge, cell, field)
						if cell_mixed:
							_edge_sample(cell, first_edge, occupancy, material_ids)
							var first_sample_site := _edge_site
							var first_sample_label := _edge_label
							_edge_sample(cell, second_edge, occupancy, material_ids)
							var second_sample_site := _edge_site
							var second_sample_label := _edge_label
							_edge_sample(cell, third_edge, occupancy, material_ids)
							var third_sample_site := _edge_site
							var third_sample_label := _edge_label
							_append_material_triangle(
								cell, bits,
								PackedVector3Array([first_point, second_point, third_point]),
								PackedInt32Array([first_sample_label, second_sample_label, third_sample_label]),
								PackedVector3Array([first_sample_site, second_sample_site, third_sample_site]),
								materials, positions, normals, vertex_colors, vertex_materials, indices
							)
							continue
						_append_oriented_triangle(
							cell, bits,
							first_point, second_point, third_point,
							cell_material, cell_material, cell_material,
							materials, positions, normals, vertex_colors, vertex_materials, indices
						)
					if cell_mixed and loop.size() == 4:
						_recolour_same_material_bridge(cell, loop, range_start, occupancy, material_ids, materials, vertex_colors, vertex_materials)
	if profile:
		cells_us += Time.get_ticks_usec() - cells_started
	return [positions, normals, vertex_colors, vertex_materials, indices]


func _recolour_same_material_bridge(cell: Vector3i, loop: PackedInt32Array, range_start: int, occupancy: PackedByteArray, material_ids: PackedInt32Array, materials: PackedFloat32Array, vertex_colors: PackedColorArray, vertex_materials: PackedInt32Array) -> void:
	var labels := PackedInt32Array()
	for edge: int in loop:
		_edge_sample(cell, edge, occupancy, material_ids)
		labels.append(_edge_label)
	var counts := {}
	for label: int in labels:
		counts[label] = counts.get(label, 0) + 1
	if counts.size() != 3:
		return
	var duplicate := -1
	for label: int in counts:
		if counts[label] == 2:
			duplicate = label
	if duplicate < 0:
		return
	var first := labels.find(duplicate)
	var second := labels.find(duplicate, first + 1)
	if (second - first) % 4 != 2:
		return
	var opposite := (first + 1) % 4
	var beyond := (first + 3) % 4
	var opposite_key := _material_values(labels[opposite], materials)
	var beyond_key := _material_values(labels[beyond], materials)
	var bridge := -1
	if _key_before(opposite_key, beyond_key):
		bridge = labels[beyond]
	elif _key_before(beyond_key, opposite_key):
		bridge = labels[opposite]
	else:
		return
	var base := duplicate * VoxelFrame.MATERIAL_STRIDE
	var colour := Color(materials[base], materials[base + 1], materials[base + 2], materials[base + 3])
	for index in range(range_start, vertex_materials.size()):
		if vertex_materials[index] != bridge:
			continue
		vertex_materials[index] = duplicate
		vertex_colors[index] = colour


static func _material_values(label: int, materials: PackedFloat32Array) -> PackedFloat32Array:
	var key := PackedFloat32Array()
	var base := label * VoxelFrame.MATERIAL_STRIDE
	for offset in VoxelFrame.MATERIAL_STRIDE:
		key.append(materials[base + offset])
	return key


func _loop_data(cell: Vector3i, loop: PackedInt32Array, field: PackedFloat32Array, occupancy: PackedByteArray, material_ids: PackedInt32Array) -> Dictionary:
	var points: Array[Vector3] = []
	var site_points: Array[Vector3] = []
	var sites: Array[Vector3i] = []
	var labels := PackedInt32Array()
	for edge: int in loop:
		points.append(_field_point(cell, edge, field))
	for edge: int in loop:
		_edge_sample(cell, edge, occupancy, material_ids)
		labels.append(_edge_label)
		site_points.append(_edge_site)
		sites.append(Vector3i(roundi(_edge_site.x), roundi(_edge_site.y), roundi(_edge_site.z)))
	var constant_axis := -1
	for axis in 3:
		if sites[0][axis] == sites[1][axis] and sites[0][axis] == sites[2][axis] and sites[0][axis] == sites[3][axis]:
			constant_axis = axis
			break
	var components := PackedInt32Array()
	var component_sizes := PackedInt32Array()
	var sums: Array = [-1, -1]
	var first_axis := -1
	var second_axis := -1
	var first_low := 0
	var second_low := 0
	if constant_axis >= 0:
		first_axis = (constant_axis + 1) % 3
		second_axis = (constant_axis + 2) % 3
		first_low = mini(mini(sites[0][first_axis], sites[1][first_axis]), mini(sites[2][first_axis], sites[3][first_axis])) - 1
		second_low = mini(mini(sites[0][second_axis], sites[1][second_axis]), mini(sites[2][second_axis], sites[3][second_axis])) - 1
		components = _quad_components(sites, constant_axis, first_axis, second_axis, first_low, second_low, occupancy, material_ids)
		if not components.is_empty():
			component_sizes.resize(16)
			component_sizes.fill(0)
			for value: int in components:
				if value >= 0:
					component_sizes[value] += 1
			var first_component := _component_at(sites[0], first_axis, second_axis, first_low, second_low, components)
			var second_component := _component_at(sites[1], first_axis, second_axis, first_low, second_low, components)
			var third_component := _component_at(sites[2], first_axis, second_axis, first_low, second_low, components)
			var fourth_component := _component_at(sites[3], first_axis, second_axis, first_low, second_low, components)
			if first_component >= 0 and second_component >= 0 and third_component >= 0 and fourth_component >= 0:
				sums = [component_sizes[first_component] + component_sizes[third_component], component_sizes[second_component] + component_sizes[fourth_component]]
	var uniform := labels[0] == labels[1] and labels[1] == labels[2] and labels[2] == labels[3]
	return {
		"points": points,
		"site_points": site_points,
		"sites": sites,
		"labels": labels,
		"components": components,
		"component_sizes": component_sizes,
		"sums": sums,
		"uniform": uniform,
	}


func _append_two_two_face_partition(cell: Vector3i, bits: int, loop: PackedInt32Array, loop_data: Dictionary, occupancy: PackedByteArray, material_ids: PackedInt32Array, materials: PackedFloat32Array, positions: PackedVector3Array, normals: PackedVector3Array, vertex_colors: PackedColorArray, vertex_materials: PackedInt32Array, indices: PackedInt32Array) -> bool:
	if loop.size() != 4:
		return false
	var points: Array[Vector3] = loop_data["points"]
	var labels: PackedInt32Array = loop_data["labels"]
	var counts := {}
	for label: int in labels:
		counts[label] = counts.get(label, 0) + 1
	if counts.size() != 2:
		return false
	for label: int in counts:
		if counts[label] != 2:
			return false
	var sites: Array[Vector3] = loop_data["site_points"]
	for index in 4:
		var next := (index + 1) % 4
		if labels[index] == labels[next]:
			return false
		var cut := _material_cut(points[index], sites[index], points[next], sites[next])
		var middle := (points[index] + points[next]) * 0.5
		if cut.distance_to(middle) > 0.001:
			return false
	var constant_axis := -1
	for axis in 3:
		if absf(points[0][axis] - points[1][axis]) < 0.001 and absf(points[0][axis] - points[2][axis]) < 0.001 and absf(points[0][axis] - points[3][axis]) < 0.001:
			constant_axis = axis
			break
	if constant_axis < 0:
		return false
	var first_axis := (constant_axis + 1) % 3
	var second_axis := (constant_axis + 2) % 3
	var first_low := INF
	var first_high := -INF
	var second_low := INF
	var second_high := -INF
	for point: Vector3 in points:
		first_low = minf(first_low, point[first_axis])
		first_high = maxf(first_high, point[first_axis])
		second_low = minf(second_low, point[second_axis])
		second_high = maxf(second_high, point[second_axis])
	if absf(first_high - first_low - 1.0) > 0.001 or absf(second_high - second_low - 1.0) > 0.001:
		return false
	var centre := (points[0] + points[1] + points[2] + points[3]) * 0.25
	var inside := _inside_gradient(bits, centre - Vector3(cell))
	if inside.length_squared() < 0.0000000001:
		return false
	var side := signi(roundi(inside[constant_axis] * 2.0))
	if side == 0:
		return false
	var corner_materials := PackedInt32Array()
	var behind: Array[Vector3i] = []
	for point: Vector3 in points:
		var behind_cell := Vector3i(roundi(point.x), roundi(point.y), roundi(point.z))
		behind_cell[constant_axis] = roundi(point[constant_axis] + side * 0.5)
		var sample := behind_cell + Vector3i.ONE * SAMPLE_PADDING
		if sample.x < 0 or sample.y < 0 or sample.z < 0 or sample.x >= SAMPLE_SIZE or sample.y >= SAMPLE_SIZE or sample.z >= SAMPLE_SIZE:
			return false
		var index := sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)
		if occupancy[index] == 0:
			return false
		for existing: Vector3i in behind:
			if existing == behind_cell:
				return false
		behind.append(behind_cell)
		corner_materials.append(material_ids[index])
	for index in 4:
		var point := points[index]
		var next := points[(index + 1) % 4]
		var previous := points[(index + 3) % 4]
		var next_middle := (point + next) * 0.5
		var previous_middle := (point + previous) * 0.5
		_append_oriented_triangle(cell, bits, point, next_middle, centre, corner_materials[index], corner_materials[index], corner_materials[index], materials, positions, normals, vertex_colors, vertex_materials, indices)
		_append_oriented_triangle(cell, bits, point, centre, previous_middle, corner_materials[index], corner_materials[index], corner_materials[index], materials, positions, normals, vertex_colors, vertex_materials, indices)
	return true


func _union_field(occupancy: PackedByteArray) -> PackedFloat32Array:
	var field := PackedFloat32Array()
	field.resize(FIELD_SIZE * FIELD_SIZE * FIELD_SIZE)
	field.fill(4.0)
	var distances := _field_distances
	var size := SAMPLE_SIZE
	var row_step := size
	var layer_step := size * size
	var field_row_step := FIELD_SIZE
	var field_layer_step := FIELD_SIZE * FIELD_SIZE
	var solid_count := 0
	for index in occupancy.size():
		solid_count += occupancy[index]
	var skip_interior := solid_count * 4 > occupancy.size()
	for z in size:
		for y in size:
			for x in size:
				var solid := x + size * (y + size * z)
				if occupancy[solid] == 0:
					continue
				var surface := true
				if skip_interior and x > 0 and y > 0 and z > 0 and x < size - 1 and y < size - 1 and z < size - 1:
					surface = false
					if occupancy[solid - 1] == 0 or occupancy[solid + 1] == 0:
						surface = true
					elif occupancy[solid - row_step] == 0 or occupancy[solid + row_step] == 0:
						surface = true
					elif occupancy[solid - layer_step] == 0 or occupancy[solid + layer_step] == 0:
						surface = true
					if not surface:
						for dz in range(-1, 2):
							for dy in range(-1, 2):
								for dx in range(-1, 2):
									if dx == 0 and dy == 0 and dz == 0:
										continue
									if occupancy[solid + dx + row_step * dy + layer_step * dz] == 0:
										surface = true
										break
								if surface:
									break
							if surface:
								break
				if not surface:
					continue
				var target := (x + FIELD_RADIUS) + FIELD_SIZE * ((y + FIELD_RADIUS) + FIELD_SIZE * (z + FIELD_RADIUS))
				var distance_index := 0
				for dz in FIELD_RADIUS * 2 + 1:
					var layer_base := target + (dz - FIELD_RADIUS) * field_layer_step - FIELD_RADIUS * field_row_step - FIELD_RADIUS
					for dy in FIELD_RADIUS * 2 + 1:
						var row_base := layer_base + dy * field_row_step
						for dx in FIELD_RADIUS * 2 + 1:
							var distance := distances[distance_index]
							distance_index += 1
							var slot := row_base + dx
							if distance < field[slot]:
								field[slot] = distance
	return field


static func _field_distance(offset_x: int, offset_y: int, offset_z: int) -> float:
	var qx := absf(offset_x) - 0.5
	var qy := absf(offset_y) - 0.5
	var qz := absf(offset_z) - 0.5
	var outside_x := maxf(qx, 0.0)
	var outside_y := maxf(qy, 0.0)
	var outside_z := maxf(qz, 0.0)
	return sqrt(outside_x * outside_x + outside_y * outside_y + outside_z * outside_z) + minf(maxf(qx, maxf(qy, qz)), 0.0)


static func _field_point(cell: Vector3i, edge: int, field: PackedFloat32Array) -> Vector3:
	if edge >= EDGE_CORNERS.size():
		return _edge_point(cell, edge)
	var corners: Array = EDGE_CORNERS[edge]
	var first: Vector3i = CORNER_OFFSETS[corners[0]]
	var second: Vector3i = CORNER_OFFSETS[corners[1]]
	var origin := (cell.x + FIELD_PADDING) + FIELD_SIZE * ((cell.y + FIELD_PADDING) + FIELD_SIZE * (cell.z + FIELD_PADDING))
	var first_index: int = origin + FIELD_CORNER_STEPS[corners[0]]
	var second_index: int = origin + FIELD_CORNER_STEPS[corners[1]]
	var first_value := field[first_index]
	var second_value := field[second_index]
	var difference := first_value - second_value
	var t := 0.5
	if absf(difference) > 0.0001:
		t = clampf(first_value / difference, 0.02, 0.98)
	return Vector3(cell) + Vector3(first) + Vector3(second - first) * t


static func _loop_point(loop: PackedInt32Array, points: Array[Vector3], edge: int, cell: Vector3i, field: PackedFloat32Array) -> Vector3:
	for index in loop.size():
		if loop[index] == edge:
			return points[index]
	return _field_point(cell, edge, field)


func _append_material_corner(cell: Vector3i, bits: int, loop: PackedInt32Array, triangle_edges: PackedInt32Array, loop_data: Dictionary, occupancy: PackedByteArray, material_ids: PackedInt32Array, materials: PackedFloat32Array, positions: PackedVector3Array, normals: PackedVector3Array, vertex_colors: PackedColorArray, vertex_materials: PackedInt32Array, indices: PackedInt32Array) -> bool:
	if loop.size() != 4 or triangle_edges.size() != 6:
		return false
	var labels: PackedInt32Array = loop_data["labels"]
	var counts := {}
	for label: int in labels:
		counts[label] = counts.get(label, 0) + 1
	if counts.size() != 2:
		return false
	var points: Array[Vector3] = loop_data["points"]
	var sites: Array[Vector3] = loop_data["site_points"]
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
		if _first_diagonal_wins(first_cut, points[first], points[last], last_cut, reference):
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


static func _first_diagonal_wins(first_cut: Vector3, first: Vector3, last: Vector3, last_cut: Vector3, reference: Vector3) -> bool:
	var first_diagonal := first_cut.distance_squared_to(last)
	var second_diagonal := first.distance_squared_to(last_cut)
	if first_diagonal != second_diagonal:
		return first_diagonal < second_diagonal
	var first_dot := absf((first_cut - last).dot(reference))
	var second_dot := absf((first - last_cut).dot(reference))
	if absf(first_dot - second_dot) > 0.000001:
		return first_dot < second_dot
	return true


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
	var second_weight := (point - points[0]).cross(points[2] - points[0]).dot(normal) / squared
	var third_weight := (points[1] - points[0]).cross(point - points[0]).dot(normal) / squared
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


func _position_ids(positions: PackedVector3Array) -> PackedInt32Array:
	var ids := PackedInt32Array()
	ids.resize(positions.size())
	var known := {}
	for vertex in positions.size():
		var key := _position_key(positions[vertex])
		if known.has(key):
			ids[vertex] = known[key]
		else:
			ids[vertex] = known.size()
			known[key] = ids[vertex]
	return ids


func _drop_degenerate_triangles(ids: PackedInt32Array, indices: PackedInt32Array) -> PackedInt32Array:
	var kept := PackedInt32Array()
	for triangle in range(0, indices.size(), 3):
		var first := ids[indices[triangle]]
		var second := ids[indices[triangle + 1]]
		var third := ids[indices[triangle + 2]]
		if first == second or second == third or first == third:
			continue
		kept.append(indices[triangle])
		kept.append(indices[triangle + 1])
		kept.append(indices[triangle + 2])
	return kept


func _rebuild_flat_normals(positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, materials: PackedInt32Array, indices: PackedInt32Array, occupancy: PackedByteArray, smooth := false) -> Array:
	var new_positions := PackedVector3Array()
	var new_normals := PackedVector3Array()
	var new_colors := PackedColorArray()
	var new_materials := PackedInt32Array()
	var new_indices := PackedInt32Array()
	var face_normals := PackedVector3Array()
	var smooth_normals := {}
	if smooth and not indices.is_empty():
		face_normals.resize(indices.size() / 3)
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
			face_normals[triangle / 3] = normal
			var area := winding.length()
			for point: Vector3 in [first, second, third]:
				var key := _position_key(point)
				smooth_normals[key] = smooth_normals.get(key, Vector3.ZERO) + normal * area
	for triangle in range(0, indices.size(), 3):
		var first := positions[indices[triangle]]
		var second := positions[indices[triangle + 1]]
		var third := positions[indices[triangle + 2]]
		var normal := normals[indices[triangle]]
		if smooth:
			normal = face_normals[triangle / 3]
		else:
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
		var first_normal := normal
		var second_normal := normal
		var third_normal := normal
		if smooth:
			first_normal = smooth_normals.get(_position_key(first), Vector3.ZERO)
			second_normal = smooth_normals.get(_position_key(second), Vector3.ZERO)
			third_normal = smooth_normals.get(_position_key(third), Vector3.ZERO)
			first_normal = first_normal.normalized() if first_normal.length_squared() > 0.0000000001 else normal
			second_normal = second_normal.normalized() if second_normal.length_squared() > 0.0000000001 else normal
			third_normal = third_normal.normalized() if third_normal.length_squared() > 0.0000000001 else normal
		new_normals.append(first_normal)
		new_normals.append(second_normal)
		new_normals.append(third_normal)
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


func _drop_opposite_duplicate_triangles(positions: PackedVector3Array, ids: PackedInt32Array, indices: PackedInt32Array) -> PackedInt32Array:
	var groups := {}
	var triangle_count := indices.size() / 3
	for triangle in triangle_count:
		var first := ids[indices[triangle * 3]]
		var second := ids[indices[triangle * 3 + 1]]
		var third := ids[indices[triangle * 3 + 2]]
		if first > second:
			var swap := first
			first = second
			second = swap
		if second > third:
			var swap := second
			second = third
			third = swap
		if first > second:
			var swap := first
			first = second
			second = swap
		var key := (first << 42) | (second << 21) | third
		if groups.has(key):
			var list: Array = groups[key]
			list.append(triangle)
		else:
			groups[key] = [triangle]
	var removed := PackedByteArray()
	removed.resize(triangle_count)
	for list: Array in groups.values():
		if list.size() < 2:
			continue
		var head: int = list[0]
		var head_normal := _triangle_normal(positions, indices, head * 3)
		for index in range(1, list.size()):
			var other: int = list[index]
			if head_normal.dot(_triangle_normal(positions, indices, other * 3)) < 0.0:
				removed[head] = 1
				removed[other] = 1
			else:
				removed[other] = 1
	var kept := PackedInt32Array()
	for triangle in triangle_count:
		if removed[triangle] != 0:
			continue
		kept.append(indices[triangle * 3])
		kept.append(indices[triangle * 3 + 1])
		kept.append(indices[triangle * 3 + 2])
	return kept


func _merge_coplanar_fans(positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, materials: PackedInt32Array, indices: PackedInt32Array) -> Array:
	if indices.is_empty():
		return [positions, normals, colors, indices, materials]
	var triangles := indices.duplicate()
	var triangle_count := triangles.size() / 3
	var triangle_normals := PackedVector3Array()
	triangle_normals.resize(triangle_count)
	var triangle_keys := PackedInt32Array()
	triangle_keys.resize(triangle_count * 3)
	var triangle_materials := PackedInt32Array()
	triangle_materials.resize(triangle_count)
	for triangle in triangle_count:
		_cache_merge_triangle(triangle, triangles, positions, materials, triangle_normals, triangle_keys, triangle_materials)
	var vertex_triangles := {}
	for triangle in triangle_count:
		_register_merge_triangle(triangle, triangles, vertex_triangles)
	_merge_next.resize(positions.size())
	_merge_next_stamp.resize(positions.size())
	_merge_previous_stamp.resize(positions.size())
	var removed := {}
	var merged := PackedByteArray()
	merged.resize(positions.size())
	var queue: Array[int] = []
	for vertex in positions.size():
		if vertex_triangles.has(vertex):
			var incident: Array = vertex_triangles[vertex]
			if incident.size() >= 3:
				queue.append(vertex)
	var queued := PackedByteArray()
	queued.resize(positions.size())
	for vertex in queue:
		queued[vertex] = 1
	while not queue.is_empty():
		var vertex: int = queue.pop_back()
		queued[vertex] = 0
		if merged[vertex] != 0:
			continue
		if not vertex_triangles.has(vertex):
			continue
		var incident: Array = vertex_triangles[vertex]
		if incident.size() < 3:
			continue
		var cycle: Array = _merge_coplanar_vertex(vertex, triangles, positions, normals, materials, triangle_normals, triangle_keys, triangle_materials, incident, vertex_triangles, removed)
		if cycle.is_empty():
			continue
		merged[vertex] = 1
		for link_vertex: int in cycle:
			if queued[link_vertex] == 0:
				queued[link_vertex] = 1
				queue.append(link_vertex)
	if removed.is_empty():
		return [positions, normals, colors, indices, materials]
	return _compact_mesh(positions, normals, colors, materials, triangles, removed)


func _compact_mesh(positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, materials: PackedInt32Array, triangles: PackedInt32Array, removed: Dictionary) -> Array:
	var kept := PackedInt32Array()
	for triangle in triangles.size() / 3:
		if removed.has(triangle):
			continue
		kept.append(triangles[triangle * 3])
		kept.append(triangles[triangle * 3 + 1])
		kept.append(triangles[triangle * 3 + 2])
	var vertex_map := {}
	var merged_positions := PackedVector3Array()
	var merged_normals := PackedVector3Array()
	var merged_colors := PackedColorArray()
	var merged_materials := PackedInt32Array()
	for vertex: int in kept:
		if vertex_map.has(vertex):
			continue
		vertex_map[vertex] = merged_positions.size()
		merged_positions.append(positions[vertex])
		merged_normals.append(normals[vertex])
		merged_colors.append(colors[vertex])
		merged_materials.append(materials[vertex])
	var merged_indices := PackedInt32Array()
	merged_indices.resize(kept.size())
	for index in kept.size():
		merged_indices[index] = vertex_map[kept[index]]
	return [merged_positions, merged_normals, merged_colors, merged_indices, merged_materials]


func _cache_merge_triangle(triangle: int, triangles: PackedInt32Array, positions: PackedVector3Array, materials: PackedInt32Array, triangle_normals: PackedVector3Array, triangle_keys: PackedInt32Array, triangle_materials: PackedInt32Array) -> void:
	var base := triangle * 3
	var first := positions[triangles[base]]
	var normal := (positions[triangles[base + 1]] - first).cross(positions[triangles[base + 2]] - first)
	triangle_materials[triangle] = materials[triangles[base]]
	if normal.length_squared() < 0.0000000001:
		triangle_keys[base] = DEGENERATE_NORMAL_KEY
		triangle_keys[base + 1] = 0
		triangle_keys[base + 2] = 0
		return
	normal = -normal.normalized()
	triangle_normals[triangle] = normal
	triangle_keys[base] = roundi(normal.x * 1024.0)
	triangle_keys[base + 1] = roundi(normal.y * 1024.0)
	triangle_keys[base + 2] = roundi(normal.z * 1024.0)


func _register_merge_triangle(triangle: int, triangles: PackedInt32Array, vertex_triangles: Dictionary) -> void:
	var base := triangle * 3
	for corner in 3:
		var vertex := triangles[base + corner]
		if vertex_triangles.has(vertex):
			var incident: Array = vertex_triangles[vertex]
			incident.append(triangle)
		else:
			vertex_triangles[vertex] = [triangle]


func _unregister_merge_triangle(triangle: int, triangles: PackedInt32Array, vertex_triangles: Dictionary) -> void:
	var base := triangle * 3
	for corner in 3:
		var vertex := triangles[base + corner]
		if not vertex_triangles.has(vertex):
			continue
		var incident: Array = vertex_triangles[vertex]
		incident.erase(triangle)


func _merge_coplanar_vertex(vertex: int, triangles: PackedInt32Array, positions: PackedVector3Array, normals: PackedVector3Array, materials: PackedInt32Array, triangle_normals: PackedVector3Array, triangle_keys: PackedInt32Array, triangle_materials: PackedInt32Array, incident: Array, vertex_triangles: Dictionary, removed: Dictionary) -> Array:
	var incident_count := incident.size()
	var first_index: int = incident[0]
	var first_base := first_index * 3
	if triangle_keys[first_base] == DEGENERATE_NORMAL_KEY:
		return []
	var normal_key_x := triangle_keys[first_base]
	var normal_key_y := triangle_keys[first_base + 1]
	var normal_key_z := triangle_keys[first_base + 2]
	var material := triangle_materials[first_index]
	for triangle_index: int in incident:
		if triangle_materials[triangle_index] != material:
			return []
		var key_base := triangle_index * 3
		if triangle_keys[key_base] != normal_key_x or triangle_keys[key_base + 1] != normal_key_y or triangle_keys[key_base + 2] != normal_key_z:
			return []
	var first_normal := triangle_normals[first_index]
	_merge_stamp += 1
	var stamp := _merge_stamp
	var next_of := _merge_next
	var next_stamp := _merge_next_stamp
	var previous_stamp := _merge_previous_stamp
	var start := -1
	var links := 0
	for triangle_index: int in incident:
		var base := triangle_index * 3
		var corner := -1
		if triangles[base] == vertex:
			corner = 0
		elif triangles[base + 1] == vertex:
			corner = 1
		elif triangles[base + 2] == vertex:
			corner = 2
		else:
			return []
		var first := triangles[base + (corner + 1) % 3]
		var second := triangles[base + (corner + 2) % 3]
		if next_stamp[first] == stamp or previous_stamp[second] == stamp:
			return []
		if start < 0:
			start = first
		next_of[first] = second
		next_stamp[first] = stamp
		previous_stamp[second] = stamp
		links += 1
	if links != incident_count:
		return []
	var cycle: Array[int] = [start]
	var current: int = next_of[start]
	while current != start:
		if cycle.size() > links or next_stamp[current] != stamp:
			return []
		cycle.append(current)
		current = next_of[current]
	if cycle.size() != links:
		return []
	var shading_normal := normals[vertex]
	var shading_key := Vector3i(roundi(shading_normal.x * 1024.0), roundi(shading_normal.y * 1024.0), roundi(shading_normal.z * 1024.0))
	for link_vertex: int in cycle:
		var link_normal := normals[link_vertex]
		if Vector3i(roundi(link_normal.x * 1024.0), roundi(link_normal.y * 1024.0), roundi(link_normal.z * 1024.0)) != shading_key:
			return []
	var orientation := 0
	for index in cycle.size():
		var first := positions[cycle[index]]
		var second := positions[cycle[(index + 1) % cycle.size()]]
		var third := positions[cycle[(index + 2) % cycle.size()]]
		var turn := (second - first).cross(third - second).dot(first_normal)
		if absf(turn) < 0.000001:
			return []
		var direction := 1 if turn > 0.0 else -1
		if orientation == 0:
			orientation = direction
		elif orientation != direction:
			return []
	var first_point := positions[cycle[0]]
	var second_point := positions[cycle[1]]
	var third_point := positions[cycle[2]]
	if (second_point - first_point).cross(third_point - first_point).dot(first_normal) > 0.0:
		cycle.reverse()
	var added: Array[PackedInt32Array] = []
	for index in range(1, cycle.size() - 1):
		var triangle := PackedInt32Array([cycle[0], cycle[index], cycle[index + 1]])
		var first := positions[triangle[0]]
		var second := positions[triangle[1]]
		var third := positions[triangle[2]]
		if (second - first).cross(third - first).dot(first_normal) >= 0.0:
			return []
		added.append(triangle)
	for triangle_index: int in incident.duplicate():
		removed[triangle_index] = true
		_unregister_merge_triangle(triangle_index, triangles, vertex_triangles)
	for triangle: PackedInt32Array in added:
		var triangle_index := triangles.size() / 3
		triangles.append(triangle[0])
		triangles.append(triangle[1])
		triangles.append(triangle[2])
		var first := positions[triangle[0]]
		var normal := (positions[triangle[1]] - first).cross(positions[triangle[2]] - first)
		triangle_materials.append(materials[triangle[0]])
		if normal.length_squared() < 0.0000000001:
			triangle_keys.append(DEGENERATE_NORMAL_KEY)
			triangle_keys.append(0)
			triangle_keys.append(0)
			triangle_normals.append(Vector3.ZERO)
		else:
			normal = -normal.normalized()
			triangle_normals.append(normal)
			triangle_keys.append(roundi(normal.x * 1024.0))
			triangle_keys.append(roundi(normal.y * 1024.0))
			triangle_keys.append(roundi(normal.z * 1024.0))
		_register_merge_triangle(triangle_index, triangles, vertex_triangles)
	return cycle


func dissolve_surface(positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, materials: PackedInt32Array, indices: PackedInt32Array) -> Array:
	return _dissolve_smooth_vertices(positions, normals, colors, materials, indices)


func _dissolve_smooth_vertices(positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, materials: PackedInt32Array, indices: PackedInt32Array) -> Array:
	if indices.is_empty():
		return [positions, normals, colors, indices, materials]
	var triangle_count := indices.size() / 3
	var triangle_normals := PackedVector3Array()
	triangle_normals.resize(triangle_count)
	for triangle in triangle_count:
		var base := triangle * 3
		var first := positions[indices[base]]
		var winding := (positions[indices[base + 1]] - first).cross(positions[indices[base + 2]] - first)
		if winding.length_squared() < 0.0000000001:
			continue
		triangle_normals[triangle] = -winding.normalized()
	var seam := _dissolve_seam_vertices(positions, triangle_normals, indices)
	var triangles := indices.duplicate()
	var vertex_triangles := {}
	for triangle in triangle_count:
		_register_merge_triangle(triangle, triangles, vertex_triangles)
	var removed := PackedByteArray()
	removed.resize(triangle_count + 64)
	var dirty := PackedByteArray()
	dirty.resize(positions.size())
	_dissolve_next.resize(positions.size())
	_dissolve_next_stamp.resize(positions.size())
	_dissolve_previous_stamp.resize(positions.size())
	var queue: Array[int] = []
	var queued := PackedByteArray()
	queued.resize(positions.size())
	for vertex in positions.size():
		if seam[vertex] != 0:
			continue
		if not vertex_triangles.has(vertex):
			continue
		var incident: Array = vertex_triangles[vertex]
		if incident.size() >= 3 and incident.size() <= dissolve_link_limit:
			queue.append(vertex)
			queued[vertex] = 1
	var dissolved := 0
	while not queue.is_empty():
		var vertex: int = queue.pop_back()
		queued[vertex] = 0
		if seam[vertex] != 0:
			continue
		var incident: Array = vertex_triangles[vertex]
		if dirty[vertex] != 0:
			dirty[vertex] = 0
			var write := 0
			for read in incident.size():
				var triangle_index: int = incident[read]
				if removed[triangle_index] == 0:
					incident[write] = triangle_index
					write += 1
			if write != incident.size():
				incident.resize(write)
		if incident.size() < 3:
			continue
		var added := _dissolve_vertex(vertex, triangles, positions, normals, colors, materials, triangle_normals, vertex_triangles, removed)
		if added.is_empty():
			continue
		for triangle_index: int in incident:
			removed[triangle_index] = 1
		dissolved += 1
		var first_triangle := triangles.size() / 3
		triangles.append_array(added)
		if removed.size() < triangles.size() / 3:
			removed.resize(triangles.size() / 3 + 64)
		for index in range(0, added.size(), 3):
			var triangle_index := first_triangle + index / 3
			for corner in 3:
				var link_vertex := added[index + corner]
				dirty[link_vertex] = 1
				var link_incident: Array = vertex_triangles[link_vertex]
				link_incident.append(triangle_index)
				vertex_triangles[link_vertex] = link_incident
				if queued[link_vertex] != 0:
					continue
				if seam[link_vertex] != 0:
					continue
				if link_incident.size() >= 3 and link_incident.size() <= dissolve_link_limit:
					queue.append(link_vertex)
					queued[link_vertex] = 1
	if dissolved == 0:
		return [positions, normals, colors, indices, materials]
	var removed_triangles := {}
	for triangle in triangles.size() / 3:
		if removed[triangle] != 0:
			removed_triangles[triangle] = true
	return _compact_mesh(positions, normals, colors, materials, triangles, removed_triangles)


func _dissolve_seam_vertices(positions: PackedVector3Array, triangle_normals: PackedVector3Array, indices: PackedInt32Array) -> PackedByteArray:
	var seam := PackedByteArray()
	seam.resize(positions.size())
	var edges := {}
	for triangle in indices.size() / 3:
		var base := triangle * 3
		for corner in 3:
			var first := indices[base + corner]
			var second := indices[base + (corner + 1) % 3]
			if first == second:
				continue
			var low := first if first < second else second
			var high := second if first < second else first
			var key := (low << 32) | high
			if not edges.has(key):
				edges[key] = triangle
				continue
			var other: int = edges[key]
			if other < 0:
				seam[low] = 1
				seam[high] = 1
				continue
			if triangle_normals[other].dot(triangle_normals[triangle]) < DISSOLVE_CREASE_COSINE:
				seam[low] = 1
				seam[high] = 1
			edges[key] = -1
	for key: int in edges:
		if edges[key] >= 0:
			seam[key >> 32] = 1
			seam[key & 0xFFFFFFFF] = 1
	var known := {}
	for index in positions.size():
		var key := _position_key(positions[index])
		if known.has(key):
			seam[index] = 1
			seam[known[key]] = 1
		else:
			known[key] = index
	_dissolve_edge_set = edges
	return seam


static func _dissolve_edge_key(first: int, second: int) -> int:
	return (first << 32) | second if first < second else (second << 32) | first


func _dissolve_vertex(vertex: int, triangles: PackedInt32Array, positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, materials: PackedInt32Array, triangle_normals: PackedVector3Array, vertex_triangles: Dictionary, removed: PackedByteArray) -> PackedInt32Array:
	var incident: Array = vertex_triangles[vertex]
	var count := incident.size()
	if count < 3 or count > dissolve_link_limit:
		return PackedInt32Array()
	var material := materials[vertex]
	for triangle_index: int in incident:
		var base := triangle_index * 3
		if materials[triangles[base]] != material or materials[triangles[base + 1]] != material or materials[triangles[base + 2]] != material:
			return PackedInt32Array()
	_dissolve_stamp += 1
	var stamp := _dissolve_stamp
	var next_of := _dissolve_next
	var next_stamp := _dissolve_next_stamp
	var previous_stamp := _dissolve_previous_stamp
	var start := -1
	var links := 0
	for triangle_index: int in incident:
		var base := triangle_index * 3
		var corner := -1
		if triangles[base] == vertex:
			corner = 0
		elif triangles[base + 1] == vertex:
			corner = 1
		elif triangles[base + 2] == vertex:
			corner = 2
		else:
			return PackedInt32Array()
		var first := triangles[base + (corner + 1) % 3]
		var second := triangles[base + (corner + 2) % 3]
		if first == second:
			return PackedInt32Array()
		if next_stamp[first] == stamp or previous_stamp[second] == stamp:
			return PackedInt32Array()
		if start < 0:
			start = first
		next_of[first] = second
		next_stamp[first] = stamp
		previous_stamp[second] = stamp
		links += 1
	if links != count:
		return PackedInt32Array()
	var cycle := PackedInt32Array()
	cycle.resize(count)
	cycle[0] = start
	var current := next_of[start]
	var filled := 1
	while current != start:
		if filled >= count or next_stamp[current] != stamp:
			return PackedInt32Array()
		cycle[filled] = current
		filled += 1
		current = next_of[current]
	if filled != count:
		return PackedInt32Array()
	var outward := Vector3.ZERO
	for triangle_index: int in incident:
		var base := triangle_index * 3
		var first := positions[triangles[base]]
		outward -= (positions[triangles[base + 1]] - first).cross(positions[triangles[base + 2]] - first)
	if outward.length_squared() < 0.0000000001:
		return PackedInt32Array()
	_dissolve_outward = outward.normalized()
	var removed_position := positions[vertex]
	var offset := 0.0
	for index in count:
		offset = maxf(offset, absf((positions[cycle[index]] - removed_position).dot(_dissolve_outward)))
	if offset > DISSOLVE_PLANAR_LIMIT:
		return PackedInt32Array()
	var axis := Vector3.RIGHT
	if absf(_dissolve_outward.y) <= absf(_dissolve_outward.x) and absf(_dissolve_outward.y) <= absf(_dissolve_outward.z):
		axis = Vector3.UP
	elif absf(_dissolve_outward.z) <= absf(_dissolve_outward.x):
		axis = Vector3.FORWARD
	var across := _dissolve_outward.cross(axis)
	if across.length_squared() < 0.0000000001:
		return PackedInt32Array()
	across = across.normalized()
	var down := _dissolve_outward.cross(across)
	if _dissolve_points.size() < dissolve_link_limit:
		_dissolve_points.resize(dissolve_link_limit)
		_dissolve_normals.resize(dissolve_link_limit)
		_dissolve_colours.resize(dissolve_link_limit)
		_dissolve_flat.resize(dissolve_link_limit)
	for index in count:
		var point := positions[cycle[index]]
		_dissolve_points[index] = point
		_dissolve_normals[index] = normals[cycle[index]]
		_dissolve_colours[index] = colors[cycle[index]]
		_dissolve_flat[index] = Vector2(point.dot(across), point.dot(down))
	_dissolve_flat_point = Vector2(removed_position.dot(across), removed_position.dot(down))
	var area := 0.0
	for index in count:
		area += _dissolve_flat[index].cross(_dissolve_flat[(index + 1) % count])
	if absf(area) < DISSOLVE_AREA_LIMIT * 4.0:
		return PackedInt32Array()
	if area < 0.0:
		for index in count:
			_dissolve_flat[index] = Vector2(_dissolve_flat[index].x, -_dissolve_flat[index].y)
		_dissolve_flat_point = Vector2(_dissolve_flat_point.x, -_dissolve_flat_point.y)
	_dissolve_removed_normal = normals[vertex]
	_dissolve_removed_colour = colors[vertex]
	_dissolve_removed_position = removed_position
	var list := _dissolve_triangulate(count)
	if list.is_empty():
		return PackedInt32Array()
	var diagonal_keys := PackedInt64Array()
	for index in range(0, list.size(), 3):
		for corner in 3:
			var first := list[index + corner]
			var second := list[index + (corner + 1) % 3]
			var step := (second - first + count) % count
			if step == 1 or step == count - 1:
				continue
			var key := _dissolve_edge_key(cycle[first], cycle[second])
			if diagonal_keys.has(key):
				continue
			if _dissolve_edge_set.has(key):
				return PackedInt32Array()
			diagonal_keys.append(key)
	var covered := false
	for index in range(0, list.size(), 3):
		if not _dissolve_triangle_check(list[index], list[index + 1], list[index + 2]):
			return PackedInt32Array()
		if _triangle_covers:
			covered = true
	if not covered:
		return PackedInt32Array()
	for key: int in diagonal_keys:
		_dissolve_edge_set[key] = true
	var added := PackedInt32Array()
	added.resize(list.size())
	for index in list.size():
		added[index] = cycle[list[index]]
	return added


func _dissolve_triangulate(count: int) -> PackedInt32Array:
	if count <= 3:
		if not _dissolve_shape(0, 1, 2):
			return PackedInt32Array()
		return PackedInt32Array([0, 1, 2])
	for index in count:
		var first := _dissolve_flat[index]
		var second := _dissolve_flat[(index + 1) % count]
		var third := _dissolve_flat[(index + 2) % count]
		if (second - first).cross(third - second) <= 0.0:
			return _dissolve_ear_triangulation(count)
	var first := -1
	var second := -1
	var third := -1
	var first_distance := INF
	var second_distance := INF
	var third_distance := INF
	for index in count:
		var distance := _dissolve_flat[index].distance_squared_to(_dissolve_flat_point)
		if distance < first_distance:
			third = second
			third_distance = second_distance
			second = first
			second_distance = first_distance
			first = index
			first_distance = distance
		elif distance < second_distance:
			third = second
			third_distance = second_distance
			second = index
			second_distance = distance
		elif distance < third_distance:
			third = index
			third_distance = distance
	var best_apex := -1
	var best_spread := INF
	var best_quality := -1.0
	for apex: int in [first, second, third]:
		if apex < 0:
			continue
		var spread := 0.0
		var quality := 1.0
		var valid := true
		for step in range(1, count - 1):
			if not _dissolve_shape(apex, (apex + step) % count, (apex + step + 1) % count):
				valid = false
				break
			spread = maxf(spread, _triangle_spread)
			quality = minf(quality, _triangle_quality)
		if not valid:
			continue
		if spread < best_spread - 0.0000001 or (spread < best_spread + 0.0000001 and quality > best_quality + 0.0000001):
			best_spread = spread
			best_quality = quality
			best_apex = apex
	if best_apex < 0:
		return _dissolve_ear_triangulation(count)
	var list := PackedInt32Array()
	list.resize((count - 2) * 3)
	var cursor := 0
	for step in range(1, count - 1):
		list[cursor] = best_apex
		list[cursor + 1] = (best_apex + step) % count
		list[cursor + 2] = (best_apex + step + 1) % count
		cursor += 3
	return list


func _dissolve_ear_triangulation(count: int) -> PackedInt32Array:
	var remaining := PackedInt32Array()
	remaining.resize(count)
	for index in count:
		remaining[index] = index
	var list := PackedInt32Array()
	while remaining.size() > 3:
		var size := remaining.size()
		var chosen := -1
		var tried := PackedByteArray()
		tried.resize(size)
		while chosen < 0:
			var best_position := -1
			var best_spread := INF
			var best_quality := -1.0
			for position in size:
				if tried[position] != 0:
					continue
				if not _dissolve_shape(remaining[(position + size - 1) % size], remaining[position], remaining[(position + 1) % size]):
					tried[position] = 1
					continue
				var spread := _triangle_spread
				var quality := _triangle_quality
				if size == 4:
					var tail_first := remaining[(position + 1) % size]
					var tail_second := remaining[(position + 2) % size]
					var tail_last := remaining[(position + 3) % size]
					if not _dissolve_shape(tail_first, tail_second, tail_last):
						tried[position] = 1
						continue
				if spread < best_spread - 0.0000001 or (spread < best_spread + 0.0000001 and quality > best_quality + 0.0000001):
					best_spread = spread
					best_quality = quality
					best_position = position
			if best_position < 0:
				return PackedInt32Array()
			if not _dissolve_ear_clear(best_position, remaining):
				tried[best_position] = 1
				continue
			chosen = best_position
		list.append(remaining[(chosen + size - 1) % size])
		list.append(remaining[chosen])
		list.append(remaining[(chosen + 1) % size])
		remaining.remove_at(chosen)
	if not _dissolve_shape(remaining[0], remaining[1], remaining[2]):
		return PackedInt32Array()
	list.append(remaining[0])
	list.append(remaining[1])
	list.append(remaining[2])
	return list


func _dissolve_ear_clear(position: int, remaining: PackedInt32Array) -> bool:
	var size := remaining.size()
	var a := _dissolve_flat[remaining[(position + size - 1) % size]]
	var b := _dissolve_flat[remaining[position]]
	var c := _dissolve_flat[remaining[(position + 1) % size]]
	for index in size:
		if index == position or index == (position + size - 1) % size or index == (position + 1) % size:
			continue
		var point := _dissolve_flat[remaining[index]]
		if (b - a).cross(point - a) > 0.0 and (c - b).cross(point - b) > 0.0 and (a - c).cross(point - c) > 0.0:
			return false
	return true


func _dissolve_shape(first: int, middle: int, last: int) -> bool:
	var a := _dissolve_flat[first]
	var b := _dissolve_flat[middle]
	var c := _dissolve_flat[last]
	var area := (b - a).cross(c - a)
	if area <= DISSOLVE_AREA_LIMIT:
		return false
	var shape := area / (a.distance_squared_to(b) + b.distance_squared_to(c) + c.distance_squared_to(a))
	if shape < DISSOLVE_QUALITY_LIMIT:
		return false
	var offset := _dissolve_flat_point - a
	var flat_middle := offset.cross(c - a) / area
	var flat_last := (b - a).cross(offset) / area
	var flat_first := 1.0 - flat_middle - flat_last
	if flat_first > -0.001 and flat_middle > -0.001 and flat_last > -0.001:
		var point_a := _dissolve_points[first]
		var point_b := _dissolve_points[middle]
		var point_c := _dissolve_points[last]
		var winding := (point_b - point_a).cross(point_c - point_a)
		var squared := winding.length_squared()
		if squared < 0.0000000000000001:
			return false
		var side := _dissolve_removed_position - point_a
		var weight_middle := clampf((point_c - point_a).cross(side).dot(winding) / squared, 0.0, 1.0)
		var weight_last := clampf((point_b - point_a).cross(side).dot(winding) / squared, 0.0, 1.0)
		var weight_first := clampf(1.0 - weight_middle - weight_last, 0.0, 1.0)
		var total := weight_first + weight_middle + weight_last
		if total <= 0.0:
			return false
		var inverse := 1.0 / total
		weight_first *= inverse
		weight_middle *= inverse
		weight_last *= inverse
		var normal_a := _dissolve_normals[first]
		var normal_b := _dissolve_normals[middle]
		var normal_c := _dissolve_normals[last]
		var blended := normal_a * weight_first + normal_b * weight_middle + normal_c * weight_last
		if blended.length_squared() < 0.0000000001:
			return false
		if blended.normalized().dot(_dissolve_removed_normal) < DISSOLVE_NORMAL_COSINE:
			return false
		var colour := _dissolve_colours[first] * weight_first + _dissolve_colours[middle] * weight_middle + _dissolve_colours[last] * weight_last
		if absf(colour.r - _dissolve_removed_colour.r) > DISSOLVE_COLOUR_LIMIT or absf(colour.g - _dissolve_removed_colour.g) > DISSOLVE_COLOUR_LIMIT or absf(colour.b - _dissolve_removed_colour.b) > DISSOLVE_COLOUR_LIMIT:
			return false
	var normal_first := _dissolve_normals[first]
	var normal_second := _dissolve_normals[middle]
	var normal_third := _dissolve_normals[last]
	var spread := 2.0 - 2.0 * normal_first.dot(normal_second)
	spread = maxf(spread, 2.0 - 2.0 * normal_second.dot(normal_third))
	spread = maxf(spread, 2.0 - 2.0 * normal_third.dot(normal_first))
	_triangle_spread = spread
	_triangle_quality = shape
	return true


func _dissolve_triangle_check(first: int, middle: int, last: int) -> bool:
	var point_a := _dissolve_points[first]
	var point_b := _dissolve_points[middle]
	var point_c := _dissolve_points[last]
	var winding := (point_b - point_a).cross(point_c - point_a)
	if winding.dot(_dissolve_outward) >= 0.0:
		return false
	var squared := winding.length_squared()
	if squared < 0.0000000000000001:
		return false
	var a := _dissolve_flat[first]
	var b := _dissolve_flat[middle]
	var c := _dissolve_flat[last]
	var area := (b - a).cross(c - a)
	if area <= DISSOLVE_AREA_LIMIT:
		return false
	var offset := _dissolve_flat_point - a
	var flat_middle := offset.cross(c - a) / area
	var flat_last := (b - a).cross(offset) / area
	var flat_first := 1.0 - flat_middle - flat_last
	_triangle_covers = flat_first > -0.001 and flat_middle > -0.001 and flat_last > -0.001
	if not _triangle_covers:
		return true
	var side := _dissolve_removed_position - point_a
	var weight_middle := clampf((point_c - point_a).cross(side).dot(winding) / squared, 0.0, 1.0)
	var weight_last := clampf((point_b - point_a).cross(side).dot(winding) / squared, 0.0, 1.0)
	var weight_first := clampf(1.0 - weight_middle - weight_last, 0.0, 1.0)
	var total := weight_first + weight_middle + weight_last
	if total <= 0.0:
		return false
	var inverse := 1.0 / total
	weight_first *= inverse
	weight_middle *= inverse
	weight_last *= inverse
	var normal_a := _dissolve_normals[first]
	var normal_b := _dissolve_normals[middle]
	var normal_c := _dissolve_normals[last]
	var blended := normal_a * weight_first + normal_b * weight_middle + normal_c * weight_last
	if blended.length_squared() < 0.0000000001:
		return false
	var dot := blended.normalized().dot(_dissolve_removed_normal)
	if dot < DISSOLVE_NORMAL_COSINE:
		return false
	var colour := _dissolve_colours[first] * weight_first + _dissolve_colours[middle] * weight_middle + _dissolve_colours[last] * weight_last
	var colour_error := maxf(maxf(absf(colour.r - _dissolve_removed_colour.r), absf(colour.g - _dissolve_removed_colour.g)), absf(colour.b - _dissolve_removed_colour.b))
	if colour_error > DISSOLVE_COLOUR_LIMIT:
		return false
	return true
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


func _edge_sample(cell: Vector3i, edge: int, occupancy: PackedByteArray, material_ids: PackedInt32Array) -> void:
	var origin := (cell.x + SAMPLE_PADDING) + SAMPLE_SIZE * ((cell.y + SAMPLE_PADDING) + SAMPLE_SIZE * (cell.z + SAMPLE_PADDING))
	var cell_point := Vector3(cell)
	if edge >= EDGE_CORNERS.size():
		var point := _edge_point(cell, edge)
		var closest := INF
		var label := -1
		for corner in 8:
			var sample_index: int = origin + CORNER_STEPS[corner]
			if occupancy[sample_index] == 0:
				continue
			var distance := (point - (cell_point + _corner_points[corner])).length_squared()
			if distance < closest - 0.000001 or (distance <= closest + 0.000001 and (label < 0 or material_ids[sample_index] < label)):
				closest = distance
				label = material_ids[sample_index]
		var site := Vector3.ZERO
		var tied := 0
		for corner in 8:
			var sample_index: int = origin + CORNER_STEPS[corner]
			if occupancy[sample_index] == 0 or material_ids[sample_index] != label:
				continue
			var distance := (point - (cell_point + _corner_points[corner])).length_squared()
			if distance <= closest + 0.000001:
				site += cell_point + _corner_points[corner]
				tied += 1
		if tied > 0:
			site /= float(tied)
		_edge_site = site
		_edge_label = label
		return
	var corners: Array = EDGE_CORNERS[edge]
	for corner: int in corners:
		var sample_index: int = origin + CORNER_STEPS[corner]
		if occupancy[sample_index] != 0:
			_edge_site = cell_point + _corner_points[corner]
			_edge_label = material_ids[sample_index]
			return
	_edge_site = cell_point
	_edge_label = 0


func _quad_fan_ambiguous(loop_data: Dictionary) -> bool:
	var points: Array[Vector3] = loop_data["points"]
	var sums: Array = loop_data["sums"]
	if sums[0] >= 0 and sums[1] >= 0 and sums[0] != sums[1]:
		return false
	var first_diagonal: float = points[0].distance_to(points[2])
	var second_diagonal: float = points[1].distance_to(points[3])
	if absf(first_diagonal - second_diagonal) > 0.0001:
		return false
	var first_key: PackedFloat32Array = _split_intrinsic_key(points, PackedInt32Array([0, 1, 2, 3]))
	var second_key: PackedFloat32Array = _split_intrinsic_key(points, PackedInt32Array([1, 2, 3, 0]))
	return not _key_before(first_key, second_key) and not _key_before(second_key, first_key)


func _append_quad_fan(cell: Vector3i, bits: int, loop: PackedInt32Array, loop_data: Dictionary, materials: PackedFloat32Array, positions: PackedVector3Array, normals: PackedVector3Array, vertex_colors: PackedColorArray, vertex_materials: PackedInt32Array, indices: PackedInt32Array, mixed: bool) -> bool:
	if loop.size() != 4:
		return false
	var points: Array[Vector3] = loop_data["points"]
	var labels: PackedInt32Array = loop_data["labels"]
	var centre := (points[0] + points[1] + points[2] + points[3]) * 0.25
	if mixed:
		var counts := {}
		for label: int in labels:
			counts[label] = counts.get(label, 0) + 1
		var majority := -1
		var best := 0
		for label: int in counts:
			if counts[label] > best:
				best = counts[label]
				majority = label
		var sites: Array[Vector3] = loop_data["site_points"]
		var centre_site := (sites[0] + sites[1] + sites[2] + sites[3]) * 0.25
		for index in 4:
			var next := (index + 1) % 4
			_append_material_triangle(
				cell, bits,
				PackedVector3Array([points[index], points[next], centre]),
				PackedInt32Array([labels[index], labels[next], majority]),
				PackedVector3Array([sites[index], sites[next], centre_site]),
				materials, positions, normals, vertex_colors, vertex_materials, indices
			)
		return true
	var material: int = labels[0]
	for index in 4:
		var next := (index + 1) % 4
		_append_oriented_triangle(
			cell, bits,
			points[index], points[next], centre,
			material, material, material,
			materials, positions, normals, vertex_colors, vertex_materials, indices
		)
	return true


func _canonical_flat_quad(loop: PackedInt32Array, loop_data: Dictionary) -> PackedInt32Array:
	if loop.size() != 4:
		return PackedInt32Array()
	var points: Array[Vector3] = loop_data["points"]
	var labels: PackedInt32Array = loop_data["labels"]
	var normal: Vector3 = (points[1] - points[0]).cross(points[2] - points[0])
	if normal.length_squared() < 0.0000000001:
		return PackedInt32Array()
	var clean_a := labels[0] == labels[1] and labels[1] == labels[2] and labels[2] == labels[3]
	var clean_b := clean_a
	var sums: Array = loop_data["sums"]
	var first_distinct := _distinct_count(labels, [0, 1, 2]) + _distinct_count(labels, [0, 2, 3])
	var second_distinct := _distinct_count(labels, [1, 2, 3]) + _distinct_count(labels, [1, 3, 0])
	var choose_a := true
	if clean_a != clean_b:
		choose_a = clean_a
	elif first_distinct != second_distinct:
		choose_a = first_distinct > second_distinct
	elif sums[0] >= 0 and sums[1] >= 0 and sums[0] != sums[1]:
		choose_a = sums[0] < sums[1]
	else:
		var first_diagonal := points[0].distance_to(points[2])
		var second_diagonal := points[1].distance_to(points[3])
		if absf(first_diagonal - second_diagonal) > 0.0001:
			choose_a = first_diagonal > second_diagonal
		else:
			choose_a = _key_before(_split_intrinsic_key(points, PackedInt32Array([0, 1, 2, 3])), _split_intrinsic_key(points, PackedInt32Array([1, 2, 3, 0])))
	if choose_a:
		return PackedInt32Array([loop[0], loop[1], loop[2], loop[0], loop[2], loop[3]])
	return PackedInt32Array([loop[1], loop[2], loop[3], loop[1], loop[3], loop[0]])


static func _distinct_count(labels: PackedInt32Array, indices: Array) -> int:
	var set := {}
	for index: int in indices:
		set[labels[index]] = true
	return set.size()


static func _split_intrinsic_key(points: Array[Vector3], order: PackedInt32Array) -> PackedFloat32Array:
	var triangles := [[order[0], order[1], order[2]], [order[0], order[2], order[3]]]
	var keys := []
	for triangle: Array in triangles:
		var lengths := []
		for index in 3:
			lengths.append(points[triangle[index]].distance_to(points[triangle[(index + 1) % 3]]))
		lengths.sort()
		keys.append(lengths)
	keys.sort_custom(func(first: Array, second: Array) -> bool:
		for index in 3:
			if absf(first[index] - second[index]) > 0.0001:
				return first[index] < second[index]
		return false)
	var key := PackedFloat32Array()
	for lengths: Array in keys:
		for length: float in lengths:
			key.append(roundf(length * 10000.0) / 10000.0)
	return key


func _material_diagonal(loop: PackedInt32Array, loop_data: Dictionary) -> PackedInt32Array:
	if loop.size() != 4:
		return PackedInt32Array()
	var quad: Array[Vector3i] = loop_data["sites"]
	var labels: PackedInt32Array = loop_data["labels"]
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
	var components: PackedInt32Array = loop_data["components"]
	if components.is_empty():
		return PackedInt32Array()
	var component_sizes: PackedInt32Array = loop_data["component_sizes"]
	var first_component := _component_at(quad[0], first_axis, second_axis, first_low - 1, second_low - 1, components)
	var second_component := _component_at(quad[1], first_axis, second_axis, first_low - 1, second_low - 1, components)
	var third_component := _component_at(quad[2], first_axis, second_axis, first_low - 1, second_low - 1, components)
	var fourth_component := _component_at(quad[3], first_axis, second_axis, first_low - 1, second_low - 1, components)
	if first_component != third_component and second_component == fourth_component:
		return PackedInt32Array([loop[0], loop[1], loop[2], loop[0], loop[2], loop[3]])
	if second_component != fourth_component and first_component == third_component:
		return PackedInt32Array([loop[1], loop[2], loop[3], loop[1], loop[3], loop[0]])
	if first_component != third_component and second_component != fourth_component:
		var first_size := (component_sizes[first_component] if first_component >= 0 else 0) + (component_sizes[third_component] if third_component >= 0 else 0)
		var second_size := (component_sizes[second_component] if second_component >= 0 else 0) + (component_sizes[fourth_component] if fourth_component >= 0 else 0)
		if first_size < second_size:
			return PackedInt32Array([loop[0], loop[1], loop[2], loop[0], loop[2], loop[3]])
		if second_size < first_size:
			return PackedInt32Array([loop[1], loop[2], loop[3], loop[1], loop[3], loop[0]])
	return PackedInt32Array()


func _quad_components(quad: Array[Vector3i], constant_axis: int, first_axis: int, second_axis: int, first_low: int, second_low: int, occupancy: PackedByteArray, material_ids: PackedInt32Array) -> PackedInt32Array:
	var constant_sample: int = quad[0][constant_axis] + SAMPLE_PADDING
	var first_start := first_low + SAMPLE_PADDING
	var second_start := second_low + SAMPLE_PADDING
	if first_start < 0 or second_start < 0 or constant_sample < 0:
		return PackedInt32Array()
	if first_start + 3 >= SAMPLE_SIZE or second_start + 3 >= SAMPLE_SIZE or constant_sample >= SAMPLE_SIZE:
		return PackedInt32Array()
	var first_stride := 1 if first_axis == 0 else (SAMPLE_SIZE if first_axis == 1 else SAMPLE_SIZE * SAMPLE_SIZE)
	var second_stride := 1 if second_axis == 0 else (SAMPLE_SIZE if second_axis == 1 else SAMPLE_SIZE * SAMPLE_SIZE)
	var constant_stride := 1 if constant_axis == 0 else (SAMPLE_SIZE if constant_axis == 1 else SAMPLE_SIZE * SAMPLE_SIZE)
	var base := constant_sample * constant_stride + first_start * first_stride + second_start * second_stride
	var samples := PackedInt32Array()
	samples.resize(16)
	for second in 4:
		var row := base + second * second_stride
		for first in 4:
			samples[second * 4 + first] = row + first * first_stride
	var components := PackedInt32Array()
	components.resize(16)
	components.fill(-1)
	var component := 0
	var stack: Array[int] = []
	for start in 16:
		if components[start] >= 0 or occupancy[samples[start]] == 0:
			continue
		var material := material_ids[samples[start]]
		components[start] = component
		stack.append(start)
		while not stack.is_empty():
			var current: int = stack.pop_back()
			var current_first := current % 4
			for offset: int in COMPONENT_STEPS:
				var neighbor := current + offset
				if neighbor < 0 or neighbor >= 16:
					continue
				if offset == -1 and current_first == 0:
					continue
				if offset == 1 and current_first == 3:
					continue
				if components[neighbor] >= 0:
					continue
				var neighbor_index := samples[neighbor]
				if occupancy[neighbor_index] == 0 or material_ids[neighbor_index] != material:
					continue
				components[neighbor] = component
				stack.append(neighbor)
		component += 1
	return components


static func _component_at(site: Vector3i, first_axis: int, second_axis: int, first_low: int, second_low: int, components: PackedInt32Array) -> int:
	var first := site[first_axis] - first_low
	var second := site[second_axis] - second_low
	if first < 0 or first > 3 or second < 0 or second > 3:
		return -1
	return components[second * 4 + first]


static func _opposite_pair_for(bits: int) -> bool:
	var solid: Array[int] = []
	for corner in 8:
		if bits & (1 << corner):
			solid.append(corner)
	if solid.size() != 2:
		return false
	return CORNER_OFFSETS[solid[0]] + CORNER_OFFSETS[solid[1]] == Vector3i.ONE


func _append_antiprism(cell: Vector3i, bits: int, groups: Array, field: PackedFloat32Array, occupancy: PackedByteArray, material_ids: PackedInt32Array, materials: PackedFloat32Array, positions: PackedVector3Array, normals: PackedVector3Array, vertex_colors: PackedColorArray, vertex_materials: PackedInt32Array, indices: PackedInt32Array) -> bool:
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
			_edge_sample(cell, edges[index], occupancy, material_ids)
			labels.append(_edge_label)
			sites.append(_edge_site)
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
		var by_normal: Dictionary
		if by_position.has(position_key):
			by_normal = by_position[position_key]
		else:
			by_normal = {}
			by_position[position_key] = by_normal
		var by_material: Dictionary
		if by_normal.has(normal_key):
			by_material = by_normal[normal_key]
		else:
			by_material = {}
			by_normal[normal_key] = by_material
		if by_material.has(material_id):
			welded_indices[index] = by_material[material_id]
			continue
		var vertex := welded_positions.size()
		welded_positions.append(position)
		welded_normals.append(normal)
		welded_colors.append(colors[source])
		welded_materials.append(material_id)
		by_material[material_id] = vertex
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
	var face_triangles: Array = _case_face_triangles[neighbor_bits]
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
	if first_material == second_material and second_material == third_material:
		var base := first_material * VoxelFrame.MATERIAL_STRIDE
		var colour := Color(materials[base], materials[base + 1], materials[base + 2], materials[base + 3])
		normals.append(shading)
		normals.append(shading)
		normals.append(shading)
		vertex_colors.append(colour)
		vertex_colors.append(colour)
		vertex_colors.append(colour)
		vertex_materials.append(first_material)
		vertex_materials.append(first_material)
		vertex_materials.append(first_material)
	else:
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









