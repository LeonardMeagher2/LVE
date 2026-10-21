extends RefCounted

## A test-only frozen copy of the surface query as it was before the query fast
## path, with the helpers that route the real fit and preview work through it.
##
## The copy is the exact body of `SculptGeometry.surface_along` as read on
## 2026-10-21. It calls the shared `march_cells`, `next_cell`, and `is_occupied`
## of the production geometry, because the fast path changes only the query body.
##
## Two uses:
##
## * [method parity] compares the frozen query against production over a
##   deterministic enumeration and over the queries of a real run. A candidate
##   query must return the same cell for every one of them.
## * The reference tool routes its real fit and preview work through
##   [method surface_along], so one measurement compares the old query against the
##   new production query on the same frames and the same cells.
##
## The copy never changes. Fixing a difference in the copy would hide it.

## The queries of the current capture, one entry per query.
static var captured: Array = []
## Whether a frozen query records itself into [member captured].
static var capture_enabled := false


## Starts a capture of the real query stream.
static func begin_capture() -> void:
	captured = []
	capture_enabled = true


## Stops recording queries.
static func end_capture() -> void:
	capture_enabled = false


## The frozen query. It builds both full DDA arrays before it tests the nearest
## cell.
static func surface_along(frame: VoxelFrame, point: Vector3, normal: Vector3, depth: int, changes := {}) -> Vector3i:
	if capture_enabled:
		captured.append({"point": point, "normal": normal, "depth": depth, "changes": changes})
	if normal == Vector3.ZERO:
		return VoxelPicking.NONE
	var use_depth := maxi(depth, 0)
	var outward := SculptGeometry.march_cells(point, normal, use_depth + 1)
	var inward := SculptGeometry.march_cells(point, -normal, use_depth + 1)
	var nearest := VoxelPicking.NONE
	for distance in range(use_depth + 1):
		if distance < outward.size() and SculptGeometry.is_occupied(frame, changes, outward[distance]):
			nearest = outward[distance]
			break
		if distance > 0 and distance < inward.size() and SculptGeometry.is_occupied(frame, changes, inward[distance]):
			nearest = inward[distance]
			break
	if nearest == VoxelPicking.NONE:
		return nearest
	var current := nearest
	var walked := 0
	while walked < use_depth + 1:
		var next := SculptGeometry.next_cell(current, normal, point)
		if not SculptGeometry.is_occupied(frame, changes, next):
			break
		current = next
		walked += 1
	if SculptGeometry.is_occupied(frame, changes, SculptGeometry.next_cell(current, normal, point)):
		return VoxelPicking.NONE
	return current


## The frozen surface points of one disc. It is the production body with the
## frozen query in place of the production one.
static func surface_points(frame: VoxelFrame, hit: Vector3i, entry: Vector3i, radius: int) -> Array:
	var points := []
	if frame == null or entry == Vector3i.ZERO:
		return points
	var entry_normal := Vector3(entry).normalized()
	var use_radius := maxi(radius, 1)
	var axis := SculptGeometry.axis_of(entry)
	var u_axis := (axis + 1) % 3
	var v_axis := (axis + 2) % 3
	var columns := {}
	for offset in SculptGeometry.disk_offsets(use_radius):
		var point := Vector3(hit)
		point[u_axis] += float(offset["u"])
		point[v_axis] += float(offset["v"])
		var surface := surface_along(frame, point, entry_normal, maxi(8, use_radius * 2))
		if surface == VoxelPicking.NONE:
			continue
		var key := Vector2i(offset["u"], offset["v"])
		columns[key] = {
			"point": Vector3(surface) + entry_normal * 0.5,
			"weight": SculptGeometry.weight_at(offset["distance"], float(use_radius), 0.5),
		}
	var queue: Array[Vector2i] = [Vector2i.ZERO]
	var visited := {Vector2i.ZERO: true}
	var index := 0
	while index < queue.size():
		var key := queue[index]
		index += 1
		if not columns.has(key):
			continue
		points.append(columns[key])
		for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var neighbor := key + offset
			if not visited.has(neighbor) and columns.has(neighbor):
				visited[neighbor] = true
				queue.append(neighbor)
	return points


## The frozen frame fit of one hit. The gradient fit and the frame construction
## are the unchanged production ones, so only the query differs.
static func fit(frame: VoxelFrame, hit: Vector3i, entry: Vector3i, radius: int, fallback: SculptFrame) -> SculptFrame:
	var points := surface_points(frame, hit, entry, radius)
	if points.size() < 3:
		return fallback
	var fit_result := SculptGeometry.fit_surface_gradient(points, fallback.normal)
	if not fit_result["ok"]:
		return fallback
	var result := SculptFrame.new()
	result.normal = fit_result["normal"]
	var centroid: Vector3 = fit_result["centroid"]
	result.origin = centroid + result.normal * result.normal.dot(fallback.origin - centroid)
	result.axis = SculptGeometry.dominant_axis(result.normal)
	result.sign = 1 if result.normal[result.axis] >= 0.0 else -1
	result.fitted = true
	result._build_normal_basis()
	return result


## Returns the parity of the frozen query against production over one query list.
## A mismatch names the query and both results.
static func parity(frame: VoxelFrame, queries: Array) -> Dictionary:
	var mismatches := []
	for query in queries:
		var point: Vector3 = query["point"]
		var normal: Vector3 = query["normal"]
		var depth: int = query["depth"]
		var changes: Dictionary = query.get("changes", {})
		var frozen := surface_along(frame, point, normal, depth, changes)
		var production := SculptGeometry.surface_along(frame, point, normal, depth, changes)
		if frozen != production:
			mismatches.append({
				"point": point, "normal": normal, "depth": depth,
				"frozen": frozen, "production": production,
			})
	return {"count": queries.size(), "mismatches": mismatches}


## Returns a deterministic query enumeration over one box. The normals cover the
## cardinal axes, obliques, exact tie directions, and both signs. The depths
## cover zero, one step, the fit disc, and the full cap. The points sit on a half
## cell lattice, so the negative halves of the first cell test are included. No
## random source is used.
static func enumeration(bounds: AABB, changes_list: Array, step_cells := 2) -> Array:
	var normals := [
		Vector3.UP, Vector3.DOWN, Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD,
		Vector3(1, 1, 0).normalized(), Vector3(-1, 1, 0).normalized(), Vector3(1, -1, 0).normalized(),
		Vector3(0, 1, 1).normalized(), Vector3(0, -1, -1).normalized(), Vector3(-1, 1, -1).normalized(),
		Vector3(0.25, 1.0, 0.5).normalized(), Vector3(1, 1, 1), Vector3.ZERO,
		Vector3(1.0, 1.000001, 0.0).normalized(), Vector3(1.0, 0.999999, 0.0).normalized(),
		Vector3(1.0, -1.000001, 0.0).normalized(), Vector3(0.0, 1.000001, 1.0).normalized(),
	]
	var depths := [0, 1, 8, 64]
	var queries := []
	var low := bounds.position
	var high := bounds.end
	for x_index in range(int(low.x * 2.0), int(high.x * 2.0) + 1, step_cells):
		for y_index in range(int(low.y * 2.0), int(high.y * 2.0) + 1, step_cells):
			for z_index in range(int(low.z * 2.0), int(high.z * 2.0) + 1, step_cells):
				var point := Vector3(x_index, y_index, z_index) * 0.5
				for normal in normals:
					for depth in depths:
						for changes in changes_list:
							queries.append({"point": point, "normal": normal, "depth": depth, "changes": changes})
	return queries


## Returns true when the production fast path finds an occupied cell in its
## three-cell prefix. It is the test-side replica of that prefix, so a report can
## state how much of a stream the fast path serves without a production counter.
static func fast_prefix_hit(frame: VoxelFrame, point: Vector3, normal: Vector3, depth: int, changes := {}) -> bool:
	if normal == Vector3.ZERO:
		return false
	var origin_cell := Vector3i(floori(point.x + 0.5), floori(point.y + 0.5), floori(point.z + 0.5))
	if SculptGeometry.is_occupied(frame, changes, origin_cell):
		return true
	if maxi(depth, 0) < 1:
		return false
	if SculptGeometry.is_occupied(frame, changes, SculptGeometry.next_cell(origin_cell, normal, point)):
		return true
	return SculptGeometry.is_occupied(frame, changes, SculptGeometry.next_cell(origin_cell, -normal, point))


## Returns queries just beside a cell boundary on each axis. The tiny fractions
## cover the exact half boundary of the first cell test, where a rounded start
## cell would move.
static func edge_queries(center: Vector3, changes_list: Array) -> Array:
	var offsets := [
		Vector3(0.4999, 0.0, 0.0), Vector3(0.5001, 0.0, 0.0),
		Vector3(-0.4999, 0.0, 0.0), Vector3(-0.5001, 0.0, 0.0),
		Vector3(0.0, 0.4999, 0.0), Vector3(0.0, -0.5001, 0.0),
		Vector3(0.0, 0.0, 0.4999), Vector3(0.0, 0.0, -0.5001),
	]
	var normals := [Vector3.UP, Vector3.DOWN, Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD, Vector3(1, 1, 0).normalized()]
	var queries := []
	for offset in offsets:
		for normal in normals:
			for depth in [0, 1, 8, 64]:
				for changes in changes_list:
					queries.append({"point": center + offset, "normal": normal, "depth": depth, "changes": changes})
	return queries


## Returns queries at large coordinates, where a float32 shift of a half cell is
## no longer representable on every lattice point. The frame stays sparse, so the
## fixture allocates a few chunks.
static func far_queries() -> Array:
	var queries := []
	var bases := [
		Vector3(8388608.0, 0.0, 0.0), Vector3(8388609.0, 1.0, 2.0),
		Vector3(-8388608.0, 0.0, 0.0), Vector3(-8388609.0, -1.0, 2.0),
		Vector3(8388608.5, 0.0, 0.0), Vector3(-8388608.5, 0.0, 0.0),
	]
	var normals := [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3(1, 1, 0).normalized(), Vector3(-1, 1, 0).normalized()]
	for base in bases:
		for normal in normals:
			for depth in [0, 1, 8, 64]:
				queries.append({"point": base, "normal": normal, "depth": depth, "changes": {}})
	return queries


## Returns the exclusive microseconds of one pass over a query list. The found
## count keeps every result in use, so no call is dropped.
static func time_queries(frame: VoxelFrame, queries: Array, frozen: bool) -> int:
	var found := 0
	var started := Time.get_ticks_usec()
	for query in queries:
		var point: Vector3 = query["point"]
		var normal: Vector3 = query["normal"]
		var depth: int = query["depth"]
		var changes: Dictionary = query.get("changes", {})
		var result := surface_along(frame, point, normal, depth, changes) if frozen else SculptGeometry.surface_along(frame, point, normal, depth, changes)
		if result != VoxelPicking.NONE:
			found += 1
	var elapsed := Time.get_ticks_usec() - started
	if found < 0:
		print("unreachable ", found)
	return elapsed
