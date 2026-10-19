extends "res://tests/test.gd"

const REGION := preload("res://Globals/Rendering/VoxelPlanarRegion.gd")
var fixtures: Array[Dictionary] = []
var meshes: Array[Array] = []
var mask_error := ""
var protected := {Vector2i(1, 0): true, Vector2i(3, 0): true, Vector2i(6, 1): true, Vector2i(2, 3): true, Vector2i(0, 2): true}


func _ready() -> void:
	timeout = 30.0
	test("planar regions preserve occupied cells, holes, and boundary vertices", _run)


func _run() -> void:
	step("Given rings, separate contacts, sparse cells, and a protected rectangle", func():
		var ring := _rectangle(Vector2i.ZERO, Vector2i(7, 7))
		for cell in _rectangle(Vector2i(2, 2), Vector2i(3, 3)):
			ring.erase(cell)
		var holes := _rectangle(Vector2i.ZERO, Vector2i(11, 9))
		for hole in [_rectangle(Vector2i(2, 2), Vector2i(2, 4)), _rectangle(Vector2i(6, 3), Vector2i(3, 3))]:
			for cell in hole:
				holes.erase(cell)
		var diagonal := {Vector2i.ZERO: true, Vector2i.ONE: true, Vector2i(2, 0): true}
		var sparse := {Vector2i(-4096, -4096): true, Vector2i(4096, 4096): true}
		fixtures = [ring, holes, diagonal, sparse, _rectangle(Vector2i.ZERO, Vector2i(6, 3))]
	)
	step("When every nonempty three-by-three mask and each fixture is triangulated", func():
		var samples := _rectangle(Vector2i(-1, -1), Vector2i(5, 5))
		for mask in range(1, 512):
			var cells := {}
			for bit in 9:
				if mask & (1 << bit):
					cells[Vector2i(bit % 3, bit / 3)] = true
			var error := _check_mesh(cells, REGION.triangulate(cells), samples)
			if not error.is_empty() and mask_error.is_empty():
				mask_error = "mask %d: %s" % [mask, error]
		for index in fixtures.size():
			meshes.append(REGION.triangulate(fixtures[index], protected if index == 4 else {}))
	)
	step("Then all masks and fixtures have positive CCW triangles and exact cell coverage", func():
		expect(mask_error.is_empty(), "all 511 masks preserve area and occupied and empty cell centers" + _detail(mask_error))
		var ring_error := _check_mesh(fixtures[0], meshes[0], _rectangle(Vector2i(-1, -1), Vector2i(9, 9)))
		expect(ring_error.is_empty() and _conforming(meshes[0]), "the seven-by-seven ring retains its three-by-three hole and conforming cuts" + _detail(ring_error))
		var holes_error := _check_mesh(fixtures[1], meshes[1], _rectangle(Vector2i(-1, -1), Vector2i(13, 11)))
		expect(holes_error.is_empty() and _conforming(meshes[1]), "multiple holes retain exact coverage and conforming cut boundaries" + _detail(holes_error))
		var diagonal_error := _check_mesh(fixtures[2], meshes[2], _rectangle(Vector2i(-1, -1), Vector2i(5, 4)))
		expect(diagonal_error.is_empty() and REGION.contours(fixtures[2]).size() == 3, "diagonal contacts retain three separate contours and exact coverage" + _detail(diagonal_error))
		var sparse_samples := {Vector2i.ZERO: true}
		for cell: Vector2i in fixtures[3]:
			sparse_samples.merge(_rectangle(cell - Vector2i.ONE, Vector2i(3, 3)))
		var sparse_error := _check_mesh(fixtures[3], meshes[3], sparse_samples)
		expect(sparse_error.is_empty(), "cells at negative and positive 4096 retain exact sparse coverage" + _detail(sparse_error))
	)
	step("Then protected collinear points remain indexed without triangle edges crossing them", func():
		var used := {}
		for mesh: Dictionary in meshes[4]:
			for index: int in mesh.indices:
				used[Vector2i(mesh.points[index])] = true
		var retained := true
		for point in protected:
			retained = retained and used.has(point)
		var error := _check_mesh(fixtures[4], meshes[4], _rectangle(Vector2i(-1, -1), Vector2i(8, 5)))
		expect(retained and error.is_empty() and _conforming(meshes[4]), "all protected boundary points belong to positive triangles without skipped vertices" + _detail(error))
		var reverse := {}
		var keys := fixtures[0].keys()
		keys.reverse()
		for cell in keys:
			reverse[cell] = true
		var turns := REGION.contours(fixtures[4])
		expect(turns.size() == 1 and turns[0].size() == 4 and REGION.contours(reverse) == REGION.contours(fixtures[0]) and REGION.triangulate(reverse) == meshes[0], "contours contain only turns and outputs are independent of cell insertion order")
	)
	step("Then internal diagonal flips improve an uneven concave outline without adding geometry", func():
		var cells := _rectangle(Vector2i.ZERO, Vector2i(12, 8))
		for cell in _rectangle(Vector2i(3, 3), Vector2i(9, 5)):
			cells.erase(cell)
		var points: PackedVector2Array = REGION.contours(cells)[0]
		var initial := Geometry2D.triangulate_polygon(points)
		var output := REGION.triangulate(cells)
		var same_counts := output.size() == 1
		var before := _minimum_angle(points, initial)
		var after := 0.0
		if same_counts:
			same_counts = output[0].points == points and output[0].indices.size() == initial.size()
			after = _minimum_angle(output[0].points, output[0].indices)
		var error := _check_mesh(cells, output, _rectangle(Vector2i(-1, -1), Vector2i(14, 10)))
		var rectangle: PackedVector2Array = REGION.contours(fixtures[4])[0]
		var ties := Geometry2D.triangulate_polygon(rectangle)
		var stable := REGION._improve(rectangle, ties.duplicate(), Callable()) == ties
		var translated := PackedVector2Array()
		for point in points:
			translated.append(point + Vector2(4096, -4096))
		stable = stable and output.size() == 1 and REGION._improve(translated, initial.duplicate(), Callable()) == output[0].indices
		var calls := [0]
		var stop: int = initial.size() / 3 + 2
		var cancel := func(_progress):
			calls[0] += 1
			return calls[0] != stop
		var cancelled: bool = REGION._improve(points, initial.duplicate(), cancel).is_empty() and calls[0] == stop
		expect(same_counts and after > before + 0.000001 and error.is_empty() and _conforming(output) and output == REGION.triangulate(cells) and stable and cancelled, "internal flips improve angles and preserve counts, boundaries, ties, determinism, and cancellation" + _detail(error) + " (angles %.6f to %.6f)" % [before, after])
	)
	step("Then cancellation discards contours and partial triangulations", func():
		var contour_cancelled := true
		var mesh_cancelled := true
		for stop in [1, 10, 45, 80, 130, 200]:
			var calls := [0]
			var cancel := func(_progress):
				calls[0] += 1
				return calls[0] != stop
			var loops := REGION.contours(fixtures[0], cancel)
			if calls[0] >= stop:
				contour_cancelled = contour_cancelled and loops.is_empty()
			calls[0] = 0
			var output := REGION.triangulate(fixtures[0], {}, cancel)
			if calls[0] >= stop:
				mesh_cancelled = mesh_cancelled and output.is_empty()
		expect(contour_cancelled, "cancelled contour extraction returns no partial loops")
		expect(mesh_cancelled, "cancelled triangulation returns no partial polygons")
	)


func _rectangle(origin: Vector2i, size: Vector2i) -> Dictionary:
	var cells := {}
	for y in size.y:
		for x in size.x:
			cells[origin + Vector2i(x, y)] = true
	return cells


func _check_mesh(cells: Dictionary, output: Array, samples: Dictionary) -> String:
	var triangles: Array[PackedVector2Array] = []
	var area := 0.0
	for mesh: Dictionary in output:
		var points: PackedVector2Array = mesh.points
		var indices: PackedInt32Array = mesh.indices
		if indices.size() % 3 != 0:
			return "incomplete triangle indices"
		for index in indices:
			if index < 0 or index >= points.size():
				return "triangle index outside the points"
		for offset in range(0, indices.size(), 3):
			var a := points[indices[offset]]
			var b := points[indices[offset + 1]]
			var c := points[indices[offset + 2]]
			var cross := (b - a).cross(c - a)
			if cross <= 0.0:
				return "nonpositive or clockwise triangle"
			area += cross * 0.5
			triangles.append(PackedVector2Array([a, b, c]))
	if area != cells.size():
		return "triangle area %s differs from cell count %s" % [area, cells.size()]
	if _boundary_units(output) != _cell_boundary(cells):
		return "triangle boundary differs from the occupied cell boundary"
	for cell: Vector2i in samples:
		var point := Vector2(cell) + Vector2(0.5, 0.5)
		var covered := false
		for triangle in triangles:
			if (triangle[1] - triangle[0]).cross(point - triangle[0]) >= 0.0 and (triangle[2] - triangle[1]).cross(point - triangle[1]) >= 0.0 and (triangle[0] - triangle[2]).cross(point - triangle[2]) >= 0.0:
				covered = true
				break
		if covered != cells.has(cell):
			return "incorrect coverage at cell %s" % cell
	return ""


func _boundary_units(output: Array) -> Dictionary:
	var boundary := {}
	for mesh: Dictionary in output:
		var points: PackedVector2Array = mesh.points
		var indices: PackedInt32Array = mesh.indices
		for offset in range(0, indices.size(), 3):
			for side in 3:
				var a := Vector2i(points[indices[offset + side]])
				var b := Vector2i(points[indices[offset + (side + 1) % 3]])
				var edge := Vector4i(a.x, a.y, b.x, b.y)
				var reverse := Vector4i(b.x, b.y, a.x, a.y)
				if boundary.has(reverse):
					boundary.erase(reverse)
				elif boundary.has(edge):
					return {"duplicate": true}
				else:
					boundary[edge] = true
	var units := {}
	for edge: Vector4i in boundary:
		var start := Vector2i(edge.x, edge.y)
		var delta := Vector2i(edge.z, edge.w) - start
		if delta.x != 0 and delta.y != 0:
			return {"diagonal": true}
		var direction := Vector2i(signi(delta.x), signi(delta.y))
		for offset in absi(delta.x) + absi(delta.y):
			var a := start + direction * offset
			var b := a + direction
			units[Vector4i(a.x, a.y, b.x, b.y)] = true
	return units


func _cell_boundary(cells: Dictionary) -> Dictionary:
	var boundary := {}
	for cell: Vector2i in cells:
		var corners := [cell, cell + Vector2i.RIGHT, cell + Vector2i.ONE, cell + Vector2i.DOWN]
		var neighbors := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
		for side in 4:
			if not cells.has(cell + neighbors[side]):
				var a: Vector2i = corners[side]
				var b: Vector2i = corners[(side + 1) % 4]
				boundary[Vector4i(a.x, a.y, b.x, b.y)] = true
	return boundary


func _minimum_angle(points: PackedVector2Array, indices: PackedInt32Array) -> float:
	var minimum := PI
	for offset in range(0, indices.size(), 3):
		for side in 3:
			var a := points[indices[offset + side]]
			var b := points[indices[offset + (side + 1) % 3]] - a
			var c := points[indices[offset + (side + 2) % 3]] - a
			minimum = minf(minimum, atan2(absf(b.cross(c)), b.dot(c)))
	return minimum


func _conforming(output: Array) -> bool:
	var vertices := {}
	var edges := []
	for mesh: Dictionary in output:
		var points: PackedVector2Array = mesh.points
		var indices: PackedInt32Array = mesh.indices
		for offset in range(0, indices.size(), 3):
			for side in 3:
				var a := points[indices[offset + side]]
				var b := points[indices[offset + (side + 1) % 3]]
				vertices[a] = true
				edges.append(PackedVector2Array([a, b]))
	for point: Vector2 in vertices:
		for edge: PackedVector2Array in edges:
			var delta := point - edge[0]
			var direction := edge[1] - edge[0]
			if delta.cross(direction) == 0.0 and delta.dot(direction) > 0.0 and delta.dot(direction) < direction.length_squared():
				return false
	return true


func _detail(error: String) -> String:
	return "" if error.is_empty() else " (%s)" % error
