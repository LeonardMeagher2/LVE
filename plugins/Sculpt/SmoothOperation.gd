extends RefCounted

## Pure 3D occupancy rounding for the Smooth sculpt tool.
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
## Every candidate earns a persistent fractional credit. A candidate earns its
## weight in the credit each pass. A candidate whose credit reaches one is
## evaluated and loses one credit. A weight of one evaluates every pass, and a
## smaller weight evaluates less often, so a soft patch edge rounds slower than a
## hard center. The credit is keyed by world cell, so the rate is deterministic
## and no cell is sampled at random.
##
## A cell key is a world cell. The module holds no state. The caller owns the
## occupancy, the candidate cells, the weights, the credits, and the fractional
## pass carry. The tool and the tests share the module, so the rounding rule has
## one definition.

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

## The occupied fraction below which a convex surface cell is removed. A flat
## face holds 18 of 27 neighbors, so it stays. A convex edge holds 12, so it
## goes.
const REMOVE_THRESHOLD := 0.5
## The occupied fraction above which a concave empty cell is filled.
const ADD_THRESHOLD := 0.5

## The most passes one [method advance] call runs.
const MAX_PASSES_PER_CALL := 8

## The pass-boundary tolerance for elapsed-time rounding.
const PASS_EPSILON := 1e-9
## The credit tolerance that decides a whole earned credit.
const CREDIT_EPSILON := 1e-9
## The candidate count between two cancellation checks of one pass.
const CHECKPOINT_INTERVAL := 512

static var _kernel_cache := {}


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
static func kernel_offsets(radius: int) -> Array:
	var use_radius := maxi(radius, 1)
	if _kernel_cache.has(use_radius):
		return _kernel_cache[use_radius]
	var offsets: Array = []
	for x in range(-use_radius, use_radius + 1):
		for y in range(-use_radius, use_radius + 1):
			for z in range(-use_radius, use_radius + 1):
				offsets.append(Vector3i(x, y, z))
	_kernel_cache[use_radius] = offsets
	return offsets


## Returns one weighted rounding pass over a frozen occupancy set.
##
## Every candidate earns its weight in [param credits] and loses one credit when
## it is evaluated. A candidate is evaluated when its credit reaches one. The
## decisions of one pass read the frozen occupancy, so the result never depends
## on the iteration order. [param weights] maps a cell to its rate weight. A
## missing weight is one.
##
## The result holds "remove", "add", "credits", and "evaluated". The evaluated
## cells can also lose isolated remnants after the pass. Pass the same credits to the
## next pass. [param cancel] receives the evaluated count and stops the pass when
## it returns false. A stopped pass holds "cancelled": true.
static func weighted_pass(occupied: Dictionary, cells: Array, weights: Dictionary, credits: Dictionary, radius := KERNEL_RADIUS, remove_threshold := REMOVE_THRESHOLD, add_threshold := ADD_THRESHOLD, cancel := Callable()) -> Dictionary:
	var completed := 0
	for cell: Vector3i in cells:
		var earned := float(credits.get(cell, 0.0)) + clampf(float(weights.get(cell, 1.0)), 0.0, 1.0)
		# Keep the fractional excess after an evaluation. Clamping the total to
		# one would reduce a three-quarter rate to one evaluation every two passes.
		credits[cell] = earned
		completed += 1
		if cancel.is_valid() and completed % CHECKPOINT_INTERVAL == 0 and not cancel.call(completed):
			return {"cancelled": true, "credits": credits}
	var remove := []
	var add := []
	var evaluated := []
	completed = 0
	for cell: Vector3i in cells:
		if float(credits.get(cell, 0.0)) < 1.0 - CREDIT_EPSILON:
			continue
		credits[cell] = maxf(0.0, float(credits[cell]) - 1.0)
		evaluated.append(cell)
		completed += 1
		if cancel.is_valid() and completed % CHECKPOINT_INTERVAL == 0 and not cancel.call(completed):
			return {"cancelled": true, "credits": credits}
		if surface_normal(occupied, cell) == null:
			if occupied.has(cell) and not _has_face_neighbor(occupied, cell):
				remove.append(cell)
			continue
		var fraction := occupied_fraction(occupied, cell, radius)
		if occupied.has(cell):
			if _protected_thin(occupied, cell):
				continue
			if fraction < remove_threshold:
				remove.append(cell)
		elif fraction > add_threshold:
			add.append(cell)
	remove.sort()
	add.sort()
	return {"remove": remove, "add": add, "credits": credits, "evaluated": evaluated}


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
## The result holds "occupied", "remove", "add", and "credits". "remove" and
## "add" hold the candidate cells whose state differs from the input, sorted.
## The input set and the input credits are unchanged. A pass count of zero or
## less returns a copy of the input. A cancelled pass returns an unchanged
## occupancy with "cancelled": true.
static func relax(occupied: Dictionary, cells: Array, passes := 1, radius := KERNEL_RADIUS, remove_threshold := REMOVE_THRESHOLD, add_threshold := ADD_THRESHOLD, weights := {}, credits := {}, cancel := Callable()) -> Dictionary:
	var current := occupied.duplicate()
	var ordered := cells.duplicate()
	ordered.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return a.y < b.y if a.y != b.y else (a.z < b.z if a.z != b.z else a.x < b.x))
	var credit_state := credits.duplicate()
	for _pass in maxi(passes, 0):
		var outcome := weighted_pass(current, ordered, weights, credit_state, radius, remove_threshold, add_threshold, cancel)
		if outcome.has("cancelled"):
			return {"occupied": occupied.duplicate(), "remove": [], "add": [], "credits": credit_state, "cancelled": true}
		for cell: Vector3i in outcome["remove"]:
			current.erase(cell)
		for cell: Vector3i in outcome["add"]:
			current[cell] = true
		if not (outcome["remove"] as Array).is_empty():
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
					return {"occupied": occupied.duplicate(), "remove": [], "add": [], "credits": credit_state, "cancelled": true}
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
	return {"occupied": current, "remove": remove, "add": add, "credits": credit_state}


## Advances the rounding by the elapsed seconds.
##
## [param rate] is the pass count per second. [param carry] is the fractional
## pass left from the previous call. [param weights] and [param credits] are the
## per-cell rate weight and the persistent fractional credit. The result holds
## "occupied", "remove", "add", "carry", "passes", and "credits".
##
## The pass count is an integer, so a split of one elapsed time gives the same
## passes as a single call. The carry keeps the fraction, so no time is lost and
## the sub-voxel progress is never reset. The carry limits the work of one call
## to [constant MAX_PASSES_PER_CALL] passes. The leftover stays in the carry. The
## credits carry the per-cell rate across calls, so a split gives the same
## credits as a single call.
##
## A call with no candidate cell keeps the carry and runs no pass. Time over
## empty geometry then never banks a burst for later.
static func advance(occupied: Dictionary, cells: Array, seconds: float, rate: float, carry := 0.0, radius := KERNEL_RADIUS, remove_threshold := REMOVE_THRESHOLD, add_threshold := ADD_THRESHOLD, weights := {}, credits := {}, cancel := Callable()) -> Dictionary:
	if cells.is_empty():
		return {"occupied": occupied.duplicate(), "remove": [], "add": [], "carry": maxf(carry, 0.0), "passes": 0, "credits": credits.duplicate()}
	var total := maxf(carry, 0.0) + maxf(seconds, 0.0) * maxf(rate, 0.0)
	var passes := mini(floori(total + PASS_EPSILON), MAX_PASSES_PER_CALL)
	var outcome := relax(occupied, cells, passes, radius, remove_threshold, add_threshold, weights, credits, cancel)
	outcome["carry"] = maxf(0.0, total - float(passes))
	outcome["passes"] = passes
	return outcome
