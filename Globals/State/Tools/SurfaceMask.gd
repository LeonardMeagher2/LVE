extends RefCounted

## The six-neighbor exposure rule for the paint tools.
##
## A cell is exposed when the frame holds it and one face neighbor is empty.
## The spray and the dither brush use the same rule. This script names no
## project script and holds no state.

const NEIGHBORS := [
	Vector3i.LEFT,
	Vector3i.RIGHT,
	Vector3i.UP,
	Vector3i.DOWN,
	Vector3i.FORWARD,
	Vector3i.BACK,
]


## Returns [code]true[/code] when the frame holds the cell and one face
## neighbor is empty.
static func is_exposed(frame, cell: Vector3i) -> bool:
	if not frame.has(cell):
		return false
	for neighbor: Vector3i in NEIGHBORS:
		if not frame.has(cell + neighbor):
			return true
	return false
