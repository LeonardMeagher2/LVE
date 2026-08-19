class_name VoxelPicking
extends RefCounted


static func start_pick(origin: Vector3, dir: Vector3, cells: Dictionary) -> PickResult:
	var res := ray_voxel(origin, dir, cells)
	if res.hit != State.NONE:
		res.target = res.hit
		res.add_target = res.hit + res.entry
		res.plane = view_plane(res.target, origin, dir)
		return res
	return ground_pick(origin, dir)


static func drag_pick(origin: Vector3, dir: Vector3, cells: Dictionary, plane: StrokePlane) -> PickResult:
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
	res.hit = c if cells.has(c) else State.NONE
	return res


static func view_plane(target: Vector3i, origin: Vector3, dir: Vector3) -> StrokePlane:
	var f: Vector3 = -dir
	var axis := 0
	if absf(f.y) >= absf(f.x) and absf(f.y) >= absf(f.z):
		axis = 1
	elif absf(f.z) >= absf(f.x):
		axis = 2
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


static func ray_voxel(origin: Vector3, dir: Vector3, cells: Dictionary) -> PickResult:
	var g := origin + Vector3(0.5, 0.5, 0.5)
	var res := PickResult.new()
	var cell := Vector3i(floori(g.x), floori(g.y), floori(g.z))
	var step := Vector3i(
		1 if dir.x > 0 else -1, 1 if dir.y > 0 else -1, 1 if dir.z > 0 else -1
	)
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
	var t := 0.0
	var entry := Vector3i.ZERO
	for i in 1024:
		if cells.has(cell):
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
		if t > 512.0:
			break
	return res


static func ground_pick(origin: Vector3, dir: Vector3) -> PickResult:
	if dir.y >= -1e-8:
		return PickResult.new()
	var t: float = (-0.5 - origin.y) / dir.y
	if t <= 0.0:
		return PickResult.new()
	var p: Vector3 = origin + dir * t
	var c := Vector3i(int(floori(p.x + 0.5)), 0, int(floori(p.z + 0.5)))
	var res := PickResult.new()
	res.target = c
	res.add_target = c
	res.plane = view_plane(c, origin, dir)
	return res
