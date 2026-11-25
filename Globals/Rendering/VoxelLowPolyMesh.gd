class_name VoxelLowPolyMesh
extends RefCounted


const FIELD_PAD := 3
const OWNED_PAD := 1
const SEARCH_RADIUS := 3
const REGULARIZATION := 0.01
const NO_CELL := Vector3i(2147483647, 2147483647, 2147483647)
const CORNERS := [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0),
	Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(0, 1, 1), Vector3i(1, 1, 1),
]
const EDGES := [
	[0, 1], [2, 3], [4, 5], [6, 7],
	[0, 2], [1, 3], [4, 6], [5, 7],
	[0, 4], [1, 5], [2, 6], [3, 7],
]
const EDGE_CELLS := [
	[Vector3i(0, -1, -1), Vector3i(0, 0, -1), Vector3i(0, 0, 0), Vector3i(0, -1, 0)],
	[Vector3i(-1, 0, -1), Vector3i(0, 0, -1), Vector3i(0, 0, 0), Vector3i(-1, 0, 0)],
	[Vector3i(-1, -1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 0), Vector3i(-1, 0, 0)],
]

var arrays: Array = []
var merge_faces := false
var triangle_count := 0
var surface_cells := 0
var build_us := 0

var _frame: VoxelFrame
var _grid_min := Vector3i.ZERO
var _grid_size := Vector3i.ZERO
var _cell_min := Vector3i.ZERO
var _cell_size := Vector3i.ZERO
var _field := PackedFloat32Array()
var _gradient := PackedFloat32Array()
var _solid := PackedByteArray()
var _bridge_materials := {}
var _cell_vertex := PackedInt32Array()
var _cell_positions := PackedVector3Array()
var _cell_solids: Array = []
var _mesh_triangles := PackedInt32Array()
var _mesh_colors: Array[Color] = []
var _mesh_materials: Array[PackedFloat32Array] = []
var _positions := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _indices := PackedInt32Array()


func build(frame: VoxelFrame) -> void:
	var started := Time.get_ticks_usec()
	_frame = frame
	arrays = _empty_arrays()
	triangle_count = 0
	surface_cells = 0
	_positions = PackedVector3Array()
	_normals = PackedVector3Array()
	_colors = PackedColorArray()
	_indices = PackedInt32Array()
	_cell_positions = PackedVector3Array()
	_cell_solids = []
	_mesh_triangles = PackedInt32Array()
	_mesh_colors = []
	_mesh_materials = []
	var bounds := frame.get_bounds()
	if not bounds.has_volume():
		build_us = Time.get_ticks_usec() - started
		return
	var min_cell := Vector3i((bounds.position + Vector3.ONE * 0.5).round())
	var max_cell := Vector3i((bounds.end - Vector3.ONE * 0.5).round())
	_cell_min = min_cell - Vector3i.ONE * OWNED_PAD
	_cell_size = max_cell - min_cell + Vector3i.ONE * (2 * OWNED_PAD + 1)
	_grid_min = _cell_min - Vector3i.ONE * FIELD_PAD
	_grid_size = _cell_size + Vector3i.ONE * 2 + Vector3i.ONE * (2 * FIELD_PAD) - Vector3i.ONE
	_fill_solid()
	_build_field()
	_build_gradient()
	_build_vertices()
	_build_triangles()
	_orient_triangles()
	if merge_faces:
		_merge_coplanar_faces()
	_expand()
	arrays[Mesh.ARRAY_VERTEX] = _positions
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_COLOR] = _colors
	arrays[Mesh.ARRAY_INDEX] = _indices
	triangle_count = _indices.size() / 3
	build_us = Time.get_ticks_usec() - started


func _empty_arrays() -> Array:
	var result := []
	result.resize(Mesh.ARRAY_MAX)
	result[Mesh.ARRAY_VERTEX] = PackedVector3Array()
	result[Mesh.ARRAY_NORMAL] = PackedVector3Array()
	result[Mesh.ARRAY_COLOR] = PackedColorArray()
	result[Mesh.ARRAY_INDEX] = PackedInt32Array()
	return result


func _grid_index(x: int, y: int, z: int) -> int:
	return x + _grid_size.x * (y + _grid_size.y * z)


func _cell_index(x: int, y: int, z: int) -> int:
	return x + _cell_size.x * (y + _cell_size.y * z)


func _fill_solid() -> void:
	var count := _grid_size.x * _grid_size.y * _grid_size.z
	_solid = PackedByteArray()
	_solid.resize(count)
	for z in _grid_size.z:
		var world_z := _grid_min.z + z
		for y in _grid_size.y:
			var world_y := _grid_min.y + y
			var row := _grid_size.x * (y + _grid_size.y * z)
			for x in _grid_size.x:
				if _frame.has(Vector3i(_grid_min.x + x, world_y, world_z)):
					_solid[row + x] = 1
	_bridge_materials.clear()
	_add_contact_bridges()


func _build_field() -> void:
	var count := _grid_size.x * _grid_size.y * _grid_size.z
	_field = PackedFloat32Array()
	_field.resize(count)
	for z in _grid_size.z:
		for y in _grid_size.y:
			for x in _grid_size.x:
				var index := _grid_index(x, y, z)
				var inside := _solid[index] != 0
				var point := Vector3(_grid_min + Vector3i(x, y, z))
				var nearest := float(SEARCH_RADIUS) + 0.5
				for oz in range(-SEARCH_RADIUS, SEARCH_RADIUS + 1):
					var sample_z := z + oz
					if sample_z < 0 or sample_z >= _grid_size.z:
						continue
					for oy in range(-SEARCH_RADIUS, SEARCH_RADIUS + 1):
						var sample_y := y + oy
						if sample_y < 0 or sample_y >= _grid_size.y:
							continue
						for ox in range(-SEARCH_RADIUS, SEARCH_RADIUS + 1):
							var sample_x := x + ox
							if sample_x < 0 or sample_x >= _grid_size.x:
								continue
							if (_solid[_grid_index(sample_x, sample_y, sample_z)] != 0) == inside:
								continue
							var cell := point + Vector3(ox, oy, oz)
							var q := (point - cell).abs() - Vector3.ONE * 0.5
							var outside := Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0))
							var distance := outside.length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)
							nearest = minf(nearest, distance)
				_field[index] = -nearest if inside else nearest


func _add_contact_bridges() -> void:
	var original := _solid.duplicate()
	var cells: Array[Vector3i] = []
	var index_of := {}
	for z in _grid_size.z:
		for y in _grid_size.y:
			for x in _grid_size.x:
				if original[_grid_index(x, y, z)] == 0:
					continue
				var cell := _grid_min + Vector3i(x, y, z)
				index_of[cell] = cells.size()
				cells.append(cell)
	var parent: Array[int] = []
	parent.resize(cells.size())
	for index in cells.size():
		parent[index] = index
	var faces: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1)]
	for cell in cells:
		var material := _material_for_cell(cell)
		for offset: Vector3i in faces:
			var neighbor := cell + offset
			if not index_of.has(neighbor):
				continue
			if _material_for_cell(neighbor) != material:
				continue
			_union(parent, index_of[cell], index_of[neighbor])
	var offsets: Array[Vector3i] = []
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				var offset := Vector3i(x, y, z)
				if absi(x) + absi(y) + absi(z) < 2:
					continue
				if _positive_offset(offset):
					offsets.append(offset)
	for cell in cells:
		var material := _material_for_cell(cell)
		for offset: Vector3i in offsets:
			var neighbor := cell + offset
			if not index_of.has(neighbor):
				continue
			if _material_for_cell(neighbor) != material:
				continue
			var first: int = index_of[cell]
			var second: int = index_of[neighbor]
			if _find(parent, first) == _find(parent, second):
				continue
			if absi(offset.x) + absi(offset.y) + absi(offset.z) == 2:
				_mark_bridge(cell + Vector3i(offset.x, 0, 0) if offset.x != 0 else cell + Vector3i(0, offset.y, 0), material)
			else:
				_mark_bridge(cell + Vector3i(offset.x, 0, 0), material)
				_mark_bridge(cell + Vector3i(offset.x, offset.y, 0), material)
			_union(parent, first, second)


func _find(parent: Array[int], index: int) -> int:
	while parent[index] != index:
		parent[index] = parent[parent[index]]
		index = parent[index]
	return index


func _union(parent: Array[int], first: int, second: int) -> void:
	var first_root := _find(parent, first)
	var second_root := _find(parent, second)
	if first_root != second_root:
		parent[second_root] = first_root


func _positive_offset(offset: Vector3i) -> bool:
	if offset.z != 0:
		return offset.z > 0
	if offset.y != 0:
		return offset.y > 0
	return offset.x > 0


func _mark_bridge(cell: Vector3i, material: PackedFloat32Array) -> void:
	var x := cell.x - _grid_min.x
	var y := cell.y - _grid_min.y
	var z := cell.z - _grid_min.z
	if x < 0 or x >= _grid_size.x or y < 0 or y >= _grid_size.y or z < 0 or z >= _grid_size.z:
		return
	var index := _grid_index(x, y, z)
	if _solid[index] != 0:
		return
	_solid[index] = 1
	_bridge_materials[cell] = material


func _material_for_cell(cell: Vector3i) -> PackedFloat32Array:
	if _bridge_materials.has(cell):
		return _bridge_materials[cell]
	return _frame.get_material(cell)


func _build_gradient() -> void:
	var count := _grid_size.x * _grid_size.y * _grid_size.z
	_gradient = PackedFloat32Array()
	_gradient.resize(count * 3)
	for z in _grid_size.z:
		for y in _grid_size.y:
			for x in _grid_size.x:
				var index := _grid_index(x, y, z)
				var x0 := _grid_index(maxi(0, x - 1), y, z)
				var x1 := _grid_index(mini(_grid_size.x - 1, x + 1), y, z)
				var y0 := _grid_index(x, maxi(0, y - 1), z)
				var y1 := _grid_index(x, mini(_grid_size.y - 1, y + 1), z)
				var z0 := _grid_index(x, y, maxi(0, z - 1))
				var z1 := _grid_index(x, y, mini(_grid_size.z - 1, z + 1))
				_gradient[index * 3] = (_field[x1] - _field[x0]) * 0.5
				_gradient[index * 3 + 1] = (_field[y1] - _field[y0]) * 0.5
				_gradient[index * 3 + 2] = (_field[z1] - _field[z0]) * 0.5


func _build_vertices() -> void:
	var count := _cell_size.x * _cell_size.y * _cell_size.z
	_cell_vertex = PackedInt32Array()
	_cell_vertex.resize(count)
	_cell_vertex.fill(-1)
	for z in _cell_size.z:
		for y in _cell_size.y:
			for x in _cell_size.x:
				var p := _cell_min + Vector3i(x, y, z)
				var values := _corner_values(p)
				var inside := 0
				for value in values:
					if value < 0.0:
						inside += 1
				if inside == 0 or inside == 8:
					continue
				var placed := _quadric_vertex(p, values)
				_cell_vertex[_cell_index(x, y, z)] = _cell_positions.size()
				_cell_positions.append(placed)
				var solids: Array[Vector3i] = []
				for corner in 8:
					if values[corner] < 0.0:
						solids.append(p + CORNERS[corner])
				_cell_solids.append(solids)
				surface_cells += 1


func _corner_values(p: Vector3i) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(8)
	for corner in 8:
		var offset: Vector3i = CORNERS[corner]
		values[corner] = _field[_grid_index(p.x - _grid_min.x + offset.x, p.y - _grid_min.y + offset.y, p.z - _grid_min.z + offset.z)]
	return values


func _face_source(centroid: Vector3, normal: Vector3, cells: Array) -> Vector3i:
	var inward := -normal
	var best := 1.0e9
	var found := NO_CELL
	for cell_index: int in cells:
		for cell: Vector3i in _cell_solids[cell_index]:
			var offset := Vector3(cell) - centroid
			if offset.dot(inward) <= 0.0:
				continue
			var distance := offset.length_squared()
			if distance < best:
				best = distance
				found = cell
	if best >= 1.0e9:
		for cell_index: int in cells:
			for cell: Vector3i in _cell_solids[cell_index]:
				var distance := Vector3(cell).distance_squared_to(centroid)
				if distance < best:
					best = distance
					found = cell
	return found


func _quadric_vertex(p: Vector3i, values: PackedFloat32Array) -> Vector3:
	var a00 := 0.0
	var a01 := 0.0
	var a02 := 0.0
	var a10 := 0.0
	var a11 := 0.0
	var a12 := 0.0
	var a20 := 0.0
	var a21 := 0.0
	var a22 := 0.0
	var b0 := 0.0
	var b1 := 0.0
	var b2 := 0.0
	var sum := Vector3.ZERO
	var crossings := 0
	for edge: Array in EDGES:
		var first := values[edge[0]]
		var second := values[edge[1]]
		if (first < 0.0) == (second < 0.0):
			continue
		var t := first / (first - second)
		var offset_a: Vector3i = CORNERS[edge[0]]
		var offset_b: Vector3i = CORNERS[edge[1]]
		var point := Vector3(p) + Vector3(offset_a).lerp(Vector3(offset_b), t)
		var normal := _edge_normal(p, offset_a, offset_b, t)
		var distance := normal.dot(point)
		a00 += normal.x * normal.x
		a01 += normal.x * normal.y
		a02 += normal.x * normal.z
		a10 += normal.y * normal.x
		a11 += normal.y * normal.y
		a12 += normal.y * normal.z
		a20 += normal.z * normal.x
		a21 += normal.z * normal.y
		a22 += normal.z * normal.z
		b0 += normal.x * distance
		b1 += normal.y * distance
		b2 += normal.z * distance
		sum += point
		crossings += 1
	if crossings == 0:
		return Vector3(p) + Vector3.ONE * 0.5
	var center := Vector3(p) + Vector3.ONE * 0.5
	a00 += REGULARIZATION
	a11 += REGULARIZATION
	a22 += REGULARIZATION
	b0 += REGULARIZATION * center.x
	b1 += REGULARIZATION * center.y
	b2 += REGULARIZATION * center.z
	var det := a00 * (a11 * a22 - a12 * a21) - a01 * (a10 * a22 - a12 * a20) + a02 * (a10 * a21 - a11 * a20)
	var solved := Vector3.ZERO
	if absf(det) < 1.0e-12:
		solved = sum / float(crossings)
	else:
		solved.x = (b0 * (a11 * a22 - a12 * a21) - a01 * (b1 * a22 - a12 * b2) + a02 * (b1 * a21 - a11 * b2)) / det
		solved.y = (a00 * (b1 * a22 - a12 * b2) - b0 * (a10 * a22 - a12 * a20) + a02 * (a10 * b2 - b1 * a20)) / det
		solved.z = (a00 * (a11 * b2 - b1 * a21) - a01 * (a10 * b2 - b1 * a20) + b0 * (a10 * a21 - a11 * a20)) / det
	return Vector3(
		clampf(solved.x, p.x + 0.001, p.x + 0.999),
		clampf(solved.y, p.y + 0.001, p.y + 0.999),
		clampf(solved.z, p.z + 0.001, p.z + 0.999)
	)


func _edge_normal(p: Vector3i, offset_a: Vector3i, offset_b: Vector3i, t: float) -> Vector3:
	var first := _grid_index(p.x - _grid_min.x + offset_a.x, p.y - _grid_min.y + offset_a.y, p.z - _grid_min.z + offset_a.z)
	var second := _grid_index(p.x - _grid_min.x + offset_b.x, p.y - _grid_min.y + offset_b.y, p.z - _grid_min.z + offset_b.z)
	var normal := Vector3(
		lerpf(_gradient[first * 3], _gradient[second * 3], t),
		lerpf(_gradient[first * 3 + 1], _gradient[second * 3 + 1], t),
		lerpf(_gradient[first * 3 + 2], _gradient[second * 3 + 2], t)
	)
	if normal.length_squared() < 1.0e-12:
		normal = Vector3(offset_b - offset_a)
	return normal.normalized()


func _build_triangles() -> void:
	for axis in 3:
		var axis_vector := Vector3.ZERO
		axis_vector[axis] = 1.0
		var cells: Array = EDGE_CELLS[axis]
		for z in _cell_size.z:
			for y in _cell_size.y:
				for x in _cell_size.x:
					if axis == 0 and (y < 1 or z < 1):
						continue
					if axis == 1 and (x < 1 or z < 1):
						continue
					if axis == 2 and (x < 1 or y < 1):
						continue
					var first := _cell_vertex[_cell_index(x + cells[0].x, y + cells[0].y, z + cells[0].z)]
					var second := _cell_vertex[_cell_index(x + cells[1].x, y + cells[1].y, z + cells[1].z)]
					var third := _cell_vertex[_cell_index(x + cells[2].x, y + cells[2].y, z + cells[2].z)]
					var fourth := _cell_vertex[_cell_index(x + cells[3].x, y + cells[3].y, z + cells[3].z)]
					if first < 0 or second < 0 or third < 0 or fourth < 0:
						continue
					var gx := FIELD_PAD + x
					var gy := FIELD_PAD + y
					var gz := FIELD_PAD + z
					var a := _field[_grid_index(gx, gy, gz)]
					var b := _field[_grid_index(gx + 1, gy, gz)] if axis == 0 else (_field[_grid_index(gx, gy + 1, gz)] if axis == 1 else _field[_grid_index(gx, gy, gz + 1)])
					if (a < 0.0) == (b < 0.0):
						continue
					var outward := axis_vector if b > a else -axis_vector
					_emit_quad([first, second, third, fourth], outward)


func _emit_quad(quad: Array, axis_vector: Vector3) -> void:
	var p0 := _cell_positions[quad[0]]
	var p1 := _cell_positions[quad[1]]
	var p2 := _cell_positions[quad[2]]
	var p3 := _cell_positions[quad[3]]
	var normal := (p1 - p0).cross(p2 - p0)
	if normal.dot(axis_vector) < 0.0:
		quad = [quad[3], quad[2], quad[1], quad[0]]
		p0 = _cell_positions[quad[0]]
		p1 = _cell_positions[quad[1]]
		p2 = _cell_positions[quad[2]]
		p3 = _cell_positions[quad[3]]
	if p0.distance_squared_to(p2) <= p1.distance_squared_to(p3):
		_add_oriented_triangle(quad[0], quad[1], quad[2], axis_vector)
		_add_oriented_triangle(quad[0], quad[2], quad[3], axis_vector)
	else:
		_add_oriented_triangle(quad[0], quad[1], quad[3], axis_vector)
		_add_oriented_triangle(quad[1], quad[2], quad[3], axis_vector)


func _add_oriented_triangle(first: int, second: int, third: int, outward: Vector3) -> void:
	var a := _cell_positions[first]
	var b := _cell_positions[second]
	var c := _cell_positions[third]
	if (b - a).cross(c - a).dot(outward) < 0.0:
		_add_triangle(first, third, second)
	else:
		_add_triangle(first, second, third)


func _orient_triangles() -> void:
	var total := _mesh_triangles.size() / 3
	if total == 0:
		return
	var edge_triangles := {}
	for triangle in total:
		for side in 3:
			var first := _mesh_triangles[triangle * 3 + side]
			var second := _mesh_triangles[triangle * 3 + (side + 1) % 3]
			var key := _edge_key(first, second)
			if not edge_triangles.has(key):
				edge_triangles[key] = []
			edge_triangles[key].append(triangle)
	var visited := PackedByteArray()
	visited.resize(total)
	for seed in total:
		if visited[seed] != 0:
			continue
		visited[seed] = 1
		var stack: Array[int] = [seed]
		while not stack.is_empty():
			var triangle: int = stack.pop_back()
			for side in 3:
				var first := _mesh_triangles[triangle * 3 + side]
				var second := _mesh_triangles[triangle * 3 + (side + 1) % 3]
				var neighbors: Array = edge_triangles.get(_edge_key(first, second), [])
				if neighbors.size() != 2:
					continue
				var neighbor: int = neighbors[0] if neighbors[0] != triangle else neighbors[1]
				if visited[neighbor] != 0:
					continue
				visited[neighbor] = 1
				if _triangle_traverses(neighbor, first, second):
					_swap_triangle(neighbor)
				stack.append(neighbor)


func _triangle_traverses(triangle: int, first: int, second: int) -> bool:
	for side in 3:
		if _mesh_triangles[triangle * 3 + side] == first and _mesh_triangles[triangle * 3 + (side + 1) % 3] == second:
			return true
	return false


func _swap_triangle(triangle: int) -> void:
	var second := _mesh_triangles[triangle * 3 + 1]
	_mesh_triangles[triangle * 3 + 1] = _mesh_triangles[triangle * 3 + 2]
	_mesh_triangles[triangle * 3 + 2] = second


func _add_triangle(first: int, second: int, third: int) -> void:
	var a := _cell_positions[first]
	var b := _cell_positions[second]
	var c := _cell_positions[third]
	var normal := (b - a).cross(c - a)
	if normal.length_squared() < 1.0e-12:
		return
	normal = normal.normalized()
	var centroid := (a + b + c) / 3.0
	var cell := _face_source(centroid, normal, [first, second, third])
	var material := _material_for_cell(cell) if cell != NO_CELL else VoxelFrame.material(Color.MAGENTA)
	_mesh_triangles.append(first)
	_mesh_triangles.append(second)
	_mesh_triangles.append(third)
	_mesh_materials.append(material)
	_mesh_colors.append(VoxelFrame.material_color(material))


func _merge_coplanar_faces() -> void:
	var total := _mesh_triangles.size() / 3
	if total == 0:
		return
	var adjacency := _edge_triangles()
	var visited := PackedByteArray()
	visited.resize(total)
	var result := PackedInt32Array()
	var colors: Array[Color] = []
	var materials: Array[PackedFloat32Array] = []
	for seed in total:
		if visited[seed] != 0:
			continue
		visited[seed] = 1
		var a := _triangle_vertex(seed, 0)
		var b := _triangle_vertex(seed, 1)
		var c := _triangle_vertex(seed, 2)
		var normal := (b - a).cross(c - a)
		if normal.length_squared() < 1.0e-12:
			_append_triangle(result, colors, materials, seed)
			continue
		normal = normal.normalized()
		var offset := normal.dot(a)
		var group: Array[int] = []
		var stack: Array[int] = [seed]
		while not stack.is_empty():
			var triangle: int = stack.pop_back()
			group.append(triangle)
			for side in 3:
				var edge := _triangle_edge(triangle, side)
				for neighbor: int in adjacency.get(edge, []):
					if visited[neighbor] != 0:
						continue
					if _mesh_materials[neighbor] != _mesh_materials[seed]:
						continue
					if not _triangle_on_plane(neighbor, normal, offset):
						continue
					visited[neighbor] = 1
					stack.append(neighbor)
		if group.size() == 1:
			_append_triangle(result, colors, materials, seed)
			continue
		var merged := _triangulate_group(group, normal)
		if merged.is_empty():
			for triangle: int in group:
				_append_triangle(result, colors, materials, triangle)
			continue
		for index in range(0, merged.size(), 3):
			result.append(merged[index])
			result.append(merged[index + 1])
			result.append(merged[index + 2])
			colors.append(_mesh_colors[seed])
			materials.append(_mesh_materials[seed])
	_mesh_triangles = result
	_mesh_colors = colors
	_mesh_materials = materials


func _append_triangle(result: PackedInt32Array, colors: Array[Color], materials: Array[PackedFloat32Array], triangle: int) -> void:
	result.append(_mesh_triangles[triangle * 3])
	result.append(_mesh_triangles[triangle * 3 + 1])
	result.append(_mesh_triangles[triangle * 3 + 2])
	colors.append(_mesh_colors[triangle])
	materials.append(_mesh_materials[triangle])


func _triangle_vertex(triangle: int, side: int) -> Vector3:
	return _cell_positions[_mesh_triangles[triangle * 3 + side]]


func _triangle_edge(triangle: int, side: int) -> int:
	var first := _mesh_triangles[triangle * 3 + side]
	var second := _mesh_triangles[triangle * 3 + (side + 1) % 3]
	return _edge_key(first, second)


func _edge_key(first: int, second: int) -> int:
	return mini(first, second) * _cell_positions.size() + maxi(first, second)


func _edge_triangles() -> Dictionary:
	var adjacency := {}
	for triangle in _mesh_triangles.size() / 3:
		for side in 3:
			var key := _triangle_edge(triangle, side)
			if not adjacency.has(key):
				adjacency[key] = []
			adjacency[key].append(triangle)
	return adjacency


func _triangle_on_plane(triangle: int, normal: Vector3, offset: float) -> bool:
	var a := _triangle_vertex(triangle, 0)
	var b := _triangle_vertex(triangle, 1)
	var c := _triangle_vertex(triangle, 2)
	var candidate := (b - a).cross(c - a)
	if candidate.length_squared() < 1.0e-12:
		return false
	candidate = candidate.normalized()
	if candidate.dot(normal) < 1.0 - 1.0e-5:
		return false
	return absf(normal.dot(a) - offset) < 1.0e-4


func _triangulate_group(group: Array[int], normal: Vector3) -> PackedInt32Array:
	var vertex_count := _cell_positions.size()
	var directed := {}
	for triangle: int in group:
		for side in 3:
			var first := _mesh_triangles[triangle * 3 + side]
			var second := _mesh_triangles[triangle * 3 + (side + 1) % 3]
			var reverse := second * vertex_count + first
			if directed.has(reverse):
				directed.erase(reverse)
			else:
				directed[first * vertex_count + second] = true
	if directed.size() < 3:
		return PackedInt32Array()
	var next_of := {}
	var start := -1
	for key in directed:
		var first: int = key / vertex_count
		var second: int = key % vertex_count
		if next_of.has(first):
			return PackedInt32Array()
		next_of[first] = second
		if start < 0 or first < start:
			start = first
	if start < 0:
		return PackedInt32Array()
	var loop: Array[int] = []
	var current := start
	while true:
		if not next_of.has(current):
			return PackedInt32Array()
		loop.append(current)
		var next: int = next_of[current]
		next_of.erase(current)
		current = next
		if current == start:
			break
		if loop.size() > vertex_count:
			return PackedInt32Array()
	if not next_of.is_empty() or loop.size() < 3:
		return PackedInt32Array()
	var points := _project_loop(loop, normal)
	var kept := _simplify_loop(points)
	if kept.size() < 3:
		return PackedInt32Array()
	var polygon := PackedVector2Array()
	var loop_indices: Array[int] = []
	for index: int in kept:
		polygon.append(points[index])
		loop_indices.append(loop[index])
	var triangles := Geometry2D.triangulate_polygon(polygon)
	if triangles.is_empty():
		return PackedInt32Array()
	var result := PackedInt32Array()
	for index in triangles:
		result.append(loop_indices[index])
	if result.size() >= 3:
		var first: Vector3 = _cell_positions[result[0]]
		var second: Vector3 = _cell_positions[result[1]]
		var third: Vector3 = _cell_positions[result[2]]
		if (second - first).cross(third - first).dot(normal) < 0.0:
			for triangle in range(0, result.size(), 3):
				var swap := result[triangle + 1]
				result[triangle + 1] = result[triangle + 2]
				result[triangle + 2] = swap
	return result


func _project_loop(loop: Array[int], normal: Vector3) -> PackedVector2Array:
	var origin := _cell_positions[loop[0]]
	var reference := Vector3.UP if absf(normal.y) < 0.9 else Vector3.RIGHT
	var u := normal.cross(reference).normalized()
	var v := normal.cross(u)
	var points := PackedVector2Array()
	for vertex: int in loop:
		var offset := _cell_positions[vertex] - origin
		points.append(Vector2(offset.dot(u), offset.dot(v)))
	return points


func _simplify_loop(points: PackedVector2Array) -> PackedInt32Array:
	var count := points.size()
	var kept := PackedInt32Array()
	for index in count:
		var previous := points[(index + count - 1) % count]
		var current := points[index]
		var next := points[(index + 1) % count]
		if absf((current - previous).cross(next - current)) > 1.0e-6:
			kept.append(index)
	return kept


func _expand() -> void:
	for triangle in range(0, _mesh_triangles.size(), 3):
		var first := _mesh_triangles[triangle]
		var second := _mesh_triangles[triangle + 1]
		var third := _mesh_triangles[triangle + 2]
		var a := _cell_positions[first]
		var b := _cell_positions[second]
		var c := _cell_positions[third]
		var normal := (b - a).cross(c - a)
		if normal.length_squared() < 1.0e-12:
			continue
		normal = normal.normalized()
		var color := _mesh_colors[triangle / 3]
		var base := _positions.size()
		_positions.append(a)
		_positions.append(b)
		_positions.append(c)
		_normals.append(normal)
		_normals.append(normal)
		_normals.append(normal)
		_colors.append(color)
		_colors.append(color)
		_colors.append(color)
		_indices.append(base)
		_indices.append(base + 2)
		_indices.append(base + 1)
