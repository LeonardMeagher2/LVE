extends "res://tests/test.gd"


const FIXTURE := preload("res://tests/helpers/marching_fixture.gd")
const VIEW := preload("res://tests/helpers/marching_view.gd")
const NORMAL_LIMIT := 8.05
const COLOUR_LIMIT := 0.021
const AREA_LIMIT := 0.02
const EXPECTED_VERTICES := 567
const EXPECTED_TRIANGLES := 992
const EXPECTED_HASH := -5756327514759218800

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


func _ready() -> void:
	timeout = 120.0
	test("the smooth mesh dissolves curved vertices beyond the constant-normal merge", _curve_dissolve, "dissolve_curve")
	test("the dissolve keeps the surface closed, manifold, and single-material", _dissolve_topology, "dissolve_topology")
	test("the dissolve keeps the smooth normal and colour field", _dissolve_normals, "dissolve_normals")
	test("the dissolve keeps the seams and the material coverage", _dissolve_seams, "dissolve_seams")
	test("the dissolved smooth geometry keeps its snapshot", _dissolve_snapshot, "dissolve_snapshot")


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

