class_name PixelPerfectStroke
extends RefCounted

# A pixel-perfect stroke filter. It keeps one waiting cell that always
# neighbors the last drawn cell. When the cursor pulls more than one cell
# away from the last drawn cell, it draws the connected path from the waiting
# cell to the cursor. This keeps the stroke connected, paints the current
# cursor cell, and skips the transient cells the cursor passes over.

var _last_drawn := State.NONE
var _waiting := State.NONE


func reset() -> void:
	_last_drawn = State.NONE
	_waiting = State.NONE


func feed(p: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if _last_drawn == State.NONE:
		_last_drawn = p
		_waiting = p
		return out
	if p == _waiting or p == _last_drawn:
		return out
	if _neighbor(_last_drawn, p):
		_waiting = p
		return out
	for c in StrokeLine.cells(_waiting, p):
		out.append(c)
	_last_drawn = p
	_waiting = p
	return out


func flush() -> Array[Vector3i]:
	if _waiting == State.NONE or _waiting == _last_drawn:
		return []
	var out: Array[Vector3i] = [_waiting]
	_last_drawn = _waiting
	_waiting = State.NONE
	return out


func _neighbor(a: Vector3i, b: Vector3i) -> bool:
	return maxi(absi(a.x - b.x), maxi(absi(a.y - b.y), absi(a.z - b.z))) <= 1
