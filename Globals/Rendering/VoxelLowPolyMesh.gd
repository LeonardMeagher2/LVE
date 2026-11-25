class_name VoxelLowPolyMesh
extends RefCounted

const FIELD_PAD := 3
const OWNED_PAD := 1
const SEARCH_RADIUS := 1
const REGULARIZATION := 0.01
const ATLAS := preload("./VoxelAtlas.gd")
const AO_LEVELS: Array[float] = [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0]
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
const OWNER_OFFSETS := [
	Vector3i(0, -1, -1),
	Vector3i(-1, 0, -1),
	Vector3i(-1, -1, 0),
]

var arrays: Array = []
var smooth_normals := false
var ao_strength := 0.0
var atlas: RefCounted
var material_uvs := {}
var triangle_count := 0
var degenerate_triangles := 0
var surface_cells := 0
var build_us := 0

var _frame: VoxelFrame
var _owned_min := Vector3i.ZERO
var _owned_size := Vector3i.ZERO
var _origin := Vector3.ZERO
var _grid_min := Vector3i.ZERO
var _grid_size := Vector3i.ZERO
var _cell_min := Vector3i.ZERO
var _cell_size := Vector3i.ZERO
var _field := PackedFloat32Array()
var _gradient := PackedFloat32Array()
var _solid := PackedByteArray()
var _bridge_materials := {}
var _material_cache := {}
var _cell_vertex := PackedInt32Array()
var _cell_positions := PackedVector3Array()
var _cell_solids: Array = []
var _mesh_triangles := PackedInt32Array()
var _mesh_materials: Array[PackedFloat32Array] = []
var _vertex_ao := PackedFloat32Array()
var _uvs := PackedVector2Array()
var _positions := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _indices := PackedInt32Array()

func build_region(frame: VoxelFrame, owned_min: Vector3i, owned_size: Vector3i, shared_atlas: RefCounted = null, shared_material_uvs: Dictionary = {}) -> void:
	var started := Time.get_ticks_usec()
	_frame = frame
	_owned_min = owned_min
	_owned_size = owned_size
	_origin = Vector3(owned_min)
	arrays = _empty_arrays()
	triangle_count = 0
	degenerate_triangles = 0
	surface_cells = 0
	_positions = PackedVector3Array()
	_normals = PackedVector3Array()
	_colors = PackedColorArray()
	_uvs = PackedVector2Array()
	_indices = PackedInt32Array()
	_cell_positions = PackedVector3Array()
	_cell_solids = []
	_mesh_triangles = PackedInt32Array()
	_mesh_materials = []
	atlas = null
	material_uvs = {}
	if owned_size.x <= 0 or owned_size.y <= 0 or owned_size.z <= 0:
		build_us = Time.get_ticks_usec() - started
		return
	_cell_min = owned_min - Vector3i.ONE * OWNED_PAD
	_cell_size = owned_size + Vector3i.ONE * (2 * OWNED_PAD + 1)
	_grid_min = _cell_min - Vector3i.ONE * FIELD_PAD
	_grid_size = _cell_size + Vector3i.ONE * 2 + Vector3i.ONE * (2 * FIELD_PAD) - Vector3i.ONE
	_fill_solid()
	_build_field()
	_build_gradient()
	_build_vertices()
	_build_triangles()
	_orient_triangles()
	_build_material_atlas(shared_atlas, shared_material_uvs)
	_build_vertex_ao()
	_expand()
	arrays[Mesh.ARRAY_VERTEX] = _positions
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_COLOR] = _colors
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_INDEX] = _indices
	triangle_count = _indices.size() / 3
	build_us = Time.get_ticks_usec() - started

func _empty_arrays() -> Array:
	var result := []
	result.resize(Mesh.ARRAY_MAX)
	result[Mesh.ARRAY_VERTEX] = PackedVector3Array()
	result[Mesh.ARRAY_NORMAL] = PackedVector3Array()
	result[Mesh.ARRAY_COLOR] = PackedColorArray()
	result[Mesh.ARRAY_TEX_UV] = PackedVector2Array()
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
	_material_cache.clear()
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
				if not _near_surface(x, y, z, inside):
					_field[index] = -1.0 if inside else 1.0
					continue
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
	if _material_cache.has(cell):
		return _material_cache[cell]
	var material := _frame.get_material(cell)
	_material_cache[cell] = material
	return material

func _near_surface(x: int, y: int, z: int, inside: bool) -> bool:
	for oz in range(-1, 2):
		var sample_z := z + oz
		if sample_z < 0 or sample_z >= _grid_size.z:
			continue
		for oy in range(-1, 2):
			var sample_y := y + oy
			if sample_y < 0 or sample_y >= _grid_size.y:
				continue
			for ox in range(-1, 2):
				if ox == 0 and oy == 0 and oz == 0:
					continue
				var sample_x := x + ox
				if sample_x < 0 or sample_x >= _grid_size.x:
					continue
				if (_solid[_grid_index(sample_x, sample_y, sample_z)] != 0) != inside:
					return true
	return false

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
		var owner_offset: Vector3i = OWNER_OFFSETS[axis]
		for gz in _cell_size.z:
			for gy in _cell_size.y:
				for gx in _cell_size.x:
					var fx := FIELD_PAD + gx
					var fy := FIELD_PAD + gy
					var fz := FIELD_PAD + gz
					var a := _field[_grid_index(fx, fy, fz)]
					var b := _field[_grid_index(fx + 1, fy, fz)] if axis == 0 else (_field[_grid_index(fx, fy + 1, fz)] if axis == 1 else _field[_grid_index(fx, fy, fz + 1)])
					if (a < 0.0) == (b < 0.0):
						continue
					var first := _edge_vertex(gx, gy, gz, cells[0])
					var second := _edge_vertex(gx, gy, gz, cells[1])
					var third := _edge_vertex(gx, gy, gz, cells[2])
					var fourth := _edge_vertex(gx, gy, gz, cells[3])
					if first < 0 or second < 0 or third < 0 or fourth < 0:
						continue
					if not _owned_cell(_edge_owner(gx, gy, gz, cells, owner_offset, axis)):
						continue
					var outward := axis_vector if b > a else -axis_vector
					_emit_quad([first, second, third, fourth], outward)

func _edge_vertex(gx: int, gy: int, gz: int, offset: Vector3i) -> int:
	var x := gx + offset.x
	var y := gy + offset.y
	var z := gz + offset.z
	if x < 0 or y < 0 or z < 0 or x >= _cell_size.x or y >= _cell_size.y or z >= _cell_size.z:
		return -1
	return _cell_vertex[_cell_index(x, y, z)]

func _owned_cell(cell: Vector3i) -> bool:
	return cell.x >= 1 and cell.y >= 1 and cell.z >= 1 and cell.x <= _owned_size.x and cell.y <= _owned_size.y and cell.z <= _owned_size.z

func _edge_owner(gx: int, gy: int, gz: int, cells: Array, owner_offset: Vector3i, axis: int) -> Vector3i:
	var anchor := Vector3i(gx, gy, gz)
	var octant := anchor + owner_offset
	var fallback := NO_CELL
	for offset: Vector3i in cells:
		var cell := anchor + offset
		if not _grid_cell(cell):
			return NO_CELL
		if not _has_chunk(cell):
			continue
		if _solid_at(_cell_min + cell):
			return cell
		if fallback == NO_CELL:
			fallback = cell
	if fallback != NO_CELL:
		return fallback
	for side in 2:
		var cell := anchor
		cell[axis] += side
		if _grid_cell(cell) and _has_chunk(cell) and _solid_at(_cell_min + cell):
			return cell
	return octant

func _grid_cell(cell: Vector3i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.z >= 0 and cell.x < _cell_size.x and cell.y < _cell_size.y and cell.z < _cell_size.z

func _has_chunk(cell: Vector3i) -> bool:
	return _frame.chunks.has(VoxelFrame.chunk_position(_cell_min + cell))

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
		degenerate_triangles += 1
		return
	normal = normal.normalized()
	var centroid := (a + b + c) / 3.0
	var cell := _face_source(centroid, normal, [first, second, third])
	var material := _material_for_cell(cell) if cell != NO_CELL else VoxelFrame.material(Color.MAGENTA)
	_mesh_triangles.append(first)
	_mesh_triangles.append(second)
	_mesh_triangles.append(third)
	_mesh_materials.append(material)

func _edge_key(first: int, second: int) -> int:
	return mini(first, second) * _cell_positions.size() + maxi(first, second)

func _build_material_atlas(shared_atlas: RefCounted, shared_material_uvs: Dictionary) -> void:
	if not shared_material_uvs.is_empty():
		atlas = shared_atlas
		material_uvs = shared_material_uvs
		return
	atlas = shared_atlas if shared_atlas != null else ATLAS.new()
	var patches := {}
	for material in _mesh_materials:
		if patches.has(material):
			continue
		patches[material] = atlas.add_patch(material, Vector2i.ONE)
	if atlas.bake(func(_progress: int) -> bool: return true) != OK:
		return
	material_uvs = {}
	for material in patches:
		var corners: PackedVector2Array = atlas.patch_uvs(patches[material])
		material_uvs[material] = (corners[0] + corners[2]) * 0.5

func _build_vertex_ao() -> void:
	_vertex_ao = PackedFloat32Array()
	_vertex_ao.resize(_cell_positions.size())
	_vertex_ao.fill(1.0)
	if ao_strength <= 0.0:
		return
	var normals := PackedVector3Array()
	normals.resize(_cell_positions.size())
	for triangle in range(0, _mesh_triangles.size(), 3):
		var first := _mesh_triangles[triangle]
		var second := _mesh_triangles[triangle + 1]
		var third := _mesh_triangles[triangle + 2]
		var normal := (_cell_positions[second] - _cell_positions[first]).cross(_cell_positions[third] - _cell_positions[first])
		normals[first] += normal
		normals[second] += normal
		normals[third] += normal
	for index in normals.size():
		normals[index] = normals[index].normalized()
	for index in _cell_positions.size():
		var normal := normals[index]
		if normal.length_squared() < 0.5:
			continue
		var vertex := _cell_positions[index]
		var source := NO_CELL
		var best := 1.0e9
		for cell: Vector3i in _cell_solids[index]:
			var distance := vertex.distance_squared_to(Vector3(cell) + Vector3.ONE * 0.5)
			if distance < best:
				best = distance
				source = cell
		if source == NO_CELL:
			continue
		var axis := normal.abs().max_axis_index()
		var direction := 1 if normal[axis] > 0.0 else -1
		var outside := source
		outside[axis] += direction
		if _solid_at(outside):
			continue
		var first_axis := (axis + 1) % 3
		var second_axis := (axis + 2) % 3
		var far_first := 1 if vertex[first_axis] > source[first_axis] + 0.5 else -1
		var far_second := 1 if vertex[second_axis] > source[second_axis] + 0.5 else -1
		var side_first := outside
		side_first[first_axis] += far_first
		var side_second := outside
		side_second[second_axis] += far_second
		var diagonal := side_first
		diagonal[second_axis] += far_second
		var level := _ao_level(_solid_at(side_first), _solid_at(side_second), _solid_at(diagonal))
		_vertex_ao[index] = 1.0 - (1.0 - AO_LEVELS[level]) * ao_strength

static func _ao_level(first: bool, second: bool, diagonal: bool) -> int:
	if first and second:
		return 0
	return 3 - (1 if first else 0) - (1 if second else 0) - (1 if diagonal else 0)

func _solid_at(cell: Vector3i) -> bool:
	var x := cell.x - _grid_min.x
	var y := cell.y - _grid_min.y
	var z := cell.z - _grid_min.z
	if x < 0 or x >= _grid_size.x or y < 0 or y >= _grid_size.y or z < 0 or z >= _grid_size.z:
		return false
	return _solid[_grid_index(x, y, z)] != 0

func _expand() -> void:
	var smooth := PackedVector3Array()
	if smooth_normals:
		smooth.resize(_cell_positions.size())
		for triangle in range(0, _mesh_triangles.size(), 3):
			var first := _mesh_triangles[triangle]
			var second := _mesh_triangles[triangle + 1]
			var third := _mesh_triangles[triangle + 2]
			var normal := (_cell_positions[second] - _cell_positions[first]).cross(_cell_positions[third] - _cell_positions[first])
			smooth[first] += normal
			smooth[second] += normal
			smooth[third] += normal
		for index in smooth.size():
			smooth[index] = smooth[index].normalized()
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
		var first_normal := smooth[first] if smooth_normals else normal
		var second_normal := smooth[second] if smooth_normals else normal
		var third_normal := smooth[third] if smooth_normals else normal
		if first_normal.length_squared() < 0.5:
			first_normal = normal
		if second_normal.length_squared() < 0.5:
			second_normal = normal
		if third_normal.length_squared() < 0.5:
			third_normal = normal
		var uv: Vector2 = material_uvs.get(_mesh_materials[triangle / 3], Vector2.ZERO)
		var first_ao := _vertex_ao[first]
		var second_ao := _vertex_ao[second]
		var third_ao := _vertex_ao[third]
		var base := _positions.size()
		_positions.append(a - _origin)
		_positions.append(b - _origin)
		_positions.append(c - _origin)
		_normals.append(first_normal)
		_normals.append(second_normal)
		_normals.append(third_normal)
		_colors.append(Color(first_ao, first_ao, first_ao, 1.0))
		_colors.append(Color(second_ao, second_ao, second_ao, 1.0))
		_colors.append(Color(third_ao, third_ao, third_ao, 1.0))
		_uvs.append(uv)
		_uvs.append(uv)
		_uvs.append(uv)
		_indices.append(base)
		_indices.append(base + 2)
		_indices.append(base + 1)
