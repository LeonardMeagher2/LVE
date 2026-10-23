extends RefCounted

## Pure helpers for one voxel brush size.
##
## A brush size is a voxel width in cells. The size runs from 1 through 64. A
## size of 1 is one voxel. An odd size centers on one cell. An even size centers
## between cells, so its offsets start half a cell below zero.
##
## Use this script for consistent brush-like size controls. The brush stamp,
## paint stamp, spray spot, and spray search area use these helpers.
## Sculpt size controls are not connected yet. The sphere mask matches the
## shipped brush sphere, so an even size keeps the brush alignment.
##
## The script names no project script. A caller preloads it and keeps its own
## caches. The helper holds no state and no cache, so no size read waits on
## another size build and no two callers share a mutable array.
##
## A symmetric footprint must reflect every footprint cell, not the anchor
## alone. Use `context.reflect(anchor + offset, mask)` for each offset. Do not
## use `context.reflect(anchor, mask) + offset`. An even size centers between
## cells, so it is not symmetric under offset negation. The two forms then place
## a different shape, and the second form is off by one cell on the mirrored
## side. An odd size is symmetric, so the two forms agree.

## The smallest brush size in cells.
const MIN_SIZE := 1
## The largest brush size in cells.
const MAX_SIZE := 64


## Returns the size clamped to the valid range.
static func clamp_size(size: int) -> int:
	return clampi(size, MIN_SIZE, MAX_SIZE)


## Returns the lowest footprint offset on each axis.
##
## An odd size reaches the same distance on both sides. An even size reaches one
## cell further on the negative side, so it spans the exact even width.
static func first_offset(size: int) -> int:
	return -floori(size * 0.5)


## Returns the highest footprint offset on each axis.
static func last_offset(size: int) -> int:
	return first_offset(size) + size - 1


## Returns the cell-space center of the footprint. A size of 1 centers on cell 0.
static func center(size: int) -> float:
	return (size - 1) * 0.5


## Returns the footprint-space center.
##
## An odd size centers on the origin. An even size centers half a cell below the
## origin on each axis, so an even shape is not symmetric under offset negation.
static func center_offset(size: int) -> float:
	return first_offset(size) + center(size)


## Returns the sphere radius of the size, in cells.
static func radius(size: int) -> float:
	return size * 0.5


## Returns the squared sphere radius of the size. It is the sphere threshold.
static func radius_squared(size: int) -> float:
	return size * size * 0.25


## Returns true when an offset lies inside the cube footprint of the size.
static func contains_cube(size: int, offset: Vector3i) -> bool:
	var low := first_offset(size)
	var high := last_offset(size)
	return (
		offset.x >= low and offset.x <= high
		and offset.y >= low and offset.y <= high
		and offset.z >= low and offset.z <= high
	)


## Returns true when an offset lies inside the sphere footprint of the size.
##
## The test uses the half-cell center of an even size and the squared radius of
## the size, so the result matches the shipped brush sphere exactly.
static func contains_sphere(size: int, offset: Vector3i) -> bool:
	var c := center_offset(size)
	var relative := Vector3(offset.x - c, offset.y - c, offset.z - c)
	return relative.length_squared() <= radius_squared(size)


## Returns true when an offset lies inside the footprint of the shape. A true
## [param sphere] selects the sphere footprint, and a false value the cube.
static func contains(size: int, offset: Vector3i, sphere: bool) -> bool:
	return contains_sphere(size, offset) if sphere else contains_cube(size, offset)


## Returns the sphere footprint offsets.
##
## The offsets come in ascending x, then y, then z order. The order matches the
## shipped brush stamp, so the two agree on every key. Every call returns a fresh
## array, so a caller owns its copy and never changes another caller's result.
static func sphere_offsets(size: int) -> Array[Vector3i]:
	var offsets: Array[Vector3i] = []
	var low := first_offset(size)
	var high := last_offset(size)
	var c := center_offset(size)
	var limit := radius_squared(size)
	for x in range(low, high + 1):
		for y in range(low, high + 1):
			for z in range(low, high + 1):
				var relative := Vector3(x - c, y - c, z - c)
				if relative.length_squared() <= limit:
					offsets.append(Vector3i(x, y, z))
	return offsets


## Returns the smallest integer ball radius that holds every sphere offset.
##
## A gather around one footprint uses it, so the gather never misses a sphere
## cell. The result is exact: it is the longest rounded offset length. The
## calculation is cheap and holds no large cache, so a caller can call it on the
## main thread without a stall.
static func reach(size: int) -> int:
	var low := first_offset(size)
	var high := last_offset(size)
	var c := center_offset(size)
	var limit := radius_squared(size)
	var longest := 0
	for x in range(low, high + 1):
		var dx := float(x) - c
		var rest_x := limit - dx * dx
		if rest_x < 0.0:
			continue
		for y in range(low, high + 1):
			var dy := float(y) - c
			var rest_y := rest_x - dy * dy
			if rest_y < 0.0:
				continue
			# The allowed z range is one interval, so the longest z sits at one
			# end of that interval.
			var span := sqrt(rest_y)
			var z_high := mini(high, floori(c + span))
			var z_low := maxi(low, ceili(c - span))
			if z_low > z_high:
				continue
			var z := maxi(absi(z_low), absi(z_high))
			longest = maxi(longest, x * x + y * y + z * z)
	return ceili(sqrt(float(longest)))


## Returns true when an in-plane offset lies inside the disk that the sphere of
## the size projects onto a plane.
##
## The disk uses the same half-cell center and the same squared radius as the
## sphere. A size of 64 therefore spans 64 cells and never 65.
static func disk_contains(size: int, u: int, v: int) -> bool:
	var c := center_offset(size)
	var du := float(u) - c
	var dv := float(v) - c
	return du * du + dv * dv <= radius_squared(size)


## Returns the integer offsets of the disk of the size.
##
## The offsets come in ascending u, then v order. Every entry holds the in-plane
## offsets "u" and "v" and the "distance" from the disk center. Every call
## returns fresh entries, so a caller owns its copy.
static func disk_offsets(size: int) -> Array:
	var offsets := []
	var low := first_offset(size)
	var high := last_offset(size)
	var c := center_offset(size)
	var limit := radius_squared(size)
	for u in range(low, high + 1):
		var du := float(u) - c
		for v in range(low, high + 1):
			var dv := float(v) - c
			var distance_squared := du * du + dv * dv
			if distance_squared > limit:
				continue
			offsets.append({"u": u, "v": v, "distance": sqrt(distance_squared)})
	return offsets


## Returns the size that spans the same width as an old radius of [param radius]
## cells. The old radius r spanned 2r + 1 cells, so it maps to the size 2r + 1.
## Use it to convert legacy integer radii while preserving their physical width.
static func radius_to_size(radius: int) -> int:
	return maxi(MIN_SIZE, 2 * radius + 1)


## Returns the legacy integer radius. It reverses [method radius_to_size] for
## odd sizes. Even sizes round down because a legacy radius has an odd width.
## This is not the sphere radius returned by [method radius].
static func size_to_radius(size: int) -> int:
	return (size - 1) / 2
