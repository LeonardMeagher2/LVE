class_name VoxelMarchingMeshBuilder
extends RefCounted


const CHUNK_SIZE := VoxelFrame.CHUNK_SIZE
const SAMPLE_PADDING := 2
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

static var _case_triangles: Array[PackedInt32Array] = []

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
var rejected_third_material := 0


static func _static_init() -> void:
	_case_triangles.resize(256)
	for bits in 256:
		_case_triangles[bits] = _case_triangles_for(bits)


func run() -> void:
	var frame := source_frame
	source_frame = null
	var occupancy := PackedByteArray()
	var material_ids := PackedInt32Array()
	var materials := PackedFloat32Array()
	if frame != null:
		var sampled := _sample(frame, chunk_location, slice_axis, slice_index, slice_count)
		occupancy = sampled[0]
		material_ids = sampled[1]
		materials = sampled[2]
	_build(occupancy, material_ids, materials)


func _sample(frame: VoxelFrame, location: Vector3i, slice_axis: int, slice_index: int, slice_count: int) -> Array:
	var cells := SAMPLE_SIZE * SAMPLE_SIZE * SAMPLE_SIZE
	var occupancy := PackedByteArray()
	occupancy.resize(cells)
	var material_ids := PackedInt32Array()
	material_ids.resize(cells)
	var materials := VoxelFrame.material(Color.TRANSPARENT)
	var material_table := {}
	var sample_origin := location * CHUNK_SIZE - Vector3i.ONE * SAMPLE_PADDING
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
	return [occupancy, material_ids, materials]


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
				var pair_second := 0
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
							pair_second = b.w
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
								pair_second = edge.w
								break
						if pair_first != 0:
							break
				if pair_first == 0:
					continue
				if not _no_third_material(real, material_ids, x, y, z, pair_first, pair_second):
					rejected_third_material += 1
					continue
				occupancy[index] = 1
				material_ids[index] = pair_first
				bridge_cells += 1
	return materials


static func _no_third_material(real: PackedByteArray, material_ids: PackedInt32Array, x: int, y: int, z: int, first: int, second: int) -> bool:
	for offset_z in range(-1, 2):
		for offset_y in range(-1, 2):
			for offset_x in range(-1, 2):
				if offset_x == 0 and offset_y == 0 and offset_z == 0:
					continue
				var neighbor_index := x + offset_x + SAMPLE_SIZE * (y + offset_y + SAMPLE_SIZE * (z + offset_z))
				if real[neighbor_index] == 0:
					continue
				var material_id := material_ids[neighbor_index]
				if material_id != first and material_id != second:
					return false
	return true


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


func _build(occupancy: PackedByteArray, material_ids: PackedInt32Array, materials: PackedFloat32Array) -> void:
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var vertex_colors := PackedColorArray()
	var indices := PackedInt32Array()
	var origin := chunk_location * CHUNK_SIZE
	for z in range(-1, CHUNK_SIZE):
		for y in range(-1, CHUNK_SIZE):
			for x in range(-1, CHUNK_SIZE):
				var cell := Vector3i(x, y, z)
				var bits := 0
				var solid := 0
				var first_solid := -1
				var color_sum := Color(0.0, 0.0, 0.0, 0.0)
				for corner in 8:
					var offset: Vector3i = CORNER_OFFSETS[corner]
					var sample := cell + offset + Vector3i.ONE * SAMPLE_PADDING
					var sample_index := sample.x + SAMPLE_SIZE * (sample.y + SAMPLE_SIZE * sample.z)
					if occupancy[sample_index] == 0:
						continue
					if first_solid < 0:
						first_solid = corner
					bits |= 1 << corner
					solid += 1
					var material_id := material_ids[sample_index]
					var base := material_id * VoxelFrame.MATERIAL_STRIDE
					color_sum += Color(materials[base], materials[base + 1], materials[base + 2], materials[base + 3])
				if first_solid < 0:
					continue
				if VoxelFrame.chunk_position(origin + cell + CORNER_OFFSETS[first_solid]) != chunk_location:
					continue
				var triangle_edges: PackedInt32Array = _case_triangles[bits]
				if triangle_edges.is_empty():
					continue
				var face_color := color_sum / float(solid)
				for index in range(0, triangle_edges.size(), 3):
					var first_point := _edge_point(cell, triangle_edges[index])
					var second_point := _edge_point(cell, triangle_edges[index + 1])
					var third_point := _edge_point(cell, triangle_edges[index + 2])
					_append_oriented_triangle(cell, bits, first_point, second_point, third_point, face_color, positions, normals, vertex_colors, indices)
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays[Mesh.ARRAY_VERTEX] = positions
	surface_arrays[Mesh.ARRAY_NORMAL] = normals
	surface_arrays[Mesh.ARRAY_COLOR] = vertex_colors
	surface_arrays[Mesh.ARRAY_INDEX] = indices
	geometry_bytes = positions.size() * 40 + indices.size() * 4


func _append_oriented_triangle(cell: Vector3i, bits: int, first: Vector3, second: Vector3, third: Vector3, color: Color, positions: PackedVector3Array, normals: PackedVector3Array, vertex_colors: PackedColorArray, indices: PackedInt32Array) -> void:
	var winding := (second - first).cross(third - first)
	if winding.length_squared() < 0.0000000001:
		return
	var inside := _inside_gradient(bits, (first + second + third) / 3.0 - Vector3(cell))
	if winding.dot(inside) < 0.0:
		var swap := second
		second = third
		third = swap
		winding = -winding
	var shading := -winding.normalized()
	var first_vertex := positions.size()
	positions.append(first)
	positions.append(second)
	positions.append(third)
	for vertex in 3:
		normals.append(shading)
		vertex_colors.append(color)
	indices.append(first_vertex)
	indices.append(first_vertex + 1)
	indices.append(first_vertex + 2)


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


static func _case_triangles_for(bits: int) -> PackedInt32Array:
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
	var triangles := PackedInt32Array()
	var visited := {}
	for edge in 12:
		if visited.has(edge) or neighbors[edge].is_empty():
			continue
		var loop: Array[int] = []
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
		triangles.append_array(_triangulate_loop(loop))
	return triangles


static func _face_corners_adjacent(first: int, second: int) -> bool:
	return (first + 1) % 4 == second or (second + 1) % 4 == first


static func _triangulate_loop(loop: Array[int]) -> PackedInt32Array:
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
