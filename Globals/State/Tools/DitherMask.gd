extends RefCounted

## The 3D ordered dither mask for the dither painting brush.
##
## The mask orders cells with a 4 by 4 by 4 Bayer table. The density is a
## fraction from 0 through 1 of the visible surface cells in the brush
## footprint. The lowest Bayer thresholds win. The pattern starts at the origin
## cell of the stroke, so a new stroke starts a fresh tile.
##
## The mask reads world cell coordinates relative to the origin. The exposure
## rule comes from [SurfaceMask]. This script holds no state.

# The pure six-neighbor exposure rule. The helper names no project script.
const SurfaceMask := preload("res://Globals/State/Tools/SurfaceMask.gd")
# The 2 by 2 by 2 Bayer order. Index = x + 2 * y + 4 * z.
const BAYER_2 := [
	0, 4, 6, 2,
	5, 1, 3, 7,
]


## Returns the Bayer threshold of one cell relative to the stroke origin. The
## result runs from 0 through 63.
static func threshold(cell: Vector3i, origin: Vector3i) -> int:
	var x := (cell.x - origin.x) & 3
	var y := (cell.y - origin.y) & 3
	var z := (cell.z - origin.z) & 3
	var low := (x & 1) | ((y & 1) << 1) | ((z & 1) << 2)
	var high := ((x >> 1) & 1) | (((y >> 1) & 1) << 1) | (((z >> 1) & 1) << 2)
	return (BAYER_2[low] << 3) + BAYER_2[high]


## Returns the offsets of the visible surface cells that the density keeps
## around one center. The caller supplies the frame and the stroke origin.
static func select_offsets(offsets: Array, center: Vector3i, density: float, frame, origin: Vector3i) -> Array:
	if frame == null or offsets.is_empty():
		return []
	var candidates := []
	for cell_offset: Vector3i in offsets:
		var cell := center + cell_offset
		if not SurfaceMask.is_exposed(frame, cell):
			continue
		candidates.append([threshold(cell, origin), cell_offset])
	if candidates.is_empty():
		return []
	var keep := clampi(roundi(clampf(density, 0.0, 1.0) * candidates.size()), 0, candidates.size())
	if keep == 0:
		return []
	if keep == candidates.size():
		var all: Array = []
		for candidate in candidates:
			all.append(candidate[1])
		return all
	candidates.sort_custom(func(first: Array, second: Array) -> bool:
		if first[0] != second[0]:
			return first[0] < second[0]
		var first_offset: Vector3i = first[1]
		var second_offset: Vector3i = second[1]
		if first_offset.x != second_offset.x:
			return first_offset.x < second_offset.x
		if first_offset.y != second_offset.y:
			return first_offset.y < second_offset.y
		return first_offset.z < second_offset.z
	)
	var selected: Array = []
	for index in keep:
		selected.append(candidates[index][1])
	return selected


## Returns the pattern values for the visible surface cells that the density
## keeps around one center.
static func filter_pattern(pattern: Dictionary, center: Vector3i, density: float, frame, origin: Vector3i) -> Dictionary:
	var kept := {}
	var selected := select_offsets(pattern.keys(), center, density, frame, origin)
	for cell_offset: Vector3i in selected:
		kept[cell_offset] = pattern[cell_offset]
	return kept
