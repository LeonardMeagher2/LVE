class_name TerrainGeometry
extends RefCounted

const BrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")

## Pure geometry and surface helpers for the terrain tools.
##
## The helpers hold no state. The tool and the tests share them, so the
## footprint, the falloff, and the column surface have one definition.

## The smallest tilt from the seed normal that a surface plane accepts.
const MIN_NORMAL_TILT := 0.3
## The margin by which one axis must beat another to become the dominant axis.
## A near tie keeps the preferred axis, so a surface normal never flips its
## dominant axis between two reads of one unchanged 45 degree surface.
const AXIS_TIE_EPSILON := 1e-3
## The disc offsets between two cancel checks of one worker read. One offset is one
## bounded surface walk, so a small value bounds the work between two cancels.
const READ_CANCEL_CHECKPOINT := 32

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


## Returns the stable logical column key of one cell and normal. The axis and its
## signed orientation join the two lateral world coordinates.
static func column_key(cell: Vector3i, normal: Vector3) -> Vector3i:
	var axis := dominant_axis(normal)
	var sign_bit := 1 if normal[axis] >= 0.0 else 0
	return Vector3i(axis * 2 + sign_bit, cell[(axis + 1) % 3], cell[(axis + 2) % 3])


## Returns the neighbor of a surface cell one layer along the dominant axis of
## the normal. [param direction] is 1 outward and -1 inward. Flatten uses this
## one-cell step toward its plane.
static func dominant_step(surface: Vector3i, normal: Vector3, direction: int) -> Vector3i:
	var axis := dominant_axis(normal)
	var sign := 1 if normal[axis] >= 0.0 else -1
	if direction < 0:
		sign = -sign
	var cell := surface
	cell[axis] += sign
	return cell


## Returns the cells of one Build or Dig step and the surface of the next step.
##
## The step is one cardinal cell along the dominant axis of the normal. A gentle
## plane grows upward. A steep plane grows sideways. The plane still shows the
## slope, and the layer stays one cell thick.
##
## Build writes the empty cell outward. Dig clears the surface and continues
## inward while the next cell is occupied. An empty surface seeds one cell on the
## captured floor for Add. [param add] is true for Build and false for Dig.
static func build_layer_cells(frame: VoxelFrame, changes: Dictionary, surface: Vector3i, normal: Vector3, seed: Vector3i, add: bool, selection: Dictionary) -> Dictionary:
	var cells: Array[Vector3i] = []
	if surface == VoxelPicking.NONE:
		if not add:
			return {"cells": cells, "next": VoxelPicking.NONE}
		if is_occupied(frame, changes, seed) or not allows(selection, seed):
			return {"cells": cells, "next": VoxelPicking.NONE}
		cells.append(seed)
		return {"cells": cells, "next": seed}
	if add:
		var destination := dominant_step(surface, normal, 1)
		if is_occupied(frame, changes, destination) or not allows(selection, destination):
			return {"cells": cells, "next": VoxelPicking.NONE}
		cells.append(destination)
		return {"cells": cells, "next": destination}
	if not allows(selection, surface):
		return {"cells": cells, "next": VoxelPicking.NONE}
	cells.append(surface)
	var inward := dominant_step(surface, normal, -1)
	var next := VoxelPicking.NONE
	if is_occupied(frame, changes, inward):
		next = inward
	return {"cells": cells, "next": next}


## Returns the falloff weight for one distance from the center. The size is the
## brush diameter, so the falloff radius is half of it.
##
## A zero falloff gives a hard edge. A falloff of one gives a smooth edge.
##
## [param inner] is the distance of the nearest brush cell. An odd size centers
## on one cell, so its nearest distance is zero. An even size centers between
## four cells, so its nearest distance is not zero. The falloff starts at that
## ring, so the center ring of every size weighs exactly one. A weight that never
## reaches one would lose the whole step of a strength-one dab.
static func weight_at(distance: float, size: float, falloff: float, inner := 0.0) -> float:
	var radius := size * 0.5
	if radius <= 0.0:
		return 1.0
	var start := clampf(inner, 0.0, radius)
	var span := radius - start
	if span <= 0.0:
		return 1.0
	var t := clampf((distance - start) / span, 0.0, 1.0)
	var smooth := 1.0 - (t * t * (3.0 - 2.0 * t))
	return lerpf(1.0, smooth, clampf(falloff, 0.0, 1.0))


## Returns the distance of the nearest disk cell from the disk center.
##
## It is the start of the disk falloff. An odd size centers on a cell, so the
## result is zero. An even size centers half a cell from four cells, so the
## result is the half-cell diagonal. Pass it to [method weight_at] for a disk.
static func disk_inner(size: int) -> float:
	var center := BrushSize.center_offset(clampi(size, 1, 64))
	var offset := absf(float(roundi(center)) - center)
	return offset * sqrt(2.0)


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
## in-plane offsets and the distance from the center. The size is the brush
## diameter, so 1 is one cell and 2 is a 2x2 block.
##
## The result is cached per size. The array and every entry dictionary are
## read-only, and a mutex guards the build, so a preview worker can read one
## size while the main thread builds another. A caller must not change an
## entry. One preview at a high size asks for the disc several times, so the
## cache removes the repeated allocation and square root of every entry.
static func disk_offsets(size: int) -> Array:
	var use_size := clampi(size, 1, 64)
	_disk_lock.lock()
	var cached: Array = _disk_cache.get(use_size, [])
	_disk_lock.unlock()
	if not cached.is_empty():
		return cached
	var offsets := BrushSize.disk_offsets(use_size)
	for entry in offsets:
		entry.make_read_only()
	offsets.make_read_only()
	_disk_lock.lock()
	var existing: Array = _disk_cache.get(use_size, [])
	if existing.is_empty():
		_disk_cache[use_size] = offsets
		cached = offsets
	else:
		cached = existing
	_disk_lock.unlock()
	return cached


static var _disk_cache := {}
static var _disk_lock := Mutex.new()


## Returns the integer offsets of a sphere of the size.
##
## Each entry holds the world-cell offset and its distance from the center. The
## size is the diameter, so size 1 is one cell. The result is cached per size and
## read-only, like [method disk_offsets].
static func sphere_offsets(size: int) -> Array:
	var use_size := clampi(size, 1, 64)
	_disk_lock.lock()
	var cached: Array = _sphere_cache.get(use_size, [])
	_disk_lock.unlock()
	if not cached.is_empty():
		return cached
	var radius := float(use_size) * 0.5
	var limit := ceili(radius)
	var squared := radius * radius
	var offsets := []
	for x in range(-limit, limit + 1):
		for y in range(-limit, limit + 1):
			for z in range(-limit, limit + 1):
				var cell := Vector3i(x, y, z)
				if cell.length_squared() > squared:
					continue
				var entry := {"offset": cell, "distance": Vector3(cell).length()}
				entry.make_read_only()
				offsets.append(entry)
	offsets.make_read_only()
	_disk_lock.lock()
	var existing: Array = _sphere_cache.get(use_size, [])
	if existing.is_empty():
		_sphere_cache[use_size] = offsets
		cached = offsets
	else:
		cached = existing
	_disk_lock.unlock()
	return cached


static var _sphere_cache := {}


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
## never leaves its column. It also rejects a query whose whole ray misses the
## occupied bounds of that snapshot, because every read cell of the walk holds a
## point of the ray. The result is identical, so a caller without a context keeps
## the walk.
static func surface_along(frame: VoxelFrame, point: Vector3, normal: Vector3, depth: int, changes := {}, context: TerrainQueryContext = null) -> Vector3i:
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
	# column returns NONE with no walk. Every read cell of any walk also holds a
	# point of the ray, so a ray that misses the occupied bounds reads nothing.
	# Both are exact, so the result never changes.
	if context != null and changes.is_empty():
		var cardinal := cardinal_axis(normal)
		if cardinal >= 0 and context.column_empty(cardinal, origin_cell):
			return VoxelPicking.NONE
		if context.misses_bounds(point, normal):
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


## Returns the next Flatten action for one sample. The result holds the cell, an
## add flag, and a settled flag. A [constant VoxelPicking.NONE] cell means the
## sample cannot act. The execution and the preview share this rule.
##
## The target band is one cell thick. A cell whose outer face sits on the plane
## is at distance -0.5, so the test accepts the half-cell band around it.
##
## An empty column fills the cell just inside the plane. The plane comes from the
## stroke, not from the floor, so a stroke that started on a surface fills at that
## surface when it leaves the model. It never drops a layer at another depth.
static func flatten_action(frame: VoxelFrame, changes: Dictionary, surface: Vector3i, normal: Vector3, anchor: Vector3i, plane_origin: Vector3, threshold: float, selection: Dictionary) -> Dictionary:
	if surface == VoxelPicking.NONE:
		var axis := dominant_axis(normal)
		var sign := 1 if normal[axis] >= 0.0 else -1
		var plane_seed := anchor
		plane_seed[axis] = roundi(plane_origin[axis] - float(sign) * 0.5)
		if is_occupied(frame, changes, plane_seed) or not allows(selection, plane_seed):
			return {"cell": VoxelPicking.NONE}
		return {"cell": plane_seed, "add": true, "seed": true}
	var distance := (Vector3(surface) - plane_origin).dot(normal)
	if absf(distance + 0.5) <= threshold:
		return {"cell": VoxelPicking.NONE, "settled": true}
	if distance + 0.5 > 0.0:
		if not allows(selection, surface):
			return {"cell": VoxelPicking.NONE}
		return {"cell": surface, "add": false}
	var destination := dominant_step(surface, normal, 1)
	if is_occupied(frame, changes, destination) or not allows(selection, destination):
		return {"cell": VoxelPicking.NONE}
	return {"cell": destination, "add": true}


## Returns the exposed face boundary points around a hit. The points come from
## the connected outward surface only, so an opposing wall or a cave floor is
## excluded. Each point holds the boundary position and its weight.
##
## [param job] supplies the cancel checkpoints of a worker. [param context] is an
## optional exact read-only column index of the same frame snapshot. A cancelled
## read returns no points, so the caller keeps its fallback and the job publishes
## nothing. The point order and the query stream are unchanged.
static func surface_points(frame: VoxelFrame, hit: Vector3i, entry: Vector3i, radius: int, job: VoxelFrame.EditJob = null, context: TerrainQueryContext = null) -> Array:
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
		if job != null and completed % READ_CANCEL_CHECKPOINT == 0 and not job.checkpoint(completed):
			return []
		if surface == VoxelPicking.NONE:
			continue
		var key := Vector2i(offset["u"], offset["v"])
		columns[key] = {
			"point": Vector3(surface) + entry_normal * 0.5,
			"weight": weight_at(offset["distance"], float(use_radius), 0.5, disk_inner(use_radius)),
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


## Reads the surface height gradient across a disc. The two derivatives
## define the normal. Missing or collinear heights cannot define a plane.
##
## The derivatives are measured in a proper orthonormal frame: the signed
## cardinal axis of the seed is the height axis, and the other two cardinal axes
## are in plane. The seed only sets that height axis and the outward orientation,
## so repeated reads of one unchanged surface give one normal.
static func surface_gradient(points: Array, seed: Vector3) -> Dictionary:
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
	if normal.dot(seed) < MIN_NORMAL_TILT:
		return {"ok": false}
	return {"ok": true, "normal": normal, "centroid": centroid}
