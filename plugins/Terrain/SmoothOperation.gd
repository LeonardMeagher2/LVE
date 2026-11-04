extends RefCounted

## Pure 3D occupancy rounding for the Smooth terrain tool.
##
## The module rounds a local voxel surface in three dimensions. It reads a
## frozen occupancy set and decides which occupied surface cells to remove and
## which empty cells to fill. A convex edge or corner loses cells, so it becomes
## a bevel. A concave notch or inside corner gains cells, so it fills. A one-cell
## plate or wall has a symmetric face neighborhood, so it has no defined normal
## and it stays. A flat solid face has a defined normal, but its kernel density
## is above the removal threshold, so it stays too.
## An isolated writable voxel is removed. Newly isolated remnants are removed
## only when they earned an application in the same pass.
##
## One pass is a Jacobi step. Every candidate cell reads the frozen occupancy of
## its neighborhood, so the result never depends on the iteration order. The
## caller applies the remove and the add sets to the voxel cells. The caller
## keeps the full material of an existing cell and chooses the local source
## material for a new fill.
##
## A dab takes a whole number of passes. Each candidate cell takes a part of those
## passes: its falloff weight scales the pass count, and a fraction below one half
## takes no pass. A weight of one takes every pass, and a smaller weight takes
## fewer, so a soft patch edge rounds slower than a hard center. The budget is
## keyed by world cell, so the result is deterministic and no cell is sampled at
## random. No fraction carries into the next dab.
##
## A cell key is a world cell. The module holds no state. The caller owns the
## occupancy, the candidate cells, and the weights. The tool and the tests share
## the module, so the rounding rule has one definition.
##
## A radius of [constant BROAD_RADIUS] or more selects the broad rounding rule.
## The broad rule rounds a convex edge or corner by the ball radius instead of
## one cell, so a long edge becomes a rounded ridge. It is a morphological
## opening for the removal and a closing for the fill, with one ball. Each
## operation is idempotent alone. The combined rule is bounded: no cell moves
## more than the ball radius in one pass, and every measured shape stops
## changing after a small number of passes. A thin feature keeps the base density
## rule for both the removal and the fill, so no feature thinner than the ball
## vanishes and no cell oscillates between the two rules. The base rule stays
## unchanged at radius one.
##
## A caller that gathers the occupancy must read at least [method required_halo]
## cells beyond every candidate. [method read_offsets] returns the exact offsets
## the rule reads, so a sparse gather reads that set instead of a large cube.

## The six face-neighbor offsets of one cell. The signed sum of the occupied
## offsets gives the outward surface normal. A cell in a one-cell plate or wall
## has a symmetric face neighborhood, so it has no defined normal and the
## rounding leaves it alone. A flat solid face has a defined normal, but its
## density is high enough to keep it. The face offsets keep a diagonal
## protrusion from tilting the normal of a neighboring thin cell.
const NEIGHBOR_OFFSETS := [
	Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
	Vector3i(0, -1, 0), Vector3i(0, 1, 0),
	Vector3i(0, 0, -1), Vector3i(0, 0, 1),
]

## The default radius of the local occupancy density kernel. A radius of one
## gives a 3x3x3 kernel, which rounds a convex edge by one cell and a corner by
## a few cells, and never erodes a flat face or a two-cell plate.
const KERNEL_RADIUS := 1

## The radius at and above which the broad rounding rule replaces the base
## density rule. A radius of two rounds a convex edge by two cells, which is the
## smallest step that reads as a rounded ridge instead of a single bevel.
const BROAD_RADIUS := 2

## The multiple of the ball radius below which the broad rule treats a local
## solid as a thin feature. A cell of a feature thinner than
## [code]THIN_MULTIPLIER * radius[/code] cells keeps the base density rule, so a
## plate, a wall, a spike, or a small cube never vanishes. A ball of the radius
## cannot fit in such a feature, so the broad opening would erase it.
const THIN_MULTIPLIER := 3

## The largest ball radius the broad rule accepts. A caller that asks for more
## gets this radius, so an accidental large radius never allocates an unbounded
## offset set. The tool uses two or three.
const MAX_ROUNDING_RADIUS := 4

## The occupied fraction below which a convex surface cell is removed. A flat
## face holds 18 of 27 neighbors, so it stays. A convex edge holds 12, so it
## goes.
const REMOVE_THRESHOLD := 0.5
## The occupied fraction above which a concave empty cell is filled.
const ADD_THRESHOLD := 0.5

## The most passes one [method advance] call runs.
const MAX_PASSES_PER_CALL := 8

## The candidate count between two cancellation checks of one pass.
const CHECKPOINT_INTERVAL := 512

static var _kernel_cache := {}
static var _ball_cache := {}
static var _read_cache := {}
# The caches hold immutable offset arrays. A worker and the main thread can ask
# for the offsets at the same time, so every get or create takes the lock.
static var _cache_lock := Mutex.new()


## Returns the outward unit surface normal of one cell, or null when the cell
## sits in a locally symmetric feature.
##
## The normal is the reverse of the signed sum of the occupied face offsets. The
## middle of a one-cell plate or wall gives a zero sum, so the cell has no
## defined normal and the rounding leaves it alone. A flat solid face gives a
## nonzero sum.
static func surface_normal(occupied: Dictionary, cell: Vector3i) -> Variant:
	var gradient := Vector3i.ZERO
	for offset: Vector3i in NEIGHBOR_OFFSETS:
		if occupied.has(cell + offset):
			gradient += offset
	if gradient == Vector3i.ZERO:
		return null
	return -Vector3(gradient).normalized()


static func _has_face_neighbor(occupied: Dictionary, cell: Vector3i) -> bool:
	for offset: Vector3i in NEIGHBOR_OFFSETS:
		if occupied.has(cell + offset):
			return true
	return false


## Returns the occupied fraction of the kernel around one cell. The fraction is
## the occupied count over the kernel size, so it is a deterministic rational.
static func occupied_fraction(occupied: Dictionary, cell: Vector3i, radius := KERNEL_RADIUS) -> float:
	var offsets: Array = kernel_offsets(radius)
	var count := 0
	for offset: Vector3i in offsets:
		if occupied.has(cell + offset):
			count += 1
	return float(count) / float(offsets.size())


## Returns the offsets of the cubic kernel of one radius, cached. The kernel
## includes the cell itself.
##
## The result is shared and read only. Never change it. Use
## [method read_offsets] when a caller needs a set it can change.
static func kernel_offsets(radius: int) -> Array:
	var use_radius := maxi(radius, 1)
	_cache_lock.lock()
	if _kernel_cache.has(use_radius):
		var cached: Array = _kernel_cache[use_radius]
		_cache_lock.unlock()
		return cached
	var offsets: Array = []
	for x in range(-use_radius, use_radius + 1):
		for y in range(-use_radius, use_radius + 1):
			for z in range(-use_radius, use_radius + 1):
				offsets.append(Vector3i(x, y, z))
	# The doc promises a read-only shared set, so a caller cannot corrupt the
	# cache for a preview worker or a later pass. Use read_offsets for a set a
	# caller can change.
	offsets.make_read_only()
	_kernel_cache[use_radius] = offsets
	_cache_lock.unlock()
	return offsets


## Returns the offsets of the solid Euclidean ball of one radius, cached. The
## ball holds every offset whose length is at most the radius, so a translation
## of the ball is a rotation-free sphere. The broad rounding rule uses the ball,
## because a cube kernel cannot round a diagonal edge without reading its
## staircase as a corner. The ball includes the cell itself.
##
## The offsets are sorted by distance, so the nearest neighbor is first. A caller
## that scans the ball then tests the likely cover first.
##
## The result is a fresh array. A caller can keep or change it without touching
## the cache. The radius is capped at [constant MAX_ROUNDING_RADIUS], so the set
## stays bounded.
static func ball_offsets(radius: int) -> Array:
	var use_radius := clampi(radius, 1, 2 * MAX_ROUNDING_RADIUS)
	_cache_lock.lock()
	if not _ball_cache.has(use_radius):
		var offsets: Array = []
		var squared := use_radius * use_radius
		for x in range(-use_radius, use_radius + 1):
			for y in range(-use_radius, use_radius + 1):
				for z in range(-use_radius, use_radius + 1):
					var point := Vector3i(x, y, z)
					if point.length_squared() <= squared:
						offsets.append(point)
		offsets.sort_custom(_order_offsets)
		_ball_cache[use_radius] = offsets
	var cached: Array = _ball_cache[use_radius]
	_cache_lock.unlock()
	return cached.duplicate()


## Returns the number of cells around a candidate that the rounding rule can
## read. The caller must gather the occupancy at least this far beyond every
## candidate, or a border decision can be wrong. A radius of one keeps the base
## halo of one cell. A broad radius reads two balls for the opening and the
## closing, and the axis probes of [method _thin_solid], so the halo follows the
## larger of the two.
static func required_halo(radius: int) -> int:
	if radius < BROAD_RADIUS:
		return 1
	var use_radius := clampi(radius, 1, MAX_ROUNDING_RADIUS)
	return maxi(2 * use_radius, THIN_MULTIPLIER * use_radius)


## Returns the exact offsets a candidate reads, as a fresh sorted array. A sparse
## gather can read this set around a candidate instead of a full cube, so a broad
## radius never reads a whole large cube. The set is the two balls of the opening
## and the closing, plus the axis probes of [method _thin_solid]. A radius of one
## returns the base cubic kernel.
static func read_offsets(radius: int) -> Array:
	if radius < BROAD_RADIUS:
		return kernel_offsets(1).duplicate()
	var use_radius := clampi(radius, 1, MAX_ROUNDING_RADIUS)
	var ball := ball_offsets(use_radius * 2)
	_cache_lock.lock()
	if not _read_cache.has(use_radius):
		var seen := {}
		for offset: Vector3i in ball:
			seen[offset] = true
		var reach := THIN_MULTIPLIER * use_radius
		for axis in 3:
			for step in range(1, reach + 1):
				seen[NEIGHBOR_OFFSETS[axis * 2] * step] = true
				seen[NEIGHBOR_OFFSETS[axis * 2 + 1] * step] = true
		var offsets: Array = seen.keys()
		offsets.sort_custom(_order_offsets)
		_read_cache[use_radius] = offsets
	var cached: Array = _read_cache[use_radius]
	_cache_lock.unlock()
	return cached.duplicate()


# Orders offsets by squared length, then by the cell, so the nearest offset is
# first and two runs always agree.
static func _order_offsets(a: Vector3i, b: Vector3i) -> bool:
	var distance_a := a.length_squared()
	var distance_b := b.length_squared()
	if distance_a != distance_b:
		return distance_a < distance_b
	if a.z != b.z:
		return a.z < b.z
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x


## Returns one weighted rounding pass over a frozen occupancy set.
##
## [param budget] maps a cell to the number of passes it takes in this dab. The
## caller builds it from the strength and the falloff weight of each cell, so a
## soft edge takes fewer passes and never carries a fraction. A cell is evaluated
## only on a pass below its budget. The decisions of one pass read the frozen
## occupancy, so the result never depends on the iteration order.
##
## The result holds "remove", "add", and "evaluated". The evaluated cells can also
## lose isolated remnants after the pass. [param cancel] receives the evaluated
## count and stops the pass when it returns false. A stopped pass holds
## "cancelled": true.
##
## A [param radius] of [constant BROAD_RADIUS] or more runs the broad rounding
## rule. The rule is one morphological opening and closing with the ball of that
## radius. An occupied cell is removed when no translated ball inside the
## occupancy covers it, so a convex edge or corner loses the cells a ball cannot
## reach. An empty cell is filled when every cell of its ball touches the
## occupancy, so a concave notch gains the cells a ball cannot enter. The opening
## and the closing are each idempotent on their own. This rule runs both on one
## frozen occupancy and falls back to the base rule for a thin cell, so the
## combined operator is not proven idempotent. It is bounded: no cell moves more
## than the ball radius in one pass, and the result stops changing after a small
## number of passes on every measured shape. A thin feature uses the base rule
## to preserve supported walls and spikes.
static func weighted_pass(occupied: Dictionary, cells: Array, budget: Dictionary, pass_index: int, radius := KERNEL_RADIUS, remove_threshold := REMOVE_THRESHOLD, add_threshold := ADD_THRESHOLD, cancel := Callable()) -> Dictionary:
	# The broad rule reads the frozen occupancy on demand for each candidate, so
	# a pass with no broad candidate does no broad work. The two memo tables hold
	# the ball tests of the cells a candidate actually reads. Both are local to
	# this pass, so the frozen input alone decides the result.
	var use_radius := clampi(radius, 1, MAX_ROUNDING_RADIUS)
	var broad := use_radius >= BROAD_RADIUS
	var ball: Array = []
	if broad:
		ball = ball_offsets(use_radius)
	var host_memo := {}
	var touch_memo := {}
	# The base density rule always reads the one-cell kernel, so its decision is
	# unchanged when a caller selects the broad radius.
	var base_radius := mini(radius, KERNEL_RADIUS)
	var remove := []
	var add := []
	var evaluated := []
	var completed := 0
	for cell: Vector3i in cells:
		if pass_index >= int(budget.get(cell, 0)):
			continue
		evaluated.append(cell)
		completed += 1
		if cancel.is_valid() and completed % CHECKPOINT_INTERVAL == 0 and not cancel.call(completed):
			return {"cancelled": true}
		if surface_normal(occupied, cell) == null:
			if occupied.has(cell) and not _has_face_neighbor(occupied, cell):
				remove.append(cell)
			continue
		if occupied.has(cell):
			if _protected_thin(occupied, cell):
				continue
			if broad and not _thin_solid(occupied, cell, use_radius):
				var normal: Vector3 = surface_normal(occupied, cell)
				var inward := -Vector3i(int(signf(normal.x)), int(signf(normal.y)), int(signf(normal.z)))
				if not _covered(occupied, host_memo, ball, cell, inward):
					remove.append(cell)
			elif occupied_fraction(occupied, cell, base_radius) < remove_threshold:
				remove.append(cell)
		else:
			if broad and not _thin_around(occupied, cell, use_radius) and _enclosed(occupied, touch_memo, ball, cell):
				add.append(cell)
			elif occupied_fraction(occupied, cell, base_radius) > add_threshold:
				add.append(cell)
	remove.sort()
	add.sort()
	return {"remove": remove, "add": add, "evaluated": evaluated}


# True when a translated ball of the radius around some cell near the candidate
# is fully inside the occupancy, so that copy of the ball covers the candidate
# and the opening keeps it. The inward half of the ball runs first, so a solid or
# a flat face finds its cover at once. A candidate with no cover lies too close
# to a convex edge or corner for the ball to fit, and the opening removes it.
static func _covered(occupied: Dictionary, memo: Dictionary, ball: Array, cell: Vector3i, inward: Vector3i) -> bool:
	var direction := Vector3(inward)
	for offset: Vector3i in ball:
		if Vector3(offset).dot(direction) >= 0.0 and _hosts(occupied, memo, ball, cell + offset):
			return true
	for offset: Vector3i in ball:
		if Vector3(offset).dot(direction) < 0.0 and _hosts(occupied, memo, ball, cell + offset):
			return true
	return false


# True when the ball around every cell near the candidate touches the occupancy,
# so the closing fills the candidate. The farthest offsets run first, so a convex
# surface fails on the first empty outside cell and only a real concavity reads
# the whole ball. The memo table holds the test of each cell the pass already
# asked about, so the cost stays one ball test per cell.
static func _enclosed(occupied: Dictionary, memo: Dictionary, ball: Array, cell: Vector3i) -> bool:
	for index in range(ball.size() - 1, -1, -1):
		if not _touches(occupied, memo, ball, cell + ball[index]):
			return false
	return true


# True when the whole ball around the cell is occupied, memoized. The six face
# offsets are in the ball, so a missing face neighbor rules the cell out at once.
static func _hosts(occupied: Dictionary, memo: Dictionary, ball: Array, cell: Vector3i) -> bool:
	if memo.has(cell):
		return memo[cell]
	var result := true
	for offset: Vector3i in NEIGHBOR_OFFSETS:
		if not occupied.has(cell + offset):
			result = false
			break
	if result:
		for offset: Vector3i in ball:
			if not occupied.has(cell + offset):
				result = false
				break
	memo[cell] = result
	return result


# True when the ball around the cell holds any occupied cell, memoized. The
# center is in the ball, so an occupied cell is always a touch.
static func _touches(occupied: Dictionary, memo: Dictionary, ball: Array, cell: Vector3i) -> bool:
	if memo.has(cell):
		return memo[cell]
	var result := false
	for offset: Vector3i in ball:
		if occupied.has(cell + offset):
			result = true
			break
	memo[cell] = result
	return result


# True when the local solid through the cell is at or below the thin limit. The
# thickness of an axis is the cell plus the occupied run on each side, capped at
# the limit. A sheet, a wall, a spike, or a small cube is at or below the limit,
# so it keeps the base rule and never vanishes. A large solid is above the limit,
# so the broad opening rounds it.
static func _thin_solid(occupied: Dictionary, cell: Vector3i, radius: int) -> bool:
	var limit := THIN_MULTIPLIER * clampi(radius, 1, MAX_ROUNDING_RADIUS)
	for axis in 3:
		# A run that already reaches the limit makes the axis thicker than the
		# limit, so the other side and the compare are skipped.
		var negative := _run(occupied, cell, NEIGHBOR_OFFSETS[axis * 2], limit)
		if negative >= limit:
			continue
		var positive := _run(occupied, cell, NEIGHBOR_OFFSETS[axis * 2 + 1], limit)
		if positive >= limit:
			continue
		if 1 + negative + positive <= limit:
			return true
	return false


# True when the solid next to an empty cell is a thin feature. The open axes of a
# concavity are skipped, so an inside corner of a thick solid reads as thick and
# the closing can fill it. A thin ridge, plate, or wall next to the cell reads as
# thin, so the closing leaves it to the base rule and the cell never oscillates
# with the base removal.
static func _thin_around(occupied: Dictionary, cell: Vector3i, radius: int) -> bool:
	var limit := THIN_MULTIPLIER * clampi(radius, 1, MAX_ROUNDING_RADIUS)
	for axis in 3:
		var negative := _run(occupied, cell, NEIGHBOR_OFFSETS[axis * 2], limit)
		var positive := _run(occupied, cell, NEIGHBOR_OFFSETS[axis * 2 + 1], limit)
		if negative == 0 and positive == 0:
			continue
		if negative >= limit or positive >= limit:
			continue
		if negative + positive <= limit:
			return true
	return false


# Returns the occupied run length from one step along the direction, capped at the
# limit. The run stops at the first empty cell or at the limit.
static func _run(occupied: Dictionary, cell: Vector3i, direction: Vector3i, limit: int) -> int:
	var length := 0
	var point := cell
	while length < limit and occupied.has(point + direction):
		point += direction
		length += 1
	return length


# True when the cell belongs to a thin, laterally supported feature that the
# rounding must not erode. A one-cell plate or wall body has an empty face
# neighbor on both sides of one axis and an occupied face neighbor on both sides
# of another axis. A one-cell spike, edge, or corner has no axis with both face
# neighbors occupied, so it is not protected and it rounds.
static func _protected_thin(occupied: Dictionary, cell: Vector3i) -> bool:
	var opposite_empty := false
	var supported := false
	for axis in 3:
		var negative := occupied.has(cell + NEIGHBOR_OFFSETS[axis * 2])
		var positive := occupied.has(cell + NEIGHBOR_OFFSETS[axis * 2 + 1])
		if not negative and not positive:
			opposite_empty = true
		elif negative and positive:
			supported = true
	return opposite_empty and supported


## Returns the occupancy after [param passes] weighted rounding passes.
##
## The result holds "occupied", "remove", and "add". "remove" and "add" hold the
## candidate cells whose state differs from the input, sorted. The input set is
## unchanged. A pass count of zero or less returns a copy of the input. A
## cancelled pass returns an unchanged occupancy with "cancelled": true.
##
## [param weights] maps a cell to its falloff weight. The first pass evaluates a
## cell only when its weight reaches one half, and later passes need more weight.
## The caller sets the pass count from the strength, so a dab never carries a
## fraction to the next dab.
static func relax(occupied: Dictionary, cells: Array, passes := 1, radius := KERNEL_RADIUS, remove_threshold := REMOVE_THRESHOLD, add_threshold := ADD_THRESHOLD, weights := {}, cancel := Callable()) -> Dictionary:
	var current := occupied.duplicate()
	var ordered := cells.duplicate()
	ordered.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return a.y < b.y if a.y != b.y else (a.z < b.z if a.z != b.z else a.x < b.x))
	var use_passes := maxi(passes, 0)
	var budget := {}
	for cell: Vector3i in ordered:
		budget[cell] = roundi(float(use_passes) * clampf(float(weights.get(cell, 1.0)), 0.0, 1.0))
	for pass_index in use_passes:
		var outcome := weighted_pass(current, ordered, budget, pass_index, radius, remove_threshold, add_threshold, cancel)
		if outcome.has("cancelled"):
			return {"occupied": occupied.duplicate(), "remove": [], "add": [], "cancelled": true}
		for cell: Vector3i in outcome["remove"]:
			current.erase(cell)
		for cell: Vector3i in outcome["add"]:
			current[cell] = true
		# The cleanup removes an isolated remnant. A removal can strand a middle
		# cell. A fill can only add a cell next to the occupancy, because the
		# closing keeps a cell only when every ball cell around it touches the
		# solid. The program cannot prove that an added cell always keeps a face
		# neighbor, so the cleanup also runs after a pass that only fills.
		if not (outcome["remove"] as Array).is_empty() or not (outcome["add"] as Array).is_empty():
			# A symmetric middle can lose every neighbor in this pass. Limit the
			# cleanup to evaluated candidates, never read-only halo cells or cells
			# that have not earned enough falloff credit. Removing an isolated cell
			# cannot disconnect another cell, so this remains order independent.
			var completed := 0
			for cell: Vector3i in outcome["evaluated"]:
				if current.has(cell) and not _has_face_neighbor(current, cell):
					current.erase(cell)
				completed += 1
				if cancel.is_valid() and completed % CHECKPOINT_INTERVAL == 0 and not cancel.call(completed):
					return {"occupied": occupied.duplicate(), "remove": [], "add": [], "cancelled": true}
	var remove := []
	var add := []
	for cell: Vector3i in cells:
		var before := occupied.has(cell)
		var after := current.has(cell)
		if before and not after:
			remove.append(cell)
		elif not before and after:
			add.append(cell)
	remove.sort()
	add.sort()
	return {"occupied": current, "remove": remove, "add": add}


## Advances the rounding by one dab.
##
## [param passes] is the strength of the dab. [param weights] maps a cell to its
## falloff weight, so a cell with a low weight takes fewer of those passes. The
## result holds "occupied", "remove", "add", and "passes".
##
## The pass count is an integer, so one dab always applies whole passes. No time
## and no fraction carries into the next dab.
##
## A call with no candidate cell runs no pass.
static func advance(occupied: Dictionary, cells: Array, passes: int, radius := KERNEL_RADIUS, remove_threshold := REMOVE_THRESHOLD, add_threshold := ADD_THRESHOLD, weights := {}, cancel := Callable()) -> Dictionary:
	if cells.is_empty():
		return {"occupied": occupied.duplicate(), "remove": [], "add": [], "passes": 0}
	var use_passes := mini(maxi(passes, 0), MAX_PASSES_PER_CALL)
	var outcome := relax(occupied, cells, use_passes, radius, remove_threshold, add_threshold, weights, cancel)
	outcome["passes"] = use_passes
	return outcome
