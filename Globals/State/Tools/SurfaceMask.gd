extends RefCounted


const NEIGHBORS := [
	Vector3i.LEFT,
	Vector3i.RIGHT,
	Vector3i.UP,
	Vector3i.DOWN,
	Vector3i.FORWARD,
	Vector3i.BACK,
]


static func is_exposed(frame, cell: Vector3i) -> bool:
	if not frame.has(cell):
		return false
	for neighbor: Vector3i in NEIGHBORS:
		if not frame.has(cell + neighbor):
			return true
	return false
