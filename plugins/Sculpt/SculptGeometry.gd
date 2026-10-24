class_name SculptGeometry
extends RefCounted

## Pure geometry and surface helpers for the sculpt tools.
##
## The helpers hold no state. The tool and the tests share them, so the
## footprint, the falloff, and the column surface have one definition.

## The smallest tilt from the seed normal that a plane fit accepts.
const FIT_MIN_TILT := 0.3
## The margin by which one axis must beat another to become the dominant axis.
## A near tie keeps the preferred axis, so a fitted normal never flips its
## dominant axis between two refits of one unchanged 45 degree surface.
const AXIS_TIE_EPSILON := 1e-3
## The disc offsets between two cancel checks of one worker fit. One offset is one
## bounded surface walk, so a small value bounds the work between two cancels.
const FIT_CANCEL_CHECKPOINT := 32

## Returns the first non-zero axis of a cell step, or -1 when every axis is
## zero.
static func axis_of(step: Vector3i) -> int:
	for axis in 3:
		if step[axis] != 0:
			return axis
	return -1


## Returns the one axis of an exactly cardinal direction, or -1 when the direction
## has zero or two non-zero components. An exact cardinal direction is the only
## one whose walk stays inside a single column.
static func cardinal_axis(direction: Vector3) -> int:
	for axis in 3:
		if direction[axis] == 0.0:
			continue
		for other in 3:
			if other != axis and direction[other] != 0.0:
				return -1
		return axis
	return -1


## Returns the axis of the largest absolute component of a vector. A zero vector
## returns axis 0. A near tie keeps the lowest axis, so a slightly different
## normal of one unchanged surface keeps the same axis.
static func dominant_axis(vector: Vector3) -> int:
	var axis := 0
	var best := absf(vector.x)
	if absf(vector.y) > best + AXIS_TIE_EPSILON:
		axis = 1
		best = absf(vector.y)
	if absf(vector.z) > best + AXIS_TIE_EPSILON:
		axis = 2
	return axis


## Returns the signed step of one axis. A zero value returns 1.
static func sign_of(step: Vector3i, axis: int) -> int:
	return 1 if step[axis] >= 0 else -1


## Returns the neighbor of a surface cell one layer along the dominant axis of
## the normal. [param direction] is 1 outward and -1 inward. The layer model uses
## this step instead of a per-ray DDA, so the shell has no holes or stalls.
static func layer_step(surface: Vector3i, normal: Vector3, direction: int) -> Vector3i:
	var axis := dominant_axis(normal)
	var sign := 1 if normal[axis] >= 0.0 else -1
	if direction < 0:
		sign = -sign
	var cell := surface
	cell[axis] += sign
	return cell


## Returns the falloff weight for one distance from the center.
##
## A zero falloff gives a hard edge. A falloff of one gives a smooth edge. The
## weight is one at the center.
static func weight_at(distance: float, radius: float, falloff: float) -> float:
	if radius <= 0.0:
		return 1.0
	var t := clampf(distance / radius, 0.0, 1.0)
	var smooth := 1.0 - (t * t * (3.0 - 2.0 * t))
	return lerpf(1.0, smooth, clampf(falloff, 0.0, 1.0))


## Returns the cell that holds a world point. A voxel is centered on an integer
## cell, so the nearest integer cell holds the point.
static func cell_at(point: Vector3) -> Vector3i:
	return Vector3i(roundi(point.x), roundi(point.y), roundi(point.z))


## Resolves a footprint candidate list into the exact sample map.
##
## Every candidate holds an "anchor" cell, an "influence" weight, and a "claim"
## cell. The result keeps one row per accepted anchor, keyed by that anchor. An
## anchor and a claim are each unique, so no two rows write the same cell and no
## row is left without its own key.
##
## The candidates resolve in one pass in their own order, so the row order is the
## shipped order. The strongest influence keeps a claimed cell. An anchor keeps
## the last candidate, which is the shipped rule. A displacement releases the
## whole opposite map entry, so an owner is never left dangling. The pass never
## aborts on a duplicate anchor or claim.
static func resolve_samples(candidates: Array) -> Dictionary:
	var built := {}
	var claim_owner := {}
	for row in candidates:
		var anchor: Vector3i = row["anchor"]
		var claim: Vector3i = row["claim"]
		var weight := float(row["weight"])
		# The claim rule: the strongest influence keeps the claimed cell.
		if claim_owner.has(claim):
			var owner: Vector3i = claim_owner[claim]
			if float(built[owner]["weight"]) >= weight:
				continue
			claim_owner.erase(claim)
			built.erase(owner)
		# The anchor rule keeps the shipped last-wins result. The previous claim of
		# the anchor is released, so its owner is never left dangling.
		if built.has(anchor):
			var previous: Vector3i = built[anchor]["claim"]
			claim_owner.erase(previous)
		built[anchor] = row
		claim_owner[claim] = anchor
	return built


## Returns the integer offsets of a disk in a plane. Each entry holds the two
## in-plane offsets and the distance from the center.
##
## The result is cached per radius. The array and every entry dictionary are
## read-only, and a mutex guards the build, so a preview worker can read one
## radius while the main thread builds another. A caller must not change an
## entry. One preview at a high radius asks for the disc several times, so the
## cache removes the repeated allocation and square root of every entry.
static func disk_offsets(radius: int) -> Array:
	var use_radius := maxi(radius, 1)
	_disk_lock.lock()
	var cached: Array = _disk_cache.get(use_radius, [])
	_disk_lock.unlock()
	if not cached.is_empty():
		return cached
	var offsets := []
	var radius_squared := use_radius * use_radius
	for u in range(-use_radius, use_radius + 1):
		for v in range(-use_radius, use_radius + 1):
			var distance_squared := u * u + v * v
			if distance_squared > radius_squared:
				continue
			offsets.append({"u": u, "v": v, "distance": sqrt(float(distance_squared))})
	for entry in offsets:
		entry.make_read_only()
	offsets.make_read_only()
	_disk_lock.lock()
	var existing: Array = _disk_cache.get(use_radius, [])
	if existing.is_empty():
		_disk_cache[use_radius] = offsets
		cached = offsets
	else:
		cached = existing
	_disk_lock.unlock()
	return cached


static var _disk_cache := {}
static var _disk_lock := Mutex.new()


## Returns the cells a ray passes through, starting at the cell that holds
## [param origin]. It uses the DDA method and returns at most [param steps]
## cells. The direction need not be normalized.
static func march_cells(origin: Vector3, direction: Vector3, steps: int) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	if steps <= 0 or direction == Vector3.ZERO:
		return cells
	var dir := direction.normalized()
	var g := origin + Vector3(0.5, 0.5, 0.5)
	var cell := Vector3i(floori(g.x), floori(g.y), floori(g.z))
	cells.append(cell)
	var step := Vector3i(
		1 if dir.x > 0.0 else -1, 1 if dir.y > 0.0 else -1, 1 if dir.z > 0.0 else -1
	)
	var t_max := Vector3(INF, INF, INF)
	var t_delta := Vector3(INF, INF, INF)
	for axis in 3:
		if dir[axis] == 0.0:
			continue
		t_delta[axis] = absf(1.0 / dir[axis])
		t_max[axis] = ((float(cell[axis]) + (1.0 if step[axis] > 0 else 0.0)) - g[axis]) / dir[axis]
	for _index in steps:
		if t_max.x < t_max.y and t_max.x < t_max.z:
			cell.x += step.x
			t_max.x += t_delta.x
		elif t_max.y < t_max.z:
			cell.y += step.y
			t_max.y += t_delta.y
		else:
			cell.z += step.z
			t_max.z += t_delta.z
		cells.append(cell)
	return cells


## Returns the next cell along a ray. Keep the same origin across voxel steps.
## Without an origin, the ray starts at the cell center.
static func next_cell(cell_position: Vector3i, direction: Vector3, ray_origin := Vector3.INF) -> Vector3i:
	if direction == Vector3.ZERO:
		return cell_position
	var origin := Vector3(cell_position) if ray_origin == Vector3.INF else ray_origin
	var crossing := Vector3(INF, INF, INF)
	var step := Vector3i.ZERO
	for axis in 3:
		if direction[axis] == 0.0:
			continue
		step[axis] = 1 if direction[axis] > 0.0 else -1
		var boundary := float(cell_position[axis]) + 0.5 * float(step[axis])
		crossing[axis] = (boundary - origin[axis]) / direction[axis]
	# Keep the same tie order as march_cells, including edge-touching cells.
	var exit_axis := 2
	if crossing.x < crossing.y and crossing.x < crossing.z:
		exit_axis = 0
	elif crossing.y < crossing.z:
		exit_axis = 1
	var next := cell_position
	next[exit_axis] += step[exit_axis]
	return next


## Returns the previous cell along a direction from a cell center.
static func previous_cell(cell_position: Vector3i, direction: Vector3, ray_origin := Vector3.INF) -> Vector3i:
	return next_cell(cell_position, -direction, ray_origin)


## Returns the outermost occupied cell nearest to [param point] along an
## oriented ray. The search is bounded to [param depth] cells on each side of
## the point. An occupied run that continues past the bound returns
## [constant VoxelPicking.NONE] instead of an interior cell.
##
## The nearest cell is almost always the cell that holds the point or one of its
## two neighbors along the ray. Those three cells are tested first, in the order
## of the bounded scan. The fallback then walks the two rays one cell at a time
## from distance two, so no full path array is built, no cell is read twice, and
## no cell is tested out of order.
##
## [param context] is an optional exact read-only index of one frame snapshot. It
## shortens an exactly cardinal query on an empty column, because a cardinal walk
## never leaves its column. The result is identical, so a caller without a context
## keeps the walk.
static func surface_along(frame: VoxelFrame, point: Vector3, normal: Vector3, depth: int, changes := {}, context: SculptQueryContext = null) -> Vector3i:
	if normal == Vector3.ZERO:
		return VoxelPicking.NONE
	# Nothing can hold a cell, so no ray can find a surface. A pending change can
	# still add a cell outside an empty frame, so the check needs no changes.
	if changes.is_empty() and (frame == null or frame.chunks.is_empty()):
		return VoxelPicking.NONE
	var use_depth := maxi(depth, 0)
	# The first cell of both walks. The shifted point and its floor are the exact
	# start of the march, and they keep the negative half boundary with it.
	var g := point + Vector3(0.5, 0.5, 0.5)
	var origin_cell := Vector3i(floori(g.x), floori(g.y), floori(g.z))
	# An exactly cardinal walk stays in the column of its origin cell, so an empty
	# column returns NONE with no walk. The result is the exact walk result.
	if context != null and changes.is_empty():
		var cardinal := cardinal_axis(normal)
		if cardinal >= 0 and context.column_empty(cardinal, origin_cell):
			return VoxelPicking.NONE
	var nearest := VoxelPicking.NONE
	# The origin cell is the distance zero cell of the outward walk.
	var first_distance := 1
	if is_occupied(frame, changes, origin_cell):
		nearest = origin_cell
	elif use_depth >= 1:
		nearest = _first_neighbor_along(frame, changes, origin_cell, normal, point)
		first_distance = 2
	if nearest == VoxelPicking.NONE:
		if use_depth < first_distance:
			return nearest
		var outward := SurfaceWalk.new(point, normal)
		var inward: SurfaceWalk = null
		for _index in first_distance:
			outward.advance()
		for distance in range(first_distance, use_depth + 1):
			if is_occupied(frame, changes, outward.cell):
				nearest = outward.cell
				break
			# The inward walk starts only when the outward cell is empty, so a
			# fallback that finds its surface outward builds one walk.
			if inward == null:
				inward = SurfaceWalk.new(point, -normal)
				for _index in first_distance:
					inward.advance()
			if is_occupied(frame, changes, inward.cell):
				nearest = inward.cell
				break
			outward.advance()
			inward.advance()
	if nearest == VoxelPicking.NONE:
		return nearest
	var current := nearest
	var walked := 0
	while walked < use_depth + 1:
		var next := next_cell(current, normal, point)
		if not is_occupied(frame, changes, next):
			break
		current = next
		walked += 1
	if is_occupied(frame, changes, next_cell(current, normal, point)):
		return VoxelPicking.NONE
	return current


## One bounded DDA walk along a fixed ray, for [method surface_along].
##
## It holds the state that a full march would build, and it advances one cell at
## a time, so a fallback query never allocates a path array. The start cell, the
## axis steps, the boundary parameters, and the strict tie order are the exact
## ones of `march_cells`. The origin stays fixed, so no step re-centers.
class SurfaceWalk extends RefCounted:
	## The cell the walk stands on.
	var cell := Vector3i.ZERO
	## The step of each axis.
	var step := Vector3i.ZERO
	## The ray parameter of the next boundary crossing of each axis.
	var t_max := Vector3(INF, INF, INF)
	## The ray parameter one cell adds on each axis.
	var t_delta := Vector3(INF, INF, INF)

	func _init(origin: Vector3, direction: Vector3) -> void:
		var dir := direction.normalized()
		var g := origin + Vector3(0.5, 0.5, 0.5)
		cell = Vector3i(floori(g.x), floori(g.y), floori(g.z))
		step = Vector3i(
			1 if dir.x > 0.0 else -1, 1 if dir.y > 0.0 else -1, 1 if dir.z > 0.0 else -1
		)
		for axis in 3:
			if dir[axis] == 0.0:
				continue
			t_delta[axis] = absf(1.0 / dir[axis])
			t_max[axis] = ((float(cell[axis]) + (1.0 if step[axis] > 0 else 0.0)) - g[axis]) / dir[axis]

	## Advances to the next cell along the ray. An axis with a zero direction keeps
	## its infinite parameter, so the walk never moves on it.
	func advance() -> void:
		if t_max.x < t_max.y and t_max.x < t_max.z:
			cell.x += step.x
			t_max.x += t_delta.x
		elif t_max.y < t_max.z:
			cell.y += step.y
			t_max.y += t_delta.y
		else:
			cell.z += step.z
			t_max.z += t_delta.z


## Returns the first occupied neighbor of [param origin_cell] along the ray, in
## the order of the bounded scan: the outward cell at distance one, then the
## inward cell at distance one. The two marches test the same two cells in that
## order, from the same fixed origin.
static func _first_neighbor_along(frame: VoxelFrame, changes: Dictionary, origin_cell: Vector3i, normal: Vector3, point: Vector3) -> Vector3i:
	var outward := next_cell(origin_cell, normal, point)
	if is_occupied(frame, changes, outward):
		return outward
	var inward := next_cell(origin_cell, -normal, point)
	if is_occupied(frame, changes, inward):
		return inward
	return VoxelPicking.NONE


## Returns [code]true[/code] when a cell holds voxels after the pending changes.
## The tool and the preview share the test, so a preview shows the same cells.
static func is_occupied(frame: VoxelFrame, changes: Dictionary, cell_position: Vector3i) -> bool:
	if changes.has(cell_position):
		var changed: PackedFloat32Array = changes[cell_position]
		return not VoxelFrame.is_empty(changed)
	return frame != null and frame.has(cell_position)


## Returns [code]true[/code] when a selection allows a cell. An empty selection
## allows every cell.
static func allows(selection: Dictionary, cell_position: Vector3i) -> bool:
	return selection.is_empty() or selection.has(cell_position)


## Returns the cell one Grow Add step writes, or [constant VoxelPicking.NONE]
## when the sample cannot continue. The execution and the preview share this
## rule, so a preview only outlines a support whose destination is writable.
static func grow_add_cell(frame: VoxelFrame, changes: Dictionary, surface: Vector3i, normal: Vector3, point: Vector3, seed_empty: bool, selection: Dictionary) -> Vector3i:
	if surface == VoxelPicking.NONE:
		if not seed_empty:
			return VoxelPicking.NONE
		var seed := cell_at(point - normal * 0.5)
		if is_occupied(frame, changes, seed) or not allows(selection, seed):
			return VoxelPicking.NONE
		return seed
	var destination := layer_step(surface, normal, 1)
	if is_occupied(frame, changes, destination) or not allows(selection, destination):
		return VoxelPicking.NONE
	return destination


## Returns the cell one Grow Remove step clears, or
## [constant VoxelPicking.NONE] when the sample cannot continue.
static func grow_remove_cell(surface: Vector3i, selection: Dictionary) -> Vector3i:
	if surface == VoxelPicking.NONE:
		return VoxelPicking.NONE
	if not allows(selection, surface):
		return VoxelPicking.NONE
	return surface


## Returns the next Flatten action for one sample. The result holds the cell, an
## add flag, and a settled flag. A [constant VoxelPicking.NONE] cell means the
## sample cannot act. The execution and the preview share this rule.
##
## The target band is one cell thick. A cell whose outer face sits on the plane
## is at distance -0.5, so the test accepts the half-cell band around it.
static func flatten_action(frame: VoxelFrame, changes: Dictionary, surface: Vector3i, normal: Vector3, point: Vector3, plane_origin: Vector3, threshold: float, seed_empty: bool, selection: Dictionary) -> Dictionary:
	if surface == VoxelPicking.NONE:
		if not seed_empty:
			return {"cell": VoxelPicking.NONE}
		var seed := cell_at(point - normal * 0.5)
		if is_occupied(frame, changes, seed) or not allows(selection, seed):
			return {"cell": VoxelPicking.NONE}
		return {"cell": seed, "add": true, "seed": true}
	var distance := (Vector3(surface) - plane_origin).dot(normal)
	if absf(distance + 0.5) <= threshold:
		return {"cell": VoxelPicking.NONE, "settled": true}
	if distance + 0.5 > 0.0:
		if not allows(selection, surface):
			return {"cell": VoxelPicking.NONE}
		return {"cell": surface, "add": false}
	var destination := layer_step(surface, normal, 1)
	if is_occupied(frame, changes, destination) or not allows(selection, destination):
		return {"cell": VoxelPicking.NONE}
	return {"cell": destination, "add": true}


## Returns the exposed face boundary points around a hit. The points come from
## the connected outward surface only, so an opposing wall or a cave floor is
## excluded. Each point holds the boundary position and its weight.
##
## [param job] supplies the cancel checkpoints of a worker. [param context] is an
## optional exact read-only column index of the same frame snapshot. A cancelled
## fit returns no points, so the caller keeps its fallback and the job publishes
## nothing. The point order and the query stream are unchanged.
static func surface_points(frame: VoxelFrame, hit: Vector3i, entry: Vector3i, radius: int, job: VoxelFrame.EditJob = null, context: SculptQueryContext = null) -> Array:
	var points := []
	if frame == null or entry == Vector3i.ZERO:
		return points
	var entry_normal := Vector3(entry).normalized()
	var use_radius := maxi(radius, 1)
	var axis := axis_of(entry)
	var u_axis := (axis + 1) % 3
	var v_axis := (axis + 2) % 3
	var columns := {}
	var completed := 0
	for offset in disk_offsets(use_radius):
		var point := Vector3(hit)
		point[u_axis] += float(offset["u"])
		point[v_axis] += float(offset["v"])
		var surface := surface_along(frame, point, entry_normal, maxi(8, use_radius * 2), {}, context)
		completed += 1
		if job != null and completed % FIT_CANCEL_CHECKPOINT == 0 and not job.checkpoint(completed):
			return []
		if surface == VoxelPicking.NONE:
			continue
		var key := Vector2i(offset["u"], offset["v"])
		columns[key] = {
			"point": Vector3(surface) + entry_normal * 0.5,
			"weight": weight_at(offset["distance"], float(use_radius), 0.5),
		}
	# Keep the surface patch connected across the disc. Empty columns separate
	# unrelated islands. Sample heights, not the normals of individual cube faces.
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


## Fits the surface height gradient across a disc. The two fitted derivatives
## define the normal. Missing or collinear heights cannot define a plane.
##
## The derivatives are measured in a proper orthonormal frame: the signed
## cardinal axis of the seed is the height axis, and the other two cardinal axes
## are in plane. The seed only sets that height axis and the outward orientation,
## so repeated fits of one unchanged surface give one normal.
static func fit_surface_gradient(points: Array, seed: Vector3) -> Dictionary:
	if seed == Vector3.ZERO:
		return {"ok": false}
	var axis := dominant_axis(seed)
	var height_axis := Vector3.ZERO
	height_axis[axis] = 1.0 if seed[axis] >= 0.0 else -1.0
	var u := Vector3.ZERO
	u[(axis + 1) % 3] = 1.0
	var v := Vector3.ZERO
	v[(axis + 2) % 3] = 1.0
	var centroid := Vector3.ZERO
	var total := 0.0
	for sample in points:
		var weight: float = sample["weight"]
		total += weight
		centroid += (sample["point"] as Vector3) * weight
	if total <= 0.0:
		return {"ok": false}
	centroid /= total
	var uu := 0.0
	var uv := 0.0
	var vv := 0.0
	var uh := 0.0
	var vh := 0.0
	for sample in points:
		var delta: Vector3 = sample["point"] - centroid
		var weight: float = sample["weight"]
		var x := delta.dot(u)
		var y := delta.dot(v)
		var height := delta.dot(height_axis)
		uu += weight * x * x
		uv += weight * x * y
		vv += weight * y * y
		uh += weight * x * height
		vh += weight * y * height
	var determinant := uu * vv - uv * uv
	if determinant <= 1e-6 * maxf(1.0, uu * vv):
		return {"ok": false}
	var slope_u := (uh * vv - vh * uv) / determinant
	var slope_v := (vh * uu - uh * uv) / determinant
	var normal := (height_axis - slope_u * u - slope_v * v).normalized()
	if normal.dot(seed) < FIT_MIN_TILT:
		return {"ok": false}
	return {"ok": true, "normal": normal, "centroid": centroid}
