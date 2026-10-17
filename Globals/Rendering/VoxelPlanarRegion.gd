extends RefCounted

const DIRECTIONS := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]


static func contours(cells: Dictionary, checkpoint := Callable()) -> Array[PackedVector2Array]:
	return _contours(cells, {}, checkpoint)


static func triangulate(cells: Dictionary, protected: Dictionary = {}, checkpoint := Callable()) -> Array:
	# Remember cancellation even when the caller rejects only one checkpoint.
	var state := {"cancelled": false}
	var check := func(progress: int) -> bool:
		if not state.cancelled and checkpoint.is_valid():
			state.cancelled = not checkpoint.call(progress)
		return not state.cancelled
	if not check.call(0) or cells.is_empty():
		return []
	var queue: Array[Dictionary] = [cells]
	var leaves: Array[PackedVector2Array] = []
	var retained := protected.duplicate()
	var cursor := 0
	while cursor < queue.size():
		var mask := queue[cursor]
		queue[cursor] = {}
		cursor += 1
		var loops := _contours(mask, {}, check, true)
		if state.cancelled:
			return []
		if loops.is_empty():
			return _unit_faces(cells, check)
		var cut := 0
		var has_hole := false
		for loop in loops:
			if _twice_area(loop) < 0:
				var bottom := int(loop[0].y)
				var top := bottom
				for point in loop:
					bottom = mini(bottom, int(point.y))
					top = maxi(top, int(point.y))
				# A one-cell hole opens at its lower edge instead of its interior.
				cut = bottom + 1 if top - bottom > 1 else bottom
				has_hole = true
				break
		if has_hole:
			var below := {}
			var above := {}
			for cell: Vector2i in mask:
				if not check.call(below.size() + above.size()):
					return []
				if cell.y < cut:
					below[cell] = true
				else:
					above[cell] = true
			if below.is_empty() or above.is_empty():
				return _unit_faces(cells, check)
			queue.append(below)
			queue.append(above)
			continue
		# Collect every cut corner before simplifying either side of a cut.
		for loop in loops:
			var seen := {}
			for point in loop:
				if seen.has(point):
					return _unit_faces(cells, check)
				seen[point] = true
			for point in _simplify(loop, {}):
				retained[Vector2i(point)] = true
		leaves.append_array(loops)
	var result := []
	var area := 0.0
	for loop in leaves:
		if not check.call(result.size()):
			return []
		var points := _simplify(loop, retained)
		var indices := _triangles(points, check)
		if state.cancelled:
			return []
		if indices.is_empty():
			return _unit_faces(cells, check)
		area += _twice_area(points)
		result.append({"points": points, "indices": indices})
	if area != cells.size() * 2.0:
		return _unit_faces(cells, check)
	return result


static func _contours(cells: Dictionary, protected: Dictionary, checkpoint: Callable, keep_collinear := false) -> Array[PackedVector2Array]:
	if not _check(checkpoint, 0):
		return []
	var edges := {}
	var order := cells.keys()
	order.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
	var starts: Array[Vector3i] = []
	for cell: Vector2i in order:
		if not _check(checkpoint, starts.size()):
			return []
		var corners := [cell, cell + Vector2i.RIGHT, cell + Vector2i.ONE, cell + Vector2i.DOWN]
		var neighbors := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
		for side in 4:
			if not cells.has(cell + neighbors[side]):
				var start: Vector2i = corners[side]
				var edge := Vector3i(start.x, start.y, side)
				edges[edge] = true
				starts.append(edge)
	var result: Array[PackedVector2Array] = []
	for first in starts:
		if not edges.has(first):
			continue
		var edge := first
		var loop := PackedVector2Array()
		while true:
			if not _check(checkpoint, edges.size()):
				return []
			if not edges.has(edge):
				return []
			edges.erase(edge)
			loop.append(Vector2(edge.x, edge.y))
			var end: Vector2i = Vector2i(edge.x, edge.y) + DIRECTIONS[edge.z]
			var found := false
			# Keep occupied cells on the left. Separate diagonal contacts with a left turn.
			for turn in [1, 0, 3, 2]:
				var next := Vector3i(end.x, end.y, (edge.z + turn) % 4)
				if next == first or edges.has(next):
					edge = next
					found = true
					break
			if not found:
				return []
			if edge == first:
				break
		result.append(loop if keep_collinear else _simplify(loop, protected))
	return result


static func _simplify(loop: PackedVector2Array, protected: Dictionary) -> PackedVector2Array:
	var result := PackedVector2Array()
	for index in loop.size():
		var point := loop[index]
		var previous := loop[(index + loop.size() - 1) % loop.size()]
		var next := loop[(index + 1) % loop.size()]
		if protected.has(Vector2i(point)) or (point - previous).cross(next - point) != 0.0:
			result.append(point)
	return result


static func _triangles(points: PackedVector2Array, checkpoint: Callable) -> PackedInt32Array:
	# Triangulate only turns. Insert collinear seam points by splitting boundary triangles.
	var turns := _simplify(points, {})
	var source := Geometry2D.triangulate_polygon(turns)
	var lookup := {}
	for index in points.size():
		lookup[points[index]] = index
	var indices := PackedInt32Array()
	var used := {}
	for offset in range(0, source.size(), 3):
		if not _check(checkpoint, offset):
			return PackedInt32Array()
		var a: int = lookup[turns[source[offset]]]
		var b: int = lookup[turns[source[offset + 1]]]
		var c: int = lookup[turns[source[offset + 2]]]
		var cross := (points[b] - points[a]).cross(points[c] - points[a])
		if cross == 0.0:
			continue
		if cross < 0.0:
			return PackedInt32Array()
		indices.append_array(PackedInt32Array([a, b, c]))
		used[a] = true
		used[b] = true
		used[c] = true
	for index in points.size():
		if used.has(index):
			continue
		var inserted := false
		for offset in range(0, indices.size(), 3):
			if not _check(checkpoint, offset):
				return PackedInt32Array()
			for side in 3:
				var a := indices[offset + side]
				var b := indices[offset + (side + 1) % 3]
				var c := indices[offset + (side + 2) % 3]
				var delta := points[index] - points[a]
				var edge := points[b] - points[a]
				if delta.cross(edge) != 0.0 or delta.dot(edge) <= 0.0 or delta.dot(edge) >= edge.length_squared():
					continue
				indices[offset] = a
				indices[offset + 1] = index
				indices[offset + 2] = c
				indices.append_array(PackedInt32Array([index, b, c]))
				inserted = true
				break
			if inserted:
				break
		if not inserted:
			return PackedInt32Array()
	indices = _improve(points, indices, checkpoint)
	# Require the exact directed polygon boundary, not only the expected total area.
	var boundary := {}
	var area := 0.0
	for offset in range(0, indices.size(), 3):
		if not _check(checkpoint, offset):
			return PackedInt32Array()
		var a := points[indices[offset]]
		var b := points[indices[offset + 1]]
		var c := points[indices[offset + 2]]
		var cross := (b - a).cross(c - a)
		if cross <= 0.0:
			return PackedInt32Array()
		area += cross
		for side in 3:
			var edge := Vector2i(indices[offset + side], indices[offset + (side + 1) % 3])
			var reverse := Vector2i(edge.y, edge.x)
			if boundary.has(reverse):
				boundary.erase(reverse)
			elif boundary.has(edge):
				return PackedInt32Array()
			else:
				boundary[edge] = true
	if area != _twice_area(points) or boundary.size() != points.size():
		return PackedInt32Array()
	for index in points.size():
		if not boundary.has(Vector2i(index, (index + 1) % points.size())):
			return PackedInt32Array()
	return indices


static func _improve(points: PackedVector2Array, indices: PackedInt32Array, checkpoint: Callable) -> PackedInt32Array:
	# Bound partial Lawson improvement to eight flips per triangle. Never move seam edges.
	var adjacency := {}
	var queue: Array[Vector2i] = []
	var pending := {}
	for base in range(0, indices.size(), 3):
		if not _check(checkpoint, base):
			return PackedInt32Array()
		for side in 3:
			var edge := Vector2i(indices[base + side], indices[base + (side + 1) % 3])
			adjacency[edge] = base + side
			_queue_edge(edge, adjacency, queue, pending)
	var cursor := 0
	var flips := 0
	var limit: int = indices.size() / 3 * 8
	while cursor < queue.size() and flips < limit:
		if not _check(checkpoint, cursor):
			return PackedInt32Array()
		var edge := queue[cursor]
		cursor += 1
		pending.erase(edge)
		var reverse := Vector2i(edge.y, edge.x)
		if not adjacency.has(edge) or not adjacency.has(reverse):
			continue
		var first: int = adjacency[edge]
		var second: int = adjacency[reverse]
		var first_base := first - first % 3
		var second_base := second - second % 3
		var a := edge.x
		var b := edge.y
		var c := indices[first_base + (first % 3 + 2) % 3]
		var d := indices[second_base + (second % 3 + 2) % 3]
		# Both replacement triangles must be strictly CCW. Reject concave quadrilaterals.
		if _orientation(points[c], points[d], points[b]) <= 0.0 or _orientation(points[d], points[c], points[a]) <= 0.0:
			continue
		if not _inside_circle(points[a], points[b], points[c], points[d]):
			continue
		for base in [first_base, second_base]:
			for side in 3:
				adjacency.erase(Vector2i(indices[base + side], indices[base + (side + 1) % 3]))
		indices[first_base] = c
		indices[first_base + 1] = d
		indices[first_base + 2] = b
		indices[second_base] = d
		indices[second_base + 1] = c
		indices[second_base + 2] = a
		for base in [first_base, second_base]:
			for side in 3:
				var changed := Vector2i(indices[base + side], indices[base + (side + 1) % 3])
				adjacency[changed] = base + side
				_queue_edge(changed, adjacency, queue, pending)
		flips += 1
	return indices


static func _queue_edge(edge: Vector2i, adjacency: Dictionary, queue: Array[Vector2i], pending: Dictionary) -> void:
	if not adjacency.has(Vector2i(edge.y, edge.x)):
		return
	var key := Vector2i(mini(edge.x, edge.y), maxi(edge.x, edge.y))
	if not pending.has(key):
		pending[key] = true
		queue.append(key)


static func _orientation(a: Vector2, b: Vector2, c: Vector2) -> float:
	var bx: float = b.x - a.x
	var by: float = b.y - a.y
	var cx: float = c.x - a.x
	var cy: float = c.y - a.y
	return bx * cy - by * cx


static func _inside_circle(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool:
	# Use translated scalar doubles, not float32 Vector2 dot products or squared lengths.
	var ax: float = a.x - d.x
	var ay: float = a.y - d.y
	var bx: float = b.x - d.x
	var by: float = b.y - d.y
	var cx: float = c.x - d.x
	var cy: float = c.y - d.y
	var first := (ax * ax + ay * ay) * (bx * cy - by * cx)
	var second := (bx * bx + by * by) * (cx * ay - cy * ax)
	var third := (cx * cx + cy * cy) * (ax * by - ay * bx)
	# Keep cocircular and numerically uncertain edges unchanged to prevent oscillation.
	return first + second + third > (absf(first) + absf(second) + absf(third)) * 1.0e-12


static func _twice_area(points: PackedVector2Array) -> float:
	var area := 0.0
	for index in range(1, points.size() - 1):
		area += (points[index] - points[0]).cross(points[index + 1] - points[0])
	return area


static func _unit_faces(cells: Dictionary, checkpoint: Callable) -> Array:
	var result := []
	var order := cells.keys()
	order.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
	for cell: Vector2i in order:
		if not _check(checkpoint, result.size()):
			return []
		var points := PackedVector2Array([Vector2(cell), Vector2(cell + Vector2i.RIGHT), Vector2(cell + Vector2i.ONE), Vector2(cell + Vector2i.DOWN)])
		result.append({"points": points, "indices": PackedInt32Array([0, 1, 2, 0, 2, 3])})
	return result


static func _check(checkpoint: Callable, progress: int) -> bool:
	return not checkpoint.is_valid() or checkpoint.call(progress)
