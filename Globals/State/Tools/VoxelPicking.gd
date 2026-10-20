class_name VoxelPicking
extends RefCounted

## Converts a pointer ray into a voxel cell.
##
## The class holds no state. A tool calls a static function with a ray and a
## frame, and reads the result from a [PickResult].

## The cell sentinel for a missing cell. It holds [constant Vector3.INF] in
## each axis, so no real cell matches it.
const NONE:Vector3i = Vector3i(Vector3.INF)

## Returns the press pick for a ray. A ray that hits the model targets the hit
## cell. A ray that misses targets the floor plane.
static func start_pick(origin: Vector3, dir: Vector3, frame: VoxelFrame, forward: Vector3) -> PickResult:
	var res := ray_voxel(origin, dir, frame)
	if res.hit != VoxelPicking.NONE:
		res.target = res.hit
		res.add_target = res.hit + res.entry
		res.plane = view_plane(res.target, origin, forward)
		return res
	return ground_pick(origin, dir, forward)


## Returns the drag pick for a ray on a plane. A ray parallel to the plane or
## behind the camera returns an empty result.
static func drag_pick(origin: Vector3, dir: Vector3, frame: VoxelFrame, plane: StrokePlane) -> PickResult:
	var denom := dir.dot(plane.normal)
	if absf(denom) < 1e-8:
		return PickResult.new()
	var t: float = (plane.point - origin).dot(plane.normal) / denom
	if t <= 0.0:
		return PickResult.new()
	var gp: Vector3 = origin + dir * t
	var c := Vector3i(int(floori(gp.x + 0.5)), int(floori(gp.y + 0.5)), int(floori(gp.z + 0.5)))
	c[plane.axis] = plane.idx
	var res := PickResult.new()
	res.target = c
	res.hit = c if frame != null and frame.has(c) else VoxelPicking.NONE
	return res


## Returns the world axis that faces the viewer most directly. Axis 0 is X,
## axis 1 is Y, and axis 2 is Z.
static func view_axis(forward: Vector3) -> int:
	# The axis that faces the viewer. The press plane of a pick uses it.
	var toward: Vector3 = -forward
	var x := absf(toward.x)
	var y := absf(toward.y)
	var z := absf(toward.z)
	if y >= x and y >= z:
		return 1
	if z >= x:
		return 2
	return 0


## Returns a plane through the target cell that faces the viewer. The plane
## sits on the side of the cell toward the ray origin.
static func view_plane(target: Vector3i, origin: Vector3, forward: Vector3) -> StrokePlane:
	var axis := view_axis(forward)
	var side := 1.0 if origin[axis] >= float(target[axis]) else -1.0
	var p := StrokePlane.new()
	p.axis = axis
	p.idx = target[axis]
	var pt := Vector3.ZERO
	pt[axis] += float(target[axis]) + 0.5 * side
	p.point = pt
	var n := Vector3.ZERO
	n[axis] = 1.0
	p.normal = n
	return p


## Returns a viewer-facing plane through a point. A drag maps onto this plane.
static func view_plane_through(point: Vector3, forward: Vector3) -> StrokePlane:
	# A plane through the point that faces the viewer. Drags map onto it.
	var p := StrokePlane.new()
	p.axis = view_axis(forward)
	p.idx = 0
	p.point = point
	var n := Vector3.ZERO
	n[p.axis] = 1.0
	p.normal = n
	return p


## Returns the first occupied cell along a ray. It uses the DDA method. The
## traversal clips to the supplied bounds, or to the frame bounds when they are
## not given. The bounds extent sets the step count, so a far ray needs no
## distance or iteration cap.
static func ray_voxel(origin: Vector3, dir: Vector3, frame: VoxelFrame, supplied_bounds := AABB()) -> PickResult:
	var res := PickResult.new()
	if frame == null:
		return res
	if dir == Vector3.ZERO:
		return res
	var bounds := supplied_bounds
	if not bounds.has_volume():
		bounds = frame.get_bounds()
	if not bounds.has_volume():
		return res
	# Work in cell space. Cell c spans [c, c + 1) after the +0.5 shift, which is
	# the world span [c - 0.5, c + 0.5].
	var g := origin + Vector3(0.5, 0.5, 0.5)
	var lo := bounds.position + Vector3(0.5, 0.5, 0.5)
	var hi := bounds.end + Vector3(0.5, 0.5, 0.5)
	# Slab clip the ray against the bounds. Both ends use the original origin, so
	# they share one parameter with the DDA below.
	var t_enter := -INF
	var t_exit := INF
	for axis in 3:
		var d: float = dir[axis]
		if d == 0.0:
			if g[axis] < lo[axis] or g[axis] > hi[axis]:
				return res
			continue
		var near: float = (lo[axis] - g[axis]) / d
		var far: float = (hi[axis] - g[axis]) / d
		if near > far:
			var swap := near
			near = far
			far = swap
		t_enter = maxf(t_enter, near)
		t_exit = minf(t_exit, far)
	if t_enter > t_exit or t_exit <= 0.0:
		return res
	var step := Vector3i(
		1 if dir.x > 0.0 else -1, 1 if dir.y > 0.0 else -1, 1 if dir.z > 0.0 else -1
	)
	var cell_min := Vector3i(floori(lo.x), floori(lo.y), floori(lo.z))
	var cell_max := Vector3i(floori(hi.x) - 1, floori(hi.y) - 1, floori(hi.z) - 1)
	# Start inside the bounds. An origin outside them starts at the entry cell,
	# which records the face the ray crosses so the first hit keeps its entry.
	var t := 0.0
	var entry := Vector3i.ZERO
	var cell := Vector3i(floori(g.x), floori(g.y), floori(g.z))
	if t_enter > 0.0:
		t = t_enter
		cell = _entry_cell(g + dir * t_enter, dir)
		cell = Vector3i(
			clampi(cell.x, cell_min.x, cell_max.x),
			clampi(cell.y, cell_min.y, cell_max.y),
			clampi(cell.z, cell_min.z, cell_max.z)
		)
		entry = _entry_face(g, dir, lo, hi, step)
	var t_max := Vector3(INF, INF, INF)
	var t_delta := Vector3(INF, INF, INF)
	if dir.x != 0.0:
		t_delta.x = absf(1.0 / dir.x)
		t_max.x = ((float(cell.x) + (1.0 if step.x > 0 else 0.0)) - g.x) / dir.x
	if dir.y != 0.0:
		t_delta.y = absf(1.0 / dir.y)
		t_max.y = ((float(cell.y) + (1.0 if step.y > 0 else 0.0)) - g.y) / dir.y
	if dir.z != 0.0:
		t_delta.z = absf(1.0 / dir.z)
		t_max.z = ((float(cell.z) + (1.0 if step.z > 0 else 0.0)) - g.z) / dir.z
	# The ray crosses at most one boundary per bounds cell on each axis, so the
	# extent bounds the step count without any assumption about the direction.
	var extent := cell_max - cell_min + Vector3i.ONE
	var max_steps := extent.x + extent.y + extent.z + 2
	for i in max_steps:
		if frame.has(cell):
			res.hit = cell
			res.entry = entry
			return res
		if t_max.x < t_max.y and t_max.x < t_max.z:
			cell.x += step.x
			entry = Vector3i(-step.x, 0, 0)
			t = t_max.x
			t_max.x += t_delta.x
		elif t_max.y < t_max.z:
			cell.y += step.y
			entry = Vector3i(0, -step.y, 0)
			t = t_max.y
			t_max.y += t_delta.y
		else:
			cell.z += step.z
			entry = Vector3i(0, 0, -step.z)
			t = t_max.z
			t_max.z += t_delta.z
		if t > t_exit:
			break
	return res


# The cell that holds the ray just after it enters the bounds. A negative axis
# picks the cell below the point, so an entry on a max bounds face stays inside.
static func _entry_cell(point: Vector3, dir: Vector3) -> Vector3i:
	var cell := Vector3i.ZERO
	for axis in 3:
		cell[axis] = ceili(point[axis]) - 1 if dir[axis] < 0.0 else floori(point[axis])
	return cell


# The bounds face the ray enters through, as the entry vector of the entry cell.
# A tie keeps the first axis, which matches the DDA step order.
static func _entry_face(g: Vector3, dir: Vector3, lo: Vector3, hi: Vector3, step: Vector3i) -> Vector3i:
	var axis := -1
	var nearest := -INF
	for a in 3:
		var d: float = dir[a]
		if d == 0.0:
			continue
		var near: float = (lo[a] - g[a]) / d if d > 0.0 else (hi[a] - g[a]) / d
		if near > nearest:
			nearest = near
			axis = a
	var entry := Vector3i.ZERO
	if axis >= 0:
		entry[axis] = -step[axis]
	return entry


## Returns a pick on the floor plane of the current document. The floor plane
## is set by [member State.floor_axis] and [member State.floor_index].
static func ground_pick(origin: Vector3, dir: Vector3, forward: Vector3) -> PickResult:
	var axis := State.floor_axis
	var denom := dir[axis]
	if absf(denom) < 1e-8:
		return PickResult.new()
	var level := float(State.floor_index) - 0.5
	var t: float = (level - origin[axis]) / denom
	if t <= 0.0:
		return PickResult.new()
	var p: Vector3 = origin + dir * t
	var c := Vector3i.ZERO
	for i in 3:
		if i != axis:
			c[i] = int(floori(p[i] + 0.5))
	if origin[axis] >= level:
		c[axis] = State.floor_index
	else:
		c[axis] = State.floor_index - 1
	var res := PickResult.new()
	res.target = c
	res.add_target = c
	res.plane = view_plane(c, origin, forward)
	return res
