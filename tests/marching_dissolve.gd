extends "res://tests/test.gd"


const FIXTURE := preload("res://tests/helpers/marching_fixture.gd")
const VIEW := preload("res://tests/helpers/marching_view.gd")
const NORMAL_LIMIT := 8.05
const COLOUR_LIMIT := 0.021
const AREA_LIMIT := 0.02
const EXPECTED_VERTICES := 574
const EXPECTED_TRIANGLES := 1006
const EXPECTED_HASH := 1856081747413111391

var _frame: VoxelFrame
var _merged: Array
var _dissolved: Array
var _merged_materials := PackedInt32Array()
var _dissolved_materials := PackedInt32Array()
var _removed: Dictionary
var _warning := 0.0
var _mean := 0.0
var _colour := 0.0
var _errors := 0
var _dissolver
var _dissolved_polygon := PackedInt32Array()
var _polygon_corners: Array = []


func _ready() -> void:
	timeout = 120.0
	test("the smooth mesh dissolves curved vertices beyond the constant-normal merge", _curve_dissolve, "dissolve_curve")
	test("the dissolve keeps the surface closed, manifold, and single-material", _dissolve_topology, "dissolve_topology")
	test("the dissolve keeps the smooth normal and colour field", _dissolve_normals, "dissolve_normals")
	test("the dissolve keeps the seams and the material coverage", _dissolve_seams, "dissolve_seams")
	test("the dissolved smooth geometry keeps its snapshot", _dissolve_snapshot, "dissolve_snapshot")
	test("a concave link polygon triangulates inside itself", _dissolve_concave_polygon, "dissolve_concave_polygon")
	test("no seam vertex dissolves after its neighbours", _dissolve_sphere_seams, "dissolve_sphere_seams")
	test("a concave link stays inside its polygon", _dissolve_concave, "dissolve_concave")
	test("every accepted diagonal enters the edge set", _dissolve_edges, "dissolve_edges")


func before_test() -> void:
	_frame = VoxelFrame.new()
	_frame.set_cells(_fixture_cells())
	var merged_builder := VoxelMarchingMeshBuilder.new()
	merged_builder.smooth_normals = true
	merged_builder.merge_coplanar = true
	merged_builder.dissolve_limited = false
	merged_builder.source_frame = _frame
	merged_builder.chunk_location = Vector3i.ZERO
	merged_builder.run()
	_merged = merged_builder.surface_arrays
	_merged_materials = merged_builder.vertex_materials
	var dissolved_builder := VoxelMarchingMeshBuilder.new()
	_dissolver = dissolved_builder
	dissolved_builder.smooth_normals = true
	dissolved_builder.merge_coplanar = true
	dissolved_builder.source_frame = _frame
	dissolved_builder.chunk_location = Vector3i.ZERO
	dissolved_builder.run()
	_dissolved = dissolved_builder.surface_arrays
	_dissolved_materials = dissolved_builder.vertex_materials
	_removed = _removed_positions(_merged, _dissolved)
	_measure_errors()


func _fixture_cells() -> Dictionary:
	var cells := {}
	var first := VoxelFrame.material(Color(0.85, 0.2, 0.15))
	var second := VoxelFrame.material(Color(0.2, 0.35, 0.9))
	var centre := Vector3(7.5, 7.5, 7.5)
	for z in range(4, 12):
		for y in range(4, 12):
			for x in range(4, 12):
				var offset := Vector3(x, y, z) - centre
				if offset.length_squared() > 16.0:
					continue
				cells[Vector3i(x, y, z)] = first if x < 7 else second
	for x in range(4, 9):
		for z in range(4, 9):
			cells[Vector3i(x, 1, z)] = first
	return cells


func _curve_dissolve() -> void:
	step("Given a smooth two-material shell and a creased plate in one chunk", func():
		expect(not _merged[Mesh.ARRAY_INDEX].is_empty(), "the fixture builds a surface")
	)
	step("Then the limited dissolve removes triangles beyond the coplanar merge", func():
		var merged_indices: PackedInt32Array = _merged[Mesh.ARRAY_INDEX]
		var dissolved_indices: PackedInt32Array = _dissolved[Mesh.ARRAY_INDEX]
		var merged_positions: PackedVector3Array = _merged[Mesh.ARRAY_VERTEX]
		var dissolved_positions: PackedVector3Array = _dissolved[Mesh.ARRAY_VERTEX]
		var merged_triangles := merged_indices.size() / 3
		var dissolved_triangles := dissolved_indices.size() / 3
		var merged_vertices := merged_positions.size()
		var dissolved_vertices := dissolved_positions.size()
		expect(merged_triangles > 0, "the merged surface has triangles")
		expect(dissolved_triangles < merged_triangles, "the dissolve removes triangles")
		expect(not _removed.is_empty(), "the dissolve removes vertices")
		expect((merged_vertices - dissolved_vertices) * 2 == merged_triangles - dissolved_triangles, "each removed vertex removes two triangles")
	)


func _dissolve_topology() -> void:
	step("When the dissolved surface is checked", func():
		var positions: PackedVector3Array = _dissolved[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = _dissolved[Mesh.ARRAY_INDEX]
		var view = VIEW.new(self)
		view.positions = positions
		view.indices = indices
		expect(view.closed(), "the dissolved surface has no boundary")
		expect(view.duplicates() == 0, "no triangle is emitted twice")
		var mesh := _mesh_edges(positions, indices, {})
		var edges: Dictionary = mesh["edges"]
		var boundary := 0
		var nonmanifold := 0
		var inconsistent := 0
		for key: Vector2i in edges:
			var entry: Array = edges[key]
			if entry[0] == 1:
				boundary += 1
			elif entry[0] > 2:
				nonmanifold += 1
			elif entry[0] == 2 and entry[1] != 1:
				inconsistent += 1
		expect(boundary == 0, "every edge keeps two triangles")
		expect(nonmanifold == 0, "no edge joins more than two triangles")
		expect(inconsistent == 0, "every edge keeps one winding")
		var zero := 0
		var flipped := 0
		var mixed := 0
		for triangle in indices.size() / 3:
			var base := triangle * 3
			var first := positions[indices[base]]
			var second := positions[indices[base + 1]]
			var third := positions[indices[base + 2]]
			var winding := (second - first).cross(third - first)
			var outward: Vector3 = _dissolved[Mesh.ARRAY_NORMAL][indices[base]]
			if winding.length_squared() < 0.0000000001:
				zero += 1
			elif winding.normalized().dot(outward) >= 0.0:
				flipped += 1
			if _dissolved_materials[indices[base]] != _dissolved_materials[indices[base + 1]] or _dissolved_materials[indices[base + 1]] != _dissolved_materials[indices[base + 2]]:
				mixed += 1
		expect(zero == 0, "no triangle has zero area")
		expect(flipped == 0, "every triangle points inward against its shading normal")
		expect(mixed == 0, "every triangle keeps one material")
	)


func _dissolve_normals() -> void:
	step("Given each removed vertex and its new triangles", func():
		expect(_errors > 0, "the fixture removes at least one vertex")
	)
	step("Then the interpolated normal and colour stay in tolerance", func():
		expect(_warning <= NORMAL_LIMIT, "every removed vertex keeps its normal within eight degrees")
		expect(_mean <= 2.0, "the mean normal error stays within two degrees")
		expect(_colour <= COLOUR_LIMIT, "every removed vertex keeps its colour within tolerance")
	)


func _dissolve_snapshot() -> void:
	step("Given the deterministic dissolved smooth chunk", func():
		var positions: PackedVector3Array = _dissolved[Mesh.ARRAY_VERTEX]
		var triangles: PackedInt32Array = _dissolved[Mesh.ARRAY_INDEX]
		var hash := FIXTURE.geometry_hash(_dissolved, Vector3i.ZERO, 5381)
		print("MEASURE dissolve_snapshot: vertices=%d triangles=%d removed=%d warning=%.3f mean=%.3f colour=%.5f hash=%d" % [
			positions.size(), triangles.size() / 3, _removed.size(), _warning, _mean, _colour, hash,
		])
		expect(positions.size() == EXPECTED_VERTICES, "the dissolved mesh keeps its vertex count")
		expect(triangles.size() / 3 == EXPECTED_TRIANGLES, "the dissolved mesh keeps its triangle count")
		expect(hash == EXPECTED_HASH, "the dissolved mesh keeps every position, normal, colour, UV, and index")
	)


func _dissolve_seams() -> void:
	step("Given the seam edges of the merged surface", func():
		var map := {}
		var merged := _mesh_edges(_merged[Mesh.ARRAY_VERTEX], _merged[Mesh.ARRAY_INDEX], map)
		var seam := _seam_pairs(_merged[Mesh.ARRAY_VERTEX], _merged[Mesh.ARRAY_INDEX], _merged_materials, merged)
		var dissolved := _mesh_edges(_dissolved[Mesh.ARRAY_VERTEX], _dissolved[Mesh.ARRAY_INDEX], map)
		var dissolved_positions := _position_set(_dissolved[Mesh.ARRAY_VERTEX])
		expect(merged["edges"].size() > 0, "the merged surface has edges")
		expect(seam["edges"].size() > 0, "the fixture has seam edges")
		var missing := 0
		for key: Vector2i in seam["edges"]:
			if not dissolved["edges"].has(key):
				missing += 1
		for key: Vector3i in seam["vertices"]:
			if not dissolved_positions.has(key):
				missing += 1
		expect(missing == 0, "every seam edge and seam vertex stays in the dissolved surface")
	)
	step("Then the material coverage stays within tolerance on both sides", func():
		var merged_sides := _material_sides(_merged)
		var dissolved_sides := _material_sides(_dissolved)
		expect(merged_sides.size() >= 2, "the fixture has two materials")
		for key: String in merged_sides:
			expect(dissolved_sides.has(key), "the dissolved surface keeps the material %s" % key)
			if not dissolved_sides.has(key):
				continue
			expect(absf(merged_sides[key] - dissolved_sides[key]) <= AREA_LIMIT * maxf(merged_sides[key], 1.0), "the material area changes less than two percent")
	)


func _dissolve_sphere_seams() -> void:
	step("Given a smooth sphere with many dissolvable neighbours", func():
		var sphere := VoxelFrame.new()
		var cells := {}
		var material := VoxelFrame.material(Color(0.8, 0.2, 0.1))
		for z in range(0, 16):
			for y in range(0, 16):
				for x in range(0, 16):
					var offset := Vector3(x, y, z) - Vector3(7.5, 7.5, 7.5)
					if offset.length_squared() > 25.0:
						continue
					cells[Vector3i(x, y, z)] = material
		sphere.set_cells(cells)
		var merged_builder := VoxelMarchingMeshBuilder.new()
		merged_builder.smooth_normals = true
		merged_builder.dissolve_limited = false
		merged_builder.source_frame = sphere
		merged_builder.chunk_location = Vector3i.ZERO
		merged_builder.run()
		var dissolved_builder := VoxelMarchingMeshBuilder.new()
		dissolved_builder.smooth_normals = true
		dissolved_builder.source_frame = sphere
		dissolved_builder.chunk_location = Vector3i.ZERO
		dissolved_builder.run()
		var map := {}
		var merged := _mesh_edges(merged_builder.surface_arrays[Mesh.ARRAY_VERTEX], merged_builder.surface_arrays[Mesh.ARRAY_INDEX], map)
		var seam := _seam_pairs(merged_builder.surface_arrays[Mesh.ARRAY_VERTEX], merged_builder.surface_arrays[Mesh.ARRAY_INDEX], merged_builder.vertex_materials, merged)
		var dissolved := _mesh_edges(dissolved_builder.surface_arrays[Mesh.ARRAY_VERTEX], dissolved_builder.surface_arrays[Mesh.ARRAY_INDEX], map)
		var dissolved_positions := _position_set(dissolved_builder.surface_arrays[Mesh.ARRAY_VERTEX])
		expect(merged["edges"].size() > 0, "the sphere builds a surface")
		expect(seam["edges"].size() > 0, "the sphere has seam edges")
		var missing := 0
		for key: Vector2i in seam["edges"]:
			if not dissolved["edges"].has(key):
				missing += 1
		for key: Vector3i in seam["vertices"]:
			if not dissolved_positions.has(key):
				missing += 1
		expect(missing == 0, "no seam edge or seam vertex dissolves after its neighbours")
		expect(merged_builder.surface_arrays[Mesh.ARRAY_INDEX].size() > dissolved_builder.surface_arrays[Mesh.ARRAY_INDEX].size(), "the sphere loses triangles")
	)


func _dissolve_concave_polygon() -> void:
	step("Given a concave link polygon in the builder plane", func():
		var builder := VoxelMarchingMeshBuilder.new()
		var flat := PackedVector2Array()
		flat.resize(16)
		var points := PackedVector3Array()
		points.resize(16)
		var normals := PackedVector3Array()
		normals.resize(16)
		var colours := PackedColorArray()
		colours.resize(16)
		var corners := [
			Vector2(0.0, 0.0), Vector2(3.0, 0.0), Vector2(3.0, 3.0), Vector2(2.0, 3.0),
			Vector2(2.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 3.0), Vector2(0.0, 3.0),
		]
		for index in 8:
			var corner: Vector2 = corners[index]
			flat[index] = corner
			points[index] = Vector3(corner.x, corner.y, 0.0)
			normals[index] = Vector3.BACK
			colours[index] = Color.WHITE
		builder._dissolve_flat = flat
		builder._dissolve_points = points
		builder._dissolve_normals = normals
		builder._dissolve_colours = colours
		builder._dissolve_outward = Vector3.FORWARD
		builder._dissolve_removed_position = Vector3(1.5, 1.5, 0.0)
		builder._dissolve_removed_normal = Vector3.BACK
		builder._dissolve_removed_colour = Color.WHITE
		builder._dissolve_flat_point = Vector2(1.5, 1.5)
		_dissolved_polygon = builder._dissolve_triangulate(8)
		_polygon_corners = corners
		expect(_dissolved_polygon.size() == 18, "the concave link becomes six triangles")
	)
	step("Then every new triangle lies inside the polygon once", func():
		var flat := PackedVector2Array()
		var corners: Array = _polygon_corners
		var area := 0.0
		for index in corners.size():
			var current: Vector2 = corners[index]
			var follow: Vector2 = corners[(index + 1) % corners.size()]
			area += current.cross(follow)
		var covered := 0.0
		var outside := 0
		for triangle in _dissolved_polygon.size() / 3:
			var first: Vector2 = corners[_dissolved_polygon[triangle * 3]]
			var second: Vector2 = corners[_dissolved_polygon[triangle * 3 + 1]]
			var third: Vector2 = corners[_dissolved_polygon[triangle * 3 + 2]]
			var triangle_area := (second - first).cross(third - first)
			if triangle_area <= 0.0:
				outside += 1
				continue
			covered += triangle_area
			flat.resize(corners.size())
			for index in corners.size():
				flat[index] = corners[index]
			if not _inside_polygon((first + second + third) / 3.0, flat):
				outside += 1
		expect(outside == 0, "no triangle of the concave link lies outside the polygon")
		expect(absf(covered - area) < 0.01 * maxf(area, 1.0), "the triangles cover the polygon area once")
	)


func _dissolve_concave() -> void:
	step("Given every removed vertex and its ordered link", func():
		var before_positions: PackedVector3Array = _merged[Mesh.ARRAY_VERTEX]
		var before_indices: PackedInt32Array = _merged[Mesh.ARRAY_INDEX]
		var after_positions: PackedVector3Array = _dissolved[Mesh.ARRAY_VERTEX]
		var after_indices: PackedInt32Array = _dissolved[Mesh.ARRAY_INDEX]
		var before_triangles := _triangles_by_vertex(before_indices)
		var after_by_position := _triangles_by_position(after_positions, after_indices)
		var concave_links := 0
		var checked := 0
		var outside := 0
		var overlap := 0
		var uncovered := 0
		for key: Vector3i in _removed:
			var vertex: int = _removed[key]
			var cycle := _link_cycle(vertex, before_indices, before_triangles)
			if cycle.size() < 4:
				continue
			var polygon := _link_polygon(cycle, before_positions)
			if polygon.is_empty():
				continue
			var flat: PackedVector2Array = polygon["flat"]
			var count := cycle.size()
			var area := 0.0
			var is_concave := false
			for index in count:
				var first := flat[index]
				var second := flat[(index + 1) % count]
				var third := flat[(index + 2) % count]
				area += first.cross(second)
				if (second - first).cross(third - second) <= 0.0:
					is_concave = true
			if is_concave:
				concave_links += 1
			var link := {}
			for index in count:
				link[_key(before_positions[cycle[index]])] = true
			var replacement := PackedInt32Array()
			for link_key: Vector3i in link:
				for triangle: int in after_by_position.get(link_key, []):
					if replacement.has(triangle):
						continue
					var inside := true
					for corner in 3:
						if not link.has(_key(after_positions[after_indices[triangle * 3 + corner]])):
							inside = false
					if inside:
						replacement.append(triangle)
			if replacement.size() != count - 2:
				continue
			checked += 1
			var covered := 0.0
			for triangle in replacement:
				var first := _project(after_positions[after_indices[triangle * 3]], polygon)
				var second := _project(after_positions[after_indices[triangle * 3 + 1]], polygon)
				var third := _project(after_positions[after_indices[triangle * 3 + 2]], polygon)
				var triangle_area := (second - first).cross(third - first)
				if triangle_area <= 0.0:
					outside += 1
					continue
				covered += triangle_area * 0.5
				if not _inside_polygon((first + second + third) / 3.0, flat):
					outside += 1
			if absf(covered - area * 0.5) > 0.01 * maxf(area * 0.5, 1.0):
				overlap += 1
		expect(checked > 20, "the fixture dissolves enough links to check")
		expect(concave_links > 0, "at least one removed link is concave")
		expect(outside == 0, "no new triangle lies outside the link polygon")
		expect(overlap == 0, "the new triangles cover the link polygon once")
	)


func _dissolve_edges() -> void:
	step("Given the builder after the dissolve", func():
		expect(_removed.size() >= 90, "the fixture dissolves enough vertices to add many diagonals")
		var edge_set: Dictionary = _dissolver._dissolve_edge_set
		var merged_indices: PackedInt32Array = _merged[Mesh.ARRAY_INDEX]
		var merged_edges := {}
		for triangle in merged_indices.size() / 3:
			for corner in 3:
				var first := mini(merged_indices[triangle * 3 + corner], merged_indices[triangle * 3 + (corner + 1) % 3])
				var second := maxi(merged_indices[triangle * 3 + corner], merged_indices[triangle * 3 + (corner + 1) % 3])
				merged_edges[(first << 32) | second] = true
		expect(edge_set.size() > merged_edges.size(), "each accepted diagonal enters the edge set")
		expect(edge_set.size() - merged_edges.size() >= _removed.size(), "the edge set keeps at least one diagonal for each removed vertex")
	)


func _triangles_by_vertex(indices: PackedInt32Array) -> Dictionary:
	var triangles := {}
	for triangle in indices.size() / 3:
		for corner in 3:
			var vertex := indices[triangle * 3 + corner]
			var list: Array = triangles.get(vertex, [])
			list.append(triangle)
			triangles[vertex] = list
	return triangles


func _triangles_by_position(positions: PackedVector3Array, indices: PackedInt32Array) -> Dictionary:
	var triangles := {}
	for triangle in indices.size() / 3:
		for corner in 3:
			var key := _key(positions[indices[triangle * 3 + corner]])
			var list: Array = triangles.get(key, [])
			if list.is_empty() or list[-1] != triangle:
				list.append(triangle)
			triangles[key] = list
	return triangles


func _link_cycle(vertex: int, indices: PackedInt32Array, triangles: Dictionary) -> PackedInt32Array:
	var next := {}
	var start := -1
	for triangle: int in triangles.get(vertex, []):
		var base := triangle * 3
		var corner := 0
		while indices[base + corner] != vertex:
			corner += 1
		var first := indices[base + (corner + 1) % 3]
		var second := indices[base + (corner + 2) % 3]
		if next.has(first):
			return PackedInt32Array()
		next[first] = second
		if start < 0:
			start = first
	if start < 0:
		return PackedInt32Array()
	var cycle := PackedInt32Array()
	var current := start
	while cycle.size() <= next.size():
		cycle.append(current)
		if not next.has(current):
			return PackedInt32Array()
		current = next[current]
		if current == start:
			return cycle
	return PackedInt32Array()


func _link_polygon(cycle: PackedInt32Array, positions: PackedVector3Array) -> Dictionary:
	var normal := Vector3.ZERO
	for index in cycle.size():
		var current := positions[cycle[index]]
		var follow := positions[cycle[(index + 1) % cycle.size()]]
		normal.x += (current.y - follow.y) * (current.z + follow.z)
		normal.y += (current.z - follow.z) * (current.x + follow.x)
		normal.z += (current.x - follow.x) * (current.y + follow.y)
	if normal.length_squared() < 0.0000000001:
		return {}
	normal = normal.normalized()
	var axis := Vector3.RIGHT
	if absf(normal.y) <= absf(normal.x) and absf(normal.y) <= absf(normal.z):
		axis = Vector3.UP
	elif absf(normal.z) <= absf(normal.x):
		axis = Vector3.FORWARD
	var across := normal.cross(axis)
	if across.length_squared() < 0.0000000001:
		return {}
	across = across.normalized()
	var down := normal.cross(across)
	var flat := PackedVector2Array()
	flat.resize(cycle.size())
	var direction := 1.0
	for pass_index in 2:
		for index in cycle.size():
			var point := positions[cycle[index]]
			flat[index] = Vector2(point.dot(across), point.dot(down) * direction)
		var area := 0.0
		for index in cycle.size():
			area += flat[index].cross(flat[(index + 1) % cycle.size()])
		if area > 0.0:
			break
		direction = -1.0
	return {"flat": flat, "across": across, "down": down, "direction": direction, "normal": normal}


func _project(point: Vector3, polygon: Dictionary) -> Vector2:
	return Vector2(point.dot(polygon["across"]), point.dot(polygon["down"]) * polygon["direction"])


static func _inside_polygon(point: Vector2, flat: PackedVector2Array) -> bool:
	var inside := false
	for index in flat.size():
		var current := flat[index]
		var follow := flat[(index + 1) % flat.size()]
		if (current.y > point.y) == (follow.y > point.y):
			continue
		var crossing := current.x + (point.y - current.y) * (follow.x - current.x) / (follow.y - current.y)
		if point.x < crossing:
			inside = not inside
	return inside


func _material_sides(arrays: Array) -> Dictionary:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var sides := {}
	for triangle in indices.size() / 3:
		var first := positions[indices[triangle * 3]]
		var second := positions[indices[triangle * 3 + 1]]
		var third := positions[indices[triangle * 3 + 2]]
		var area := (second - first).cross(third - first).length() * 0.5
		var colour := colours[indices[triangle * 3]]
		var key := "red" if colour.r > colour.b else "blue"
		sides[key] = sides.get(key, 0.0) + area
	return sides


func _removed_positions(before: Array, after: Array) -> Dictionary:
	var remaining := _position_set(after[Mesh.ARRAY_VERTEX])
	var removed := {}
	var positions: PackedVector3Array = before[Mesh.ARRAY_VERTEX]
	for index in positions.size():
		var key := _key(positions[index])
		if remaining.has(key):
			continue
		removed[key] = index
	return removed


func _measure_errors() -> void:
	var before_positions: PackedVector3Array = _merged[Mesh.ARRAY_VERTEX]
	var before_normals: PackedVector3Array = _merged[Mesh.ARRAY_NORMAL]
	var before_colours: PackedColorArray = _merged[Mesh.ARRAY_COLOR]
	var before_indices: PackedInt32Array = _merged[Mesh.ARRAY_INDEX]
	var after_positions: PackedVector3Array = _dissolved[Mesh.ARRAY_VERTEX]
	var after_normals: PackedVector3Array = _dissolved[Mesh.ARRAY_NORMAL]
	var after_colours: PackedColorArray = _dissolved[Mesh.ARRAY_COLOR]
	var after_indices: PackedInt32Array = _dissolved[Mesh.ARRAY_INDEX]
	var triangles_of := {}
	for triangle in after_indices.size() / 3:
		for corner in 3:
			var key := _key(after_positions[after_indices[triangle * 3 + corner]])
			if triangles_of.has(key):
				var list: Array = triangles_of[key]
				list.append(triangle)
			else:
				triangles_of[key] = [triangle]
	var before_triangles := {}
	for triangle in before_indices.size() / 3:
		for corner in 3:
			var vertex := before_indices[triangle * 3 + corner]
			if before_triangles.has(vertex):
				var list: Array = before_triangles[vertex]
				list.append(triangle)
			else:
				before_triangles[vertex] = [triangle]
	var total := 0.0
	for key: Vector3i in _removed:
		var vertex: int = _removed[key]
		var position := before_positions[vertex]
		var link := {}
		for triangle: int in before_triangles.get(vertex, []):
			for corner in 3:
				var other := before_indices[triangle * 3 + corner]
				if other != vertex:
					link[_key(before_positions[other])] = true
		var candidates := {}
		for link_key: Vector3i in link:
			for triangle: int in triangles_of.get(link_key, []):
				candidates[triangle] = true
		var best := INF
		var best_covering := false
		var best_normal := Vector3.ZERO
		var best_colour := Color.WHITE
		var inside_count := 0
		for triangle: int in candidates:
			var base := triangle * 3
			var inside := true
			for corner in 3:
				if not link.has(_key(after_positions[after_indices[base + corner]])):
					inside = false
			if not inside:
				continue
			inside_count += 1
			var a := after_positions[after_indices[base]]
			var b := after_positions[after_indices[base + 1]]
			var c := after_positions[after_indices[base + 2]]
			var raw := _raw_barycentric(position, a, b, c)
			var covering := raw.x > -0.001 and raw.y > -0.001 and raw.z > -0.001
			var weights := _clamped(raw)
			var closest := a * weights.x + b * weights.y + c * weights.z
			var distance := position.distance_squared_to(closest)
			if covering and not best_covering:
				best = distance
				best_covering = true
			elif covering == best_covering and distance < best:
				best = distance
			else:
				continue
			best_normal = (after_normals[after_indices[base]] * weights.x + after_normals[after_indices[base + 1]] * weights.y + after_normals[after_indices[base + 2]] * weights.z).normalized()
			best_colour = after_colours[after_indices[base]] * weights.x + after_colours[after_indices[base + 1]] * weights.y + after_colours[after_indices[base + 2]] * weights.z
		if best == INF:
			continue
		var intact := inside_count == link.size() - 2
		if not intact:
			continue
		var angle := rad_to_deg(before_normals[vertex].angle_to(best_normal))
		var colour := maxf(maxf(absf(before_colours[vertex].r - best_colour.r), absf(before_colours[vertex].g - best_colour.g)), absf(before_colours[vertex].b - best_colour.b))
		_warning = maxf(_warning, angle)
		_colour = maxf(_colour, colour)
		total += angle
		_errors += 1
	_mean = total / maxf(1.0, float(_errors))


static func _raw_barycentric(point: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var normal := (b - a).cross(c - a)
	var squared := normal.length_squared()
	if squared < 0.0000000001:
		return Vector3(1, 0, 0)
	var weight_b := (c - a).cross(point - a).dot(normal) / squared
	var weight_c := (b - a).cross(point - a).dot(normal) / squared
	return Vector3(1.0 - weight_b - weight_c, weight_b, weight_c)


static func _clamped(weights: Vector3) -> Vector3:
	var weight_a := clampf(weights.x, 0.0, 1.0)
	var weight_b := clampf(weights.y, 0.0, 1.0)
	var weight_c := clampf(weights.z, 0.0, 1.0)
	var total := weight_a + weight_b + weight_c
	if total <= 0.0:
		return Vector3(1, 0, 0)
	return Vector3(weight_a / total, weight_b / total, weight_c / total)


func _seam_pairs(positions: PackedVector3Array, indices: PackedInt32Array, materials: PackedInt32Array, mesh: Dictionary) -> Dictionary:
	var pairs := {}
	var vertices := {}
	var ids: PackedInt32Array = mesh["ids"]
	for triangle in indices.size() / 3:
		for corner in 3:
			var first := ids[indices[triangle * 3 + corner]]
			var second := ids[indices[triangle * 3 + (corner + 1) % 3]]
			var edge := Vector2i(mini(first, second), maxi(first, second))
			var entry: Array = pairs.get(edge, [])
			entry.append(triangle)
			pairs[edge] = entry
	var seams := {}
	for edge: Vector2i in pairs:
		var list: Array = pairs[edge]
		var flagged := list.size() != 2
		if not flagged:
			flagged = _triangle_normal(positions, indices, list[0]).dot(_triangle_normal(positions, indices, list[1])) < 0.9063077870366499
		if not flagged:
			flagged = materials[indices[list[0] * 3]] != materials[indices[list[1] * 3]]
		if not flagged:
			continue
		seams[edge] = true
		vertices[mesh["points"][edge.x]] = true
		vertices[mesh["points"][edge.y]] = true
	return {"edges": seams, "vertices": vertices}


func _mesh_edges(positions: PackedVector3Array, indices: PackedInt32Array, map: Dictionary) -> Dictionary:
	var ids := PackedInt32Array()
	ids.resize(positions.size())
	for index in positions.size():
		var key := _key(positions[index])
		if not map.has(key):
			map[key] = map.size()
		ids[index] = map[key]
	var points := {}
	for key: Vector3i in map:
		points[map[key]] = key
	var edges := {}
	for triangle in indices.size() / 3:
		for corner in 3:
			var first := ids[indices[triangle * 3 + corner]]
			var second := ids[indices[triangle * 3 + (corner + 1) % 3]]
			if first == second:
				continue
			var key := Vector2i(mini(first, second), maxi(first, second))
			var entry: Array = edges.get(key, [0, 0])
			entry[0] += 1
			if first > second:
				entry[1] += 1
			edges[key] = entry
	return {"ids": ids, "edges": edges, "points": points}


func _position_set(positions: PackedVector3Array) -> Dictionary:
	var keys := {}
	for position: Vector3 in positions:
		keys[_key(position)] = true
	return keys


static func _key(point: Vector3) -> Vector3i:
	return Vector3i(roundi(point.x * 1024.0), roundi(point.y * 1024.0), roundi(point.z * 1024.0))


static func _triangle_normal(positions: PackedVector3Array, indices: PackedInt32Array, triangle: int) -> Vector3:
	var first := positions[indices[triangle * 3]]
	var winding := (positions[indices[triangle * 3 + 1]] - first).cross(positions[indices[triangle * 3 + 2]] - first)
	if winding.length_squared() < 0.0000000001:
		return Vector3.ZERO
	return -winding.normalized()




