class_name PixelPerfectStroke
extends RefCounted

## Filters a stroke to a connected path with no skipped cells.
##
## The filter keeps one waiting cell that always neighbors the last drawn cell.
## It draws the connected path only when the cursor moves away.

# A pixel-perfect stroke filter. It keeps one waiting cell that always
# neighbors the last drawn cell. When the cursor pulls more than one cell
# away from the last drawn cell, it draws the connected path from the waiting
# cell to the cursor. This keeps the stroke connected, paints the current
# cursor cell, and skips the transient cells the cursor passes over.

var _last_drawn := VoxelPicking.NONE
var _waiting := VoxelPicking.NONE


## Clears the filter for a new stroke.
func reset() -> void:
	_last_drawn = VoxelPicking.NONE
	_waiting = VoxelPicking.NONE


## Feeds one cursor cell to the filter. Returns the cells to draw now. The
## filter holds the cell while the cursor stays close.
func feed(p: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if _last_drawn == VoxelPicking.NONE:
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


## Returns the last waiting cell on stroke release. Returns an empty array when
## no cell waits.
func flush() -> Array[Vector3i]:
	if _waiting == VoxelPicking.NONE or _waiting == _last_drawn:
		return []
	var out: Array[Vector3i] = [_waiting]
	_last_drawn = _waiting
	_waiting = VoxelPicking.NONE
	return out


func _neighbor(a: Vector3i, b: Vector3i) -> bool:
	return maxi(absi(a.x - b.x), maxi(absi(a.y - b.y), absi(a.z - b.z))) <= 1
