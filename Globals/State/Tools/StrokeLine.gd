class_name StrokeLine
extends RefCounted

## Builds a connected cell path between two cells.
##
## The path follows the straight line between the endpoints. The eager form and
## the lazy cursor share one definition, so a tool that must not allocate the
## whole path yields exactly the cells the eager form returns.

## A lazy cursor over the path from [param a] to [param b].
##
## The cursor yields the cells one at a time, so a long segment never builds a
## full path array. It holds only the current cell, the step, the error terms,
## and the remaining step count.
class Cursor extends RefCounted:
	var _cell := Vector3i.ZERO
	var _step := Vector3i.ZERO
	var _span := Vector3i.ZERO
	var _remaining := 0
	var _dominant := 0
	var _error := [0.0, 0.0, 0.0]

	func _init(a: Vector3i, b: Vector3i) -> void:
		_cell = a
		var delta := b - a
		_span = Vector3i(absi(delta.x), absi(delta.y), absi(delta.z))
		_step = Vector3i(StrokeLine._signi(delta.x), StrokeLine._signi(delta.y), StrokeLine._signi(delta.z))
		_dominant = StrokeLine._dominant(_span)
		_remaining = _span[_dominant]

	## Returns the cell the cursor currently holds.
	func origin() -> Vector3i:
		return _cell

	## Returns the number of crossed cells that remain.
	func remaining() -> int:
		return _remaining

	## Returns the completed fraction of the segment, from zero to one.
	func progress() -> float:
		if _span[_dominant] <= 0:
			return 1.0
		return 1.0 - float(_remaining) / float(_span[_dominant])

	## Advances one cell past the start and returns it, or null at the end.
	func next_cell() -> Variant:
		if _remaining <= 0:
			return null
		_cell[_dominant] += _step[_dominant]
		for axis in 3:
			if axis == _dominant or _span[axis] == 0:
				continue
			_error[axis] += float(_span[axis]) / float(_span[_dominant])
			if _error[axis] >= 0.5:
				_cell[axis] += _step[axis]
				_error[axis] -= 1.0
		_remaining -= 1
		return _cell


## Returns the connected path of cells from [param a] to [param b], inclusive.
## The path steps the longest axis at each step, so consecutive cells touch.
static func cells(a: Vector3i, b: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var cursor := Cursor.new(a, b)
	out.append(cursor.origin())
	var cell: Variant = cursor.next_cell()
	while cell != null:
		out.append(cell)
		cell = cursor.next_cell()
	return out


static func _dominant(ad: Vector3i) -> int:
	if ad.y >= ad.x and ad.y >= ad.z:
		return 1
	if ad.z >= ad.x:
		return 2
	return 0


static func _signi(v: int) -> int:
	return -1 if v < 0 else (1 if v > 0 else 0)
