extends RefCounted


const NEIGHBOR_OFFSETS := [
	Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
	Vector3i(0, -1, 0), Vector3i(0, 1, 0),
	Vector3i(0, 0, -1), Vector3i(0, 0, 1),
]

const KERNEL_RADIUS := 1

const BROAD_RADIUS := 2

const THIN_MULTIPLIER := 3

const MAX_ROUNDING_RADIUS := 4

const REMOVE_THRESHOLD := 0.5
const ADD_THRESHOLD := 0.5

const MAX_PASSES_PER_CALL := 8

const CHECKPOINT_INTERVAL := 512

const GRID_LIMIT_BYTES := 1 << 26

static var _kernel_cache := {}
static var _ball_cache := {}
static var _read_cache := {}
static var _cache_lock := Mutex.new()


static func surface_normal(occupied: Dictionary, cell: Vector3i) -> Variant:
	var gradient := Vector3i.ZERO
	for offset: Vector3i in NEIGHBOR_OFFSETS:
		if occupied.has(cell + offset):
			gradient += offset
	if gradient == Vector3i.ZERO:
		return null
	return -Vector3(gradient).normalized()


static func _has_face_neighbor(occupied: Dictionary, cell: Vector3i) -> bool:
	for offset: Vector3i in NEIGHBOR_OFFSETS:
		if occupied.has(cell + offset):
			return true
	return false


static func occupied_fraction(occupied: Dictionary, cell: Vector3i, radius := KERNEL_RADIUS) -> float:
	var offsets: Array = kernel_offsets(radius)
	var count := 0
	for offset: Vector3i in offsets:
		if occupied.has(cell + offset):
			count += 1
	return float(count) / float(offsets.size())


static func kernel_offsets(radius: int) -> Array:
	var use_radius := maxi(radius, 1)
	_cache_lock.lock()
	if _kernel_cache.has(use_radius):
		var cached: Array = _kernel_cache[use_radius]
		_cache_lock.unlock()
		return cached
	var offsets: Array = []
	for x in range(-use_radius, use_radius + 1):
		for y in range(-use_radius, use_radius + 1):
			for z in range(-use_radius, use_radius + 1):
				offsets.append(Vector3i(x, y, z))
	offsets.make_read_only()
	_kernel_cache[use_radius] = offsets
	_cache_lock.unlock()
	return offsets


static func ball_offsets(radius: int) -> Array:
	var use_radius := clampi(radius, 1, 2 * MAX_ROUNDING_RADIUS)
	_cache_lock.lock()
	if not _ball_cache.has(use_radius):
		var offsets: Array = []
		var squared := use_radius * use_radius
		for x in range(-use_radius, use_radius + 1):
			for y in range(-use_radius, use_radius + 1):
				for z in range(-use_radius, use_radius + 1):
					var point := Vector3i(x, y, z)
					if point.length_squared() <= squared:
						offsets.append(point)
		offsets.sort_custom(_order_offsets)
		_ball_cache[use_radius] = offsets
	var cached: Array = _ball_cache[use_radius]
	_cache_lock.unlock()
	return cached.duplicate()


static func required_halo(radius: int) -> int:
	if radius < BROAD_RADIUS:
		return 1
	var use_radius := clampi(radius, 1, MAX_ROUNDING_RADIUS)
	return maxi(2 * use_radius, THIN_MULTIPLIER * use_radius)


static func read_offsets(radius: int) -> Array:
	if radius < BROAD_RADIUS:
		return kernel_offsets(1).duplicate()
	var use_radius := clampi(radius, 1, MAX_ROUNDING_RADIUS)
	var ball := ball_offsets(use_radius * 2)
	_cache_lock.lock()
	if not _read_cache.has(use_radius):
		var seen := {}
		for offset: Vector3i in ball:
			seen[offset] = true
		var reach := THIN_MULTIPLIER * use_radius
		for axis in 3:
			for step in range(1, reach + 1):
				seen[NEIGHBOR_OFFSETS[axis * 2] * step] = true
				seen[NEIGHBOR_OFFSETS[axis * 2 + 1] * step] = true
		var offsets: Array = seen.keys()
		offsets.sort_custom(_order_offsets)
		_read_cache[use_radius] = offsets
	var cached: Array = _read_cache[use_radius]
	_cache_lock.unlock()
	return cached.duplicate()


static func _order_offsets(a: Vector3i, b: Vector3i) -> bool:
	var distance_a := a.length_squared()
	var distance_b := b.length_squared()
	if distance_a != distance_b:
		return distance_a < distance_b
	if a.z != b.z:
		return a.z < b.z
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x


static func weighted_pass(occupied: Dictionary, cells: Array, budget: Dictionary, pass_index: int, radius := KERNEL_RADIUS, remove_threshold := REMOVE_THRESHOLD, add_threshold := ADD_THRESHOLD, cancel := Callable()) -> Dictionary:
	var use_radius := clampi(radius, 1, MAX_ROUNDING_RADIUS)
	var broad := use_radius >= BROAD_RADIUS
	var ball: Array = []
	if broad:
		ball = ball_offsets(use_radius)
	var host_memo := {}
	var touch_memo := {}
	var base_radius := mini(radius, KERNEL_RADIUS)
	var base_count := base_radius * 2 + 1
	var remove_limit := 0
	var add_limit := 0
	if base_count == 3:
		var full_count := base_count * base_count * base_count
		remove_limit = ceili(float(full_count) * remove_threshold)
		add_limit = floori(float(full_count) * add_threshold) + 1
	var remove := []
	var add := []
	var evaluated := []
	var completed := 0
	for cell: Vector3i in cells:
		if pass_index >= int(budget.get(cell, 0)):
			continue
		evaluated.append(cell)
		completed += 1
		if cancel.is_valid() and completed % CHECKPOINT_INTERVAL == 0 and not cancel.call(completed):
			return {"cancelled": true}
		var self_occupied := occupied.has(cell)
		var face_x := occupied.has(cell + NEIGHBOR_OFFSETS[0])
		var back_x := occupied.has(cell + NEIGHBOR_OFFSETS[1])
		var face_y := occupied.has(cell + NEIGHBOR_OFFSETS[2])
		var back_y := occupied.has(cell + NEIGHBOR_OFFSETS[3])
		var face_z := occupied.has(cell + NEIGHBOR_OFFSETS[4])
		var back_z := occupied.has(cell + NEIGHBOR_OFFSETS[5])
		var has_face := face_x or back_x or face_y or back_y or face_z or back_z
		var gradient_x := int(face_x) - int(back_x)
		var gradient_y := int(face_y) - int(back_y)
		var gradient_z := int(face_z) - int(back_z)
		if gradient_x == 0 and gradient_y == 0 and gradient_z == 0:
			if self_occupied and not has_face:
				remove.append(cell)
			continue
		if self_occupied:
			var opposite_empty := (not face_x and not back_x) or (not face_y and not back_y) or (not face_z and not back_z)
			var supported := (face_x and back_x) or (face_y and back_y) or (face_z and back_z)
			if opposite_empty and supported:
				continue
			if broad and not _thin_solid(occupied, cell, use_radius):
				var normal := -Vector3(gradient_x, gradient_y, gradient_z).normalized()
				var inward := Vector3i(int(signf(normal.x)), int(signf(normal.y)), int(signf(normal.z)))
				if not _covered(occupied, host_memo, ball, cell, -inward):
					remove.append(cell)
			elif base_count != 3:
				if occupied_fraction(occupied, cell, base_radius) < remove_threshold:
					remove.append(cell)
			elif _base_occupied(occupied, cell, true, remove_limit) < remove_limit:
				remove.append(cell)
		else:
			if broad and not _thin_around(occupied, cell, use_radius) and _enclosed(occupied, touch_memo, ball, cell):
				add.append(cell)
			elif base_count != 3:
				if occupied_fraction(occupied, cell, base_radius) > add_threshold:
					add.append(cell)
			elif _base_occupied(occupied, cell, false, add_limit) >= add_limit:
				add.append(cell)
	remove.sort()
	add.sort()
	return {"remove": remove, "add": add, "evaluated": evaluated}


static func _covered(occupied: Dictionary, memo: Dictionary, ball: Array, cell: Vector3i, inward: Vector3i) -> bool:
	var direction := Vector3(inward)
	for offset: Vector3i in ball:
		if Vector3(offset).dot(direction) >= 0.0 and _hosts(occupied, memo, ball, cell + offset):
			return true
	for offset: Vector3i in ball:
		if Vector3(offset).dot(direction) < 0.0 and _hosts(occupied, memo, ball, cell + offset):
			return true
	return false


static func _enclosed(occupied: Dictionary, memo: Dictionary, ball: Array, cell: Vector3i) -> bool:
	for index in range(ball.size() - 1, -1, -1):
		if not _touches(occupied, memo, ball, cell + ball[index]):
			return false
	return true


static func _hosts(occupied: Dictionary, memo: Dictionary, ball: Array, cell: Vector3i) -> bool:
	if memo.has(cell):
		return memo[cell]
	var result := true
	for offset: Vector3i in NEIGHBOR_OFFSETS:
		if not occupied.has(cell + offset):
			result = false
			break
	if result:
		for offset: Vector3i in ball:
			if not occupied.has(cell + offset):
				result = false
				break
	memo[cell] = result
	return result


static func _touches(occupied: Dictionary, memo: Dictionary, ball: Array, cell: Vector3i) -> bool:
	if memo.has(cell):
		return memo[cell]
	var result := false
	for offset: Vector3i in ball:
		if occupied.has(cell + offset):
			result = true
			break
	memo[cell] = result
	return result


static func _thin_solid(occupied: Dictionary, cell: Vector3i, radius: int) -> bool:
	var limit := THIN_MULTIPLIER * clampi(radius, 1, MAX_ROUNDING_RADIUS)
	for axis in 3:
		var negative := _run(occupied, cell, NEIGHBOR_OFFSETS[axis * 2], limit)
		if negative >= limit:
			continue
		var positive := _run(occupied, cell, NEIGHBOR_OFFSETS[axis * 2 + 1], limit)
		if positive >= limit:
			continue
		if 1 + negative + positive <= limit:
			return true
	return false


static func _thin_around(occupied: Dictionary, cell: Vector3i, radius: int) -> bool:
	var limit := THIN_MULTIPLIER * clampi(radius, 1, MAX_ROUNDING_RADIUS)
	for axis in 3:
		var negative := _run(occupied, cell, NEIGHBOR_OFFSETS[axis * 2], limit)
		var positive := _run(occupied, cell, NEIGHBOR_OFFSETS[axis * 2 + 1], limit)
		if negative == 0 and positive == 0:
			continue
		if negative >= limit or positive >= limit:
			continue
		if negative + positive <= limit:
			return true
	return false


static func _run(occupied: Dictionary, cell: Vector3i, direction: Vector3i, limit: int) -> int:
	var length := 0
	var point := cell
	while length < limit and occupied.has(point + direction):
		point += direction
		length += 1
	return length


static func _base_occupied(occupied: Dictionary, cell: Vector3i, self_occupied: bool, limit: int) -> int:
	var count := int(self_occupied)
	count += int(occupied.has(cell + NEIGHBOR_OFFSETS[0]))
	count += int(occupied.has(cell + NEIGHBOR_OFFSETS[1]))
	if count >= limit:
		return count
	count += int(occupied.has(cell + NEIGHBOR_OFFSETS[2]))
	count += int(occupied.has(cell + NEIGHBOR_OFFSETS[3]))
	if count >= limit:
		return count
	count += int(occupied.has(cell + NEIGHBOR_OFFSETS[4]))
	count += int(occupied.has(cell + NEIGHBOR_OFFSETS[5]))
	if count >= limit:
		return count
	for x in range(-1, 2):
		for y in range(-1, 2):
			for z in range(-1, 2):
				if (x == 0 and y == 0) or (x == 0 and z == 0) or (y == 0 and z == 0):
					continue
				count += int(occupied.has(cell + Vector3i(x, y, z)))
				if count >= limit:
					return count
	return count


static func _grid_pass(data: PackedByteArray, stride_x: int, stride_y: int, budgets: PackedInt32Array, bases: PackedInt32Array, pass_index: int, radius: int, remove_threshold: float, add_threshold: float, cancel: Callable) -> Dictionary:
	var use_radius := clampi(radius, 1, MAX_ROUNDING_RADIUS)
	var broad := use_radius >= BROAD_RADIUS
	var ball: Array = []
	var ball_deltas := PackedInt32Array()
	var host_deltas := PackedInt32Array()
	var extra_deltas := PackedInt32Array()
	var fraction_deltas := PackedInt32Array()
	var run_deltas := PackedInt32Array([-stride_x, stride_x, -stride_y, stride_y, -1, 1])
	if broad:
		ball = ball_offsets(use_radius)
		ball_deltas.resize(ball.size())
		for index in ball.size():
			var offset: Vector3i = ball[index]
			ball_deltas[index] = offset.x * stride_x + offset.y * stride_y + offset.z
		for offset: Vector3i in NEIGHBOR_OFFSETS:
			host_deltas.append(offset.x * stride_x + offset.y * stride_y + offset.z)
	var base_radius := mini(radius, KERNEL_RADIUS)
	var base_count := base_radius * 2 + 1
	var remove_limit := 0
	var add_limit := 0
	if base_count == 3:
		var full_count := base_count * base_count * base_count
		remove_limit = ceili(float(full_count) * remove_threshold)
		add_limit = floori(float(full_count) * add_threshold) + 1
		for x in range(-1, 2):
			for y in range(-1, 2):
				for z in range(-1, 2):
					if (x == 0 and y == 0) or (x == 0 and z == 0) or (y == 0 and z == 0):
						continue
					extra_deltas.append(x * stride_x + y * stride_y + z)
	else:
		var offsets: Array = kernel_offsets(base_radius)
		for offset: Vector3i in offsets:
			fraction_deltas.append(offset.x * stride_x + offset.y * stride_y + offset.z)
	var host_memo := {}
	var touch_memo := {}
	var remove := PackedInt32Array()
	var add := PackedInt32Array()
	var evaluated := PackedInt32Array()
	var cancel_valid := cancel.is_valid()
	var completed := 0
	for index in budgets.size():
		if pass_index >= budgets[index]:
			continue
		evaluated.append(index)
		completed += 1
		if cancel_valid and completed % CHECKPOINT_INTERVAL == 0 and not cancel.call(completed):
			return {"cancelled": true}
		var base := bases[index]
		var self_occupied := data[base] == 1
		var face_x := data[base - stride_x] == 1
		var back_x := data[base + stride_x] == 1
		var face_y := data[base - stride_y] == 1
		var back_y := data[base + stride_y] == 1
		var face_z := data[base - 1] == 1
		var back_z := data[base + 1] == 1
		var has_face := face_x or back_x or face_y or back_y or face_z or back_z
		var face_count := int(self_occupied) + int(face_x) + int(back_x) + int(face_y) + int(back_y) + int(face_z) + int(back_z)
		var gradient_x := int(face_x) - int(back_x)
		var gradient_y := int(face_y) - int(back_y)
		var gradient_z := int(face_z) - int(back_z)
		if gradient_x == 0 and gradient_y == 0 and gradient_z == 0:
			if self_occupied and not has_face:
				remove.append(index)
			continue
		if self_occupied:
			var opposite_empty := (not face_x and not back_x) or (not face_y and not back_y) or (not face_z and not back_z)
			var supported := (face_x and back_x) or (face_y and back_y) or (face_z and back_z)
			if opposite_empty and supported:
				continue
			if broad and not _grid_thin_solid(data, run_deltas, base, use_radius):
				var normal := -Vector3(gradient_x, gradient_y, gradient_z).normalized()
				var inward := Vector3i(int(signf(normal.x)), int(signf(normal.y)), int(signf(normal.z)))
				if not _grid_covered(data, host_memo, host_deltas, ball, ball_deltas, base, -inward):
					remove.append(index)
			elif base_count != 3:
				if _grid_fraction(data, fraction_deltas, base) < remove_threshold:
					remove.append(index)
			elif _grid_base_occupied(data, base, face_count, remove_limit, extra_deltas) < remove_limit:
				remove.append(index)
		else:
			if broad and not _grid_thin_around(data, run_deltas, base, use_radius) and _grid_enclosed(data, touch_memo, ball_deltas, base):
				add.append(index)
			elif base_count != 3:
				if _grid_fraction(data, fraction_deltas, base) > add_threshold:
					add.append(index)
			elif _grid_base_occupied(data, base, face_count, add_limit, extra_deltas) >= add_limit:
				add.append(index)
	return {"remove": remove, "add": add, "evaluated": evaluated}


static func _grid_covered(data: PackedByteArray, memo: Dictionary, host_deltas: PackedInt32Array, ball: Array, ball_deltas: PackedInt32Array, base: int, inward: Vector3i) -> bool:
	var direction := Vector3(inward)
	for index in ball.size():
		var offset: Vector3i = ball[index]
		if Vector3(offset).dot(direction) >= 0.0 and _grid_hosts(data, memo, host_deltas, ball_deltas, base + ball_deltas[index]):
			return true
	for index in ball.size():
		var offset: Vector3i = ball[index]
		if Vector3(offset).dot(direction) < 0.0 and _grid_hosts(data, memo, host_deltas, ball_deltas, base + ball_deltas[index]):
			return true
	return false


static func _grid_enclosed(data: PackedByteArray, memo: Dictionary, ball_deltas: PackedInt32Array, base: int) -> bool:
	for index in range(ball_deltas.size() - 1, -1, -1):
		if not _grid_touches(data, memo, ball_deltas, base + ball_deltas[index]):
			return false
	return true


static func _grid_hosts(data: PackedByteArray, memo: Dictionary, host_deltas: PackedInt32Array, ball_deltas: PackedInt32Array, key: int) -> bool:
	if memo.has(key):
		return memo[key]
	var result := true
	for delta in host_deltas:
		if data[key + delta] != 1:
			result = false
			break
	if result:
		for delta in ball_deltas:
			if data[key + delta] != 1:
				result = false
				break
	memo[key] = result
	return result


static func _grid_touches(data: PackedByteArray, memo: Dictionary, ball_deltas: PackedInt32Array, key: int) -> bool:
	if memo.has(key):
		return memo[key]
	var result := false
	for delta in ball_deltas:
		if data[key + delta] == 1:
			result = true
			break
	memo[key] = result
	return result


static func _grid_thin_solid(data: PackedByteArray, run_deltas: PackedInt32Array, base: int, radius: int) -> bool:
	var limit := THIN_MULTIPLIER * clampi(radius, 1, MAX_ROUNDING_RADIUS)
	for axis in 3:
		var negative := _grid_run(data, base, run_deltas[axis * 2], limit)
		if negative >= limit:
			continue
		var positive := _grid_run(data, base, run_deltas[axis * 2 + 1], limit)
		if positive >= limit:
			continue
		if 1 + negative + positive <= limit:
			return true
	return false


static func _grid_thin_around(data: PackedByteArray, run_deltas: PackedInt32Array, base: int, radius: int) -> bool:
	var limit := THIN_MULTIPLIER * clampi(radius, 1, MAX_ROUNDING_RADIUS)
	for axis in 3:
		var negative := _grid_run(data, base, run_deltas[axis * 2], limit)
		var positive := _grid_run(data, base, run_deltas[axis * 2 + 1], limit)
		if negative == 0 and positive == 0:
			continue
		if negative >= limit or positive >= limit:
			continue
		if negative + positive <= limit:
			return true
	return false


static func _grid_run(data: PackedByteArray, base: int, step: int, limit: int) -> int:
	var length := 0
	var point := base
	while length < limit and data[point + step] == 1:
		point += step
		length += 1
	return length


static func _grid_base_occupied(data: PackedByteArray, base: int, count: int, limit: int, extra_deltas: PackedInt32Array) -> int:
	if count >= limit:
		return count
	for delta in extra_deltas:
		count += int(data[base + delta] == 1)
		if count >= limit:
			return count
	return count


static func _grid_fraction(data: PackedByteArray, deltas: PackedInt32Array, base: int) -> float:
	var count := 0
	for delta in deltas:
		if data[base + delta] == 1:
			count += 1
	return float(count) / float(deltas.size())


static func _relax_grid(occupied: Dictionary, ordered: Array, budgets: PackedInt32Array, bases: PackedInt32Array, use_passes: int, radius: int, remove_threshold: float, add_threshold: float, cancel: Callable, data: PackedByteArray, initial: PackedByteArray, stride_x: int, stride_y: int) -> Dictionary:
	var cancel_valid := cancel.is_valid()
	for pass_index in use_passes:
		var outcome := _grid_pass(data, stride_x, stride_y, budgets, bases, pass_index, radius, remove_threshold, add_threshold, cancel)
		if outcome.has("cancelled"):
			return {"occupied": occupied.duplicate(), "remove": [], "add": [], "cancelled": true}
		var removed: PackedInt32Array = outcome["remove"]
		var added: PackedInt32Array = outcome["add"]
		for index in removed:
			data[bases[index]] = 0
		for index in added:
			data[bases[index]] = 1
		if not removed.is_empty() or not added.is_empty():
			var evaluated: PackedInt32Array = outcome["evaluated"]
			var completed := 0
			for index in evaluated:
				var base := bases[index]
				if data[base] == 1 and not _grid_face_neighbor(data, base, stride_x, stride_y):
					data[base] = 0
				completed += 1
				if cancel_valid and completed % CHECKPOINT_INTERVAL == 0 and not cancel.call(completed):
					return {"occupied": occupied.duplicate(), "remove": [], "add": [], "cancelled": true}
	var final := occupied.duplicate()
	var remove := []
	var add := []
	for index in ordered.size():
		var cell: Vector3i = ordered[index]
		var base := bases[index]
		var before := initial[base] == 1
		var after := data[base] == 1
		if before and not after:
			final.erase(cell)
			remove.append(cell)
		elif not before and after:
			final[cell] = true
			add.append(cell)
	remove.sort()
	add.sort()
	return {"occupied": final, "remove": remove, "add": add}


static func _grid_face_neighbor(data: PackedByteArray, base: int, stride_x: int, stride_y: int) -> bool:
	return data[base - stride_x] == 1 or data[base + stride_x] == 1 or data[base - stride_y] == 1 or data[base + stride_y] == 1 or data[base - 1] == 1 or data[base + 1] == 1


static func _relax_dict(occupied: Dictionary, cells: Array, ordered: Array, budget: Dictionary, use_passes: int, radius: int, remove_threshold: float, add_threshold: float, cancel: Callable) -> Dictionary:
	var current := occupied.duplicate()
	for pass_index in use_passes:
		var outcome := weighted_pass(current, ordered, budget, pass_index, radius, remove_threshold, add_threshold, cancel)
		if outcome.has("cancelled"):
			return {"occupied": occupied.duplicate(), "remove": [], "add": [], "cancelled": true}
		for cell: Vector3i in outcome["remove"]:
			current.erase(cell)
		for cell: Vector3i in outcome["add"]:
			current[cell] = true
		if not (outcome["remove"] as Array).is_empty() or not (outcome["add"] as Array).is_empty():
			var completed := 0
			for cell: Vector3i in outcome["evaluated"]:
				if current.has(cell) and not _has_face_neighbor(current, cell):
					current.erase(cell)
				completed += 1
				if cancel.is_valid() and completed % CHECKPOINT_INTERVAL == 0 and not cancel.call(completed):
					return {"occupied": occupied.duplicate(), "remove": [], "add": [], "cancelled": true}
	var remove := []
	var add := []
	for cell: Vector3i in cells:
		var before := occupied.has(cell)
		var after := current.has(cell)
		if before and not after:
			remove.append(cell)
		elif not before and after:
			add.append(cell)
	remove.sort()
	add.sort()
	return {"occupied": current, "remove": remove, "add": add}


static func _budget(ordered: Array, use_passes: int, weights: Dictionary) -> Dictionary:
	var budget := {}
	for cell: Vector3i in ordered:
		budget[cell] = roundi(float(use_passes) * clampf(float(weights.get(cell, 1.0)), 0.0, 1.0))
	return budget


static func relax(occupied: Dictionary, cells: Array, passes := 1, radius := KERNEL_RADIUS, remove_threshold := REMOVE_THRESHOLD, add_threshold := ADD_THRESHOLD, weights := {}, cancel := Callable(), box := [], ordered_hint := false, cell_weights := PackedFloat64Array()) -> Dictionary:
	var use_passes := maxi(passes, 0)
	if cells.is_empty() or use_passes == 0:
		return _relax_dict(occupied, cells, cells, _budget(cells, use_passes, weights), use_passes, radius, remove_threshold, add_threshold, cancel)
	var min_cell: Vector3i
	var max_cell: Vector3i
	if box.size() == 2:
		min_cell = box[0]
		max_cell = box[1]
	else:
		min_cell = cells[0]
		max_cell = cells[0]
		for index in range(1, cells.size()):
			var cell: Vector3i = cells[index]
			min_cell.x = mini(min_cell.x, cell.x)
			min_cell.y = mini(min_cell.y, cell.y)
			min_cell.z = mini(min_cell.z, cell.z)
			max_cell.x = maxi(max_cell.x, cell.x)
			max_cell.y = maxi(max_cell.y, cell.y)
			max_cell.z = maxi(max_cell.z, cell.z)
	var ordered_input := ordered_hint
	if not ordered_input:
		var previous: Vector3i = cells[0]
		for index in range(1, cells.size()):
			var cell: Vector3i = cells[index]
			if previous.y > cell.y or (previous.y == cell.y and (previous.z > cell.z or (previous.z == cell.z and previous.x > cell.x))):
				ordered_input = false
				break
			previous = cell
	var ordered: Array
	if ordered_input:
		ordered = cells
	else:
		ordered = cells.duplicate()
		ordered.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return a.y < b.y if a.y != b.y else (a.z < b.z if a.z != b.z else a.x < b.x))
	var halo := required_halo(radius)
	var low := Vector3i(min_cell.x - halo, min_cell.y - halo, min_cell.z - halo)
	var high := Vector3i(max_cell.x + halo, max_cell.y + halo, max_cell.z + halo)
	var size := Vector3i(high.x - low.x + 1, high.y - low.y + 1, high.z - low.z + 1)
	var volume := size.x * size.y * size.z
	if volume > GRID_LIMIT_BYTES:
		return _relax_dict(occupied, cells, ordered, _budget(ordered, use_passes, weights), use_passes, radius, remove_threshold, add_threshold, cancel)
	var stride_y := size.z
	var stride_x := size.y * size.z
	var data := PackedByteArray()
	data.resize(volume)
	for point: Vector3i in occupied:
		if point.x >= low.x and point.x <= high.x and point.y >= low.y and point.y <= high.y and point.z >= low.z and point.z <= high.z:
			data[(point.x - low.x) * stride_x + (point.y - low.y) * stride_y + (point.z - low.z)] = 1
	var budgets := PackedInt32Array()
	var bases := PackedInt32Array()
	budgets.resize(ordered.size())
	bases.resize(ordered.size())
	var aligned := cell_weights.size() == ordered.size()
	var budget_scale := float(use_passes)
	var previous_cell := Vector3i.ZERO
	var base_cursor := 0
	for index in ordered.size():
		var cell: Vector3i = ordered[index]
		if aligned:
			budgets[index] = roundi(budget_scale * clampf(cell_weights[index], 0.0, 1.0))
		else:
			budgets[index] = roundi(budget_scale * clampf(float(weights.get(cell, 1.0)), 0.0, 1.0))
		if index == 0 or cell.y != previous_cell.y or cell.z != previous_cell.z or cell.x != previous_cell.x + 1:
			base_cursor = (cell.x - low.x) * stride_x + (cell.y - low.y) * stride_y + (cell.z - low.z)
		else:
			base_cursor += stride_x
		bases[index] = base_cursor
		previous_cell = cell
	var initial := data.duplicate()
	return _relax_grid(occupied, ordered, budgets, bases, use_passes, radius, remove_threshold, add_threshold, cancel, data, initial, stride_x, stride_y)


static func advance(occupied: Dictionary, cells: Array, passes: int, radius := KERNEL_RADIUS, remove_threshold := REMOVE_THRESHOLD, add_threshold := ADD_THRESHOLD, weights := {}, cancel := Callable(), box := [], ordered_hint := false, cell_weights := PackedFloat64Array()) -> Dictionary:
	if cells.is_empty():
		return {"occupied": occupied.duplicate(), "remove": [], "add": [], "passes": 0}
	var use_passes := mini(maxi(passes, 0), MAX_PASSES_PER_CALL)
	var outcome := relax(occupied, cells, use_passes, radius, remove_threshold, add_threshold, weights, cancel, box, ordered_hint, cell_weights)
	outcome["passes"] = use_passes
	return outcome
