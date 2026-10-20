extends RefCounted

## Triangulates planar voxel regions with a seam-preserving cleanup.
##
## A region is a set of occupied cells on one plane. The class follows the
## outline loops, splits a pinched outline, cuts holes, and triangulates the
## result. The cleanup never moves a protected seam corner.

## The four edge directions in the loop walk order.
const DIRECTIONS := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]
# Keep the left turn first. It separates regions that touch at one corner.
## The turn order that keeps the occupied cells on the left.
const TURNS: Array[int] = [1, 0, 3, 2]
# One row mask holds at most 64 cells. Wider or taller regions, and sparse
# regions, use the dictionary path.
## The maximum compact box width in cells.
const BOX_LIMIT := 64


# A compact cell box. One row mask per row and one edge bitfield per lattice
# corner replace dictionary hashing. An empty box or a box outside the limit
# returns null, and the caller keeps the dictionary path.
## A compact cell box for a dense region.
##
## One row mask per row replaces dictionary hashing. A region that is too wide
## or too sparse keeps the dictionary path.
class Cells:
	## The first cell of the box.
	var origin := Vector2i.ZERO
	## The box width in cells.
	var width := 0
	## The box height in cells.
	var height := 0
	## One row mask per row.
	var rows: PackedInt64Array = []
	## The occupied cell count.
	var count := 0


static func _compact(cells: Dictionary) -> Cells:
	if cells.is_empty():
		return null
	var origin := Vector2i.MAX
	var extent := Vector2i.MIN
	for cell: Vector2i in cells:
		origin = Vector2i(mini(origin.x, cell.x), mini(origin.y, cell.y))
		extent = Vector2i(maxi(extent.x, cell.x), maxi(extent.y, cell.y))
	# The width is a row mask, so it cannot exceed the word size. The height is only
	# an array length, and the density test below already bounds the scan by area.
	if extent.x - origin.x >= BOX_LIMIT:
		return null
	var area := (extent.x - origin.x + 1) * (extent.y - origin.y + 1)
	# A box only pays for a dense region. Fragmented regions cost less in the
	# dictionary path, because the box scan reads every cell of its rectangle.
	if area > maxi(cells.size() * 4, 16):
		return null
	var box := Cells.new()
	box.origin = origin
	box.width = extent.x - origin.x + 1
	box.height = extent.y - origin.y + 1
	box.rows.resize(box.height)
	for cell: Vector2i in cells:
		var local := cell - origin
		box.rows[local.y] |= 1 << local.x
		box.count += 1
	return box


# Latch the caller's checkpoint. After the first rejection every later check
# fails, so no path restarts after cancellation.
static func _latch(checkpoint: Callable, state: Dictionary) -> Callable:
	return func(progress: int) -> bool:
		if not state.cancelled and checkpoint.is_valid():
			state.cancelled = not checkpoint.call(progress)
		return not state.cancelled


# The unsimplified boundary loops of one region. A caller that needs both the
# turns and the triangulation prepares them once instead of twice.
## Returns the unsimplified boundary loops of one region. A caller that needs
## both the turns and the triangulation prepares them once.
static func raw_loops(cells: Dictionary, checkpoint := Callable()) -> Array[PackedVector2Array]:
	var state := {"cancelled": false}
	var check := _latch(checkpoint, state)
	if not check.call(0):
		return []
	var box := _compact(cells)
	if box == null:
		return _contours(cells, {}, check, true)
	return _box_loops(box, check)


## Returns the simplified boundary loops of one region.
static func contours(cells: Dictionary, checkpoint := Callable()) -> Array[PackedVector2Array]:
	var state := {"cancelled": false}
	var check := _latch(checkpoint, state)
	if not check.call(0):
		return []
	var box := _compact(cells)
	var loops: Array[PackedVector2Array]
	if box == null:
		loops = _contours(cells, {}, check, true)
	else:
		loops = _box_loops(box, check)
	if state.cancelled:
		return []
	var result: Array[PackedVector2Array] = []
	for loop in loops:
		if not _check(check, result.size()):
			return []
		result.append(_simplify(loop, {}))
	return result


## Returns one polygon record per triangle region. Each record holds
## [code]points[/code] and [code]indices[/code]. [param protected] lists the
## seam corners that must stay. [param prepared] supplies the loops from
## [method raw_loops]. Returns an empty array on a cancel.
static func triangulate(cells: Dictionary, protected: Dictionary = {}, checkpoint := Callable(), prepared: Array = []) -> Array:
	# Remember cancellation even when the caller rejects only one checkpoint.
	var state := {"cancelled": false}
	var check := _latch(checkpoint, state)
	if not check.call(0) or cells.is_empty():
		return []
	# A prepared region whose every loop is one unit square needs no compaction,
	# splitting, hole detection, simplification, or triangulation. Emit the same
	# loops, points, and indices the general path would produce, in the same order.
	if not prepared.is_empty() and _all_unit_squares(prepared):
		return _unit_square_faces(cells, prepared, check)
	var box := _compact(cells)
	var queue: Array[Dictionary] = [cells]
	var queue_boxes: Array[Cells] = [box]
	var leaves: Array[PackedVector2Array] = []
	var retained := protected.duplicate()
	var cursor := 0
	var first := true
	while cursor < queue.size():
		var mask := queue[cursor]
		queue[cursor] = {}
		var mask_box: Cells = queue_boxes[cursor]
		queue_boxes[cursor] = null
		cursor += 1
		var loops: Array[PackedVector2Array]
		if first and not prepared.is_empty():
			loops = prepared
		elif mask_box == null:
			loops = _contours(mask, {}, check, true)
		else:
			loops = _box_loops(mask_box, check)
		first = false
		if state.cancelled:
			return []
		if loops.is_empty():
			return _unit_faces(cells, check)
		# An outline that pinches at a corner visits that corner twice. Split it
		# there so every piece is a simple polygon. A hole that touches the
		# outline at a corner becomes a negative piece, and opens below.
		var parts: Array[PackedVector2Array] = []
		for loop in loops:
			parts.append_array(_split_loops(loop))
		if parts.is_empty():
			return _unit_faces(cells, check)
		var cut := 0
		var has_hole := false
		for loop in parts:
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
			var below_box: Cells = null
			var above_box: Cells = null
			if mask_box == null:
				for cell: Vector2i in mask:
					if not check.call(below.size() + above.size()):
						return []
					if cell.y < cut:
						below[cell] = true
					else:
						above[cell] = true
				if below.is_empty() or above.is_empty():
					return _unit_faces(cells, check)
			else:
				below_box = _split_box(mask_box, cut)
				above_box = _split_box(mask_box, cut, true)
				if below_box.count == 0 or above_box.count == 0:
					return _unit_faces(cells, check)
			queue.append(below)
			queue.append(above)
			queue_boxes.append(below_box)
			queue_boxes.append(above_box)
			continue
		# Collect every cut corner before simplifying either side of a cut.
		for loop in parts:
			for point in _simplify(loop, {}):
				retained[Vector2i(point)] = true
		leaves.append_array(parts)
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


# Cut a compact box at one world row. Keep the rows below or above the cut.
static func _split_box(box: Cells, cut: int, upper := false) -> Cells:
	var local_cut := clampi(cut - box.origin.y, 0, box.height)
	var out := Cells.new()
	out.width = box.width
	if upper:
		out.origin = Vector2i(box.origin.x, box.origin.y + local_cut)
		out.height = box.height - local_cut
	else:
		out.origin = box.origin
		out.height = local_cut
	out.rows.resize(out.height)
	for y in out.height:
		out.rows[y] = box.rows[y + (local_cut if upper else 0)]
	for row in out.rows:
		var bits := row
		while bits != 0:
			out.count += 1
			bits &= bits - 1
	return out


# Boundary edges of one compact box, in the order the dictionary path emits
# them: cells by row and column, and the up, right, down, left side of each
# cell. Corner 0 of a cell is its own corner. The other sides start one step
# along the edge direction.
static func _box_edge_starts(box: Cells) -> Array[Vector3i]:
	var starts: Array[Vector3i] = []
	for y in box.height:
		var row := box.rows[y]
		var above := 0
		if y > 0:
			above = box.rows[y - 1]
		var below := 0
		if y + 1 < box.height:
			below = box.rows[y + 1]
		for x in box.width:
			var bit := 1 << x
			if row & bit == 0:
				continue
			var cell_x := box.origin.x + x
			var cell_y := box.origin.y + y
			if above & bit == 0:
				starts.append(Vector3i(cell_x, cell_y, 0))
			if row & (bit << 1) == 0:
				starts.append(Vector3i(cell_x + 1, cell_y, 1))
			if below & bit == 0:
				starts.append(Vector3i(cell_x + 1, cell_y + 1, 2))
			if row & (bit >> 1) == 0:
				starts.append(Vector3i(cell_x, cell_y + 1, 3))
	return starts


# Follow the boundary loops of one compact box. The edge state is one bitfield
# per lattice corner, so the walk never hashes a key. The turn order keeps the
# occupied cells on the left, which separates regions that touch at a corner.
static func _box_loops(box: Cells, check: Callable) -> Array[PackedVector2Array]:
	var starts := _box_edge_starts(box)
	if starts.is_empty():
		return []
	# Edge start corners cover the (width + 1) by (height + 1) corner grid.
	var grid_w := box.width + 1
	var grid_h := box.height + 1
	var ox := box.origin.x
	var oy := box.origin.y
	var state := PackedInt32Array()
	state.resize(grid_w * grid_h)
	for start in starts:
		state[start.x - ox + grid_w * (start.y - oy)] |= 1 << start.z
	var result: Array[PackedVector2Array] = []
	for start in starts:
		if state[start.x - ox + grid_w * (start.y - oy)] & (1 << start.z) == 0:
			continue
		var edge := start
		var loop := PackedVector2Array()
		while true:
			if not _check(check, result.size()):
				return []
			var corner := edge.x - ox + grid_w * (edge.y - oy)
			state[corner] &= ~(1 << edge.z)
			loop.append(Vector2(edge.x, edge.y))
			var end_x: int = edge.x + DIRECTIONS[edge.z].x
			var end_y: int = edge.y + DIRECTIONS[edge.z].y
			var found := false
			if end_x >= ox and end_x < ox + grid_w and end_y >= oy and end_y < oy + grid_h:
				var end_corner := end_x - ox + grid_w * (end_y - oy)
				for turn in TURNS:
					var next_z := (edge.z + turn) % 4
					var is_first := end_x == start.x and end_y == start.y and next_z == start.z
					if is_first or state[end_corner] & (1 << next_z) != 0:
						edge = Vector3i(end_x, end_y, next_z)
						found = true
						break
			if not found:
				return []
			if edge == start:
				break
		result.append(loop)
	return result


# A region whose outline pinches at a corner returns one loop that visits that
# corner twice. Split it there so every piece is a simple polygon. The pinch
# contributes no area, so the pieces still cover the occupied cells exactly.
static func _split_loops(loop: PackedVector2Array) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	var pending: Array[PackedVector2Array] = [loop]
	while not pending.is_empty():
		var current: PackedVector2Array = pending.pop_back()
		var first_index := {}
		var repeated_at := -1
		for index in current.size():
			var point := current[index]
			if first_index.has(point):
				repeated_at = index
				break
			first_index[point] = index
		if repeated_at < 0:
			if current.size() >= 3:
				result.append(current)
			continue
		var start: int = first_index[current[repeated_at]]
		var head := PackedVector2Array()
		for index in range(start, repeated_at):
			head.append(current[index])
		var tail := PackedVector2Array()
		for index in range(repeated_at, current.size()):
			tail.append(current[index])
		for index in range(0, start):
			tail.append(current[index])
		pending.append(head)
		pending.append(tail)
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
	# A unit square needs no triangulation, no collinear insertion, and no
	# improvement. Geometry2D fans a four-point polygon from its last vertex.
	if _unit_square(points):
		return PackedInt32Array([3, 0, 1, 1, 2, 3])
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


# A loop of four points is a unit square when it is one cell wide, one cell
# tall, and wound counterclockwise. Clockwise loops fall through, because the
# full path rejects them.
static func _unit_square(points: PackedVector2Array) -> bool:
	if points.size() != 4:
		return false
	var minimum := points[0]
	var maximum := points[0]
	for point in points:
		minimum = Vector2(minf(minimum.x, point.x), minf(minimum.y, point.y))
		maximum = Vector2(maxf(maximum.x, point.x), maxf(maximum.y, point.y))
	if maximum - minimum != Vector2.ONE:
		return false
	var area := 0.0
	for index in 4:
		var step := points[(index + 1) % 4] - points[index]
		if absf(step.x) + absf(step.y) != 1.0:
			return false
		area += points[index].cross(points[(index + 1) % 4])
	return area == 2.0


# True when the prepared loops are all counterclockwise unit squares. Such a
# region holds only isolated cells, so no loop needs a split, a hole cut, or a
# triangle.
static func _all_unit_squares(loops: Array) -> bool:
	for loop: PackedVector2Array in loops:
		if not _unit_square(loop):
			return false
	return true


# Emit one polygon per prepared unit square. The points are the loop itself, and
# the indices are the fan `_triangles` gives a unit square. The loop count must
# equal the input cells, or the region falls back to one quad per cell.
static func _unit_square_faces(cells: Dictionary, loops: Array, check: Callable) -> Array:
	var result := []
	for loop: PackedVector2Array in loops:
		if not check.call(result.size()):
			return []
		result.append({"points": loop, "indices": PackedInt32Array([3, 0, 1, 1, 2, 3])})
	if result.size() != cells.size():
		return _unit_faces(cells, check)
	return result


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
