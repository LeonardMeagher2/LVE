class_name StrokeLine
extends RefCounted

## Builds a connected cell path between two cells.
##
## The path follows the straight line between the endpoints.

# Returns the connected 8-neighbor path of cells from a to b inclusive.
# The path follows the straight line, stepping the longest axis each step.

## Returns the connected path of cells from [param a] to [param b], inclusive.
## The path steps the longest axis at each step, so consecutive cells touch.
static func cells(a: Vector3i, b: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var p := a
	out.append(p)
	var d := b - a
	var ad := Vector3i(absi(d.x), absi(d.y), absi(d.z))
	var s := Vector3i(_signi(d.x), _signi(d.y), _signi(d.z))
	var dom := _dominant(ad)
	var n := ad[dom]
	if n == 0:
		return out
	var e := [0.0, 0.0, 0.0]
	for i in n:
		p[dom] += s[dom]
		for j in 3:
			if j == dom or ad[j] == 0:
				continue
			e[j] += float(ad[j]) / n
			if e[j] >= 0.5:
				p[j] += s[j]
				e[j] -= 1.0
		out.append(p)
	return out


static func _dominant(ad: Vector3i) -> int:
	if ad.y >= ad.x and ad.y >= ad.z:
		return 1
	if ad.z >= ad.x:
		return 2
	return 0


static func _signi(v: int) -> int:
	return -1 if v < 0 else (1 if v > 0 else 0)
