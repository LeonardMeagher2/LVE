class_name TerrainPreview
extends RefCounted


const CANCEL_CHECKPOINT := 16
const VoxelFalloff := preload("res://Globals/State/Tools/VoxelFalloff.gd")

static func depth_for(radius: int) -> int:
	return footprint_depth(radius)


static func footprint_depth(size: int) -> int:
	return TerrainGeometry.read_depth(size)


static func masks_for(context: VoxelFrame.EditContext) -> Array:
	var masks := []
	if context == null:
		masks.append(0)
		return masks
	for mask in 8:
		if (mask & ~context.axes) == 0:
			masks.append(mask)
	return masks


static func compute_sample_map(frame: VoxelFrame, terrain_frame: TerrainFrame, center_point: Vector3, radius: int, falloff: float, context: VoxelFrame.EditContext, depth: int, known: Dictionary = {}, job: VoxelFrame.EditJob = null, query: TerrainQueryContext = null, base_known: Dictionary = {}, floor_axis := 1, floor_cell := 0, known_columns: Dictionary = {}) -> Dictionary:
	var candidates := []
	var completed := 0
	for mask in masks_for(context):
		var reflected := terrain_frame.reflected(context, mask)
		var center := center_point if mask == 0 else TerrainFrame.mirror_point(center_point, context, mask)
		for entry in TerrainGeometry.disk_offsets(radius):
			var weight := VoxelFalloff.weight_at(entry["distance"], float(radius), falloff, TerrainGeometry.disk_inner(radius))
			if weight <= 0.0:
				continue
			var point: Vector3 = center + float(entry["u"]) * reflected.tangent_u + float(entry["v"]) * reflected.tangent_v
			var base_point: Vector3 = center_point + float(entry["u"]) * terrain_frame.tangent_u + float(entry["v"]) * terrain_frame.tangent_v
			var anchor := TerrainGeometry.cell_at(base_point) if mask == 0 else context.reflect(TerrainGeometry.cell_at(base_point), mask)
			var seed0 := TerrainGeometry.cell_at(base_point)
			seed0[floor_axis] = floor_cell
			var seed := seed0 if mask == 0 else context.reflect(seed0, mask)
			var base_key := TerrainGeometry.column_key(anchor, reflected.normal)
			var tracked := known.has(anchor) or known_columns.has(base_key)
			var surface: Vector3i
			if known.has(anchor):
				surface = known[anchor]
			elif known_columns.has(base_key):
				surface = known_columns[base_key]
			else:
				surface = TerrainGeometry.surface_along(frame, point, reflected.normal, depth, {}, query)
			if surface != VoxelPicking.NONE and not tracked:
				if TerrainGeometry.is_occupied(frame, {}, TerrainGeometry.next_cell(surface, reflected.normal)):
					surface = VoxelPicking.NONE
			var base: Vector3i
			if base_known.has(base_key):
				base = base_known[base_key]
			else:
				base = surface
				base_known[base_key] = base
			candidates.append({
				"anchor": anchor,
				"point": point,
				"normal": reflected.normal,
				"plane_origin": reflected.origin,
				"weight": weight,
				"surface": surface,
				"base_surface": base,
				"seed": seed,
				"claim": surface if surface != VoxelPicking.NONE else anchor,
			})
			completed += 1
			if job != null and completed % CANCEL_CHECKPOINT == 0 and not job.checkpoint(completed):
				return {}
	if job != null and not job.checkpoint(completed):
		return {}
	return TerrainGeometry.resolve_samples(candidates)


static var _weighted_sphere_cache := {}
static var _weighted_sphere_lock := Mutex.new()

static func compute_smooth_fields(center_point: Vector3, radius: int, falloff: float, context: VoxelFrame.EditContext, job: VoxelFrame.EditJob = null) -> Array:
	var fields := []
	var completed := 0
	var selection: Dictionary = context.selection if context != null else {}
	var sphere := _weighted_sphere(radius, falloff)
	var offset_cells: Array = sphere[0]
	var sphere_weights: PackedFloat64Array = sphere[1]
	var low_offset: Vector3i = sphere[2]
	var high_offset: Vector3i = sphere[3]
	var offset_count := offset_cells.size()
	for mask in masks_for(context):
		var center := center_point if mask == 0 else TerrainFrame.mirror_point(center_point, context, mask)
		var base := TerrainGeometry.cell_at(center)
		var cells := []
		var weights := {}
		var cell_weights := PackedFloat64Array()
		for i in offset_count:
			var weight := sphere_weights[i]
			if weight <= 0.0:
				continue
			var cell: Vector3i = base + offset_cells[i]
			completed += 1
			if job != null and completed % CANCEL_CHECKPOINT == 0 and not job.checkpoint(completed):
				return []
			if TerrainGeometry.allows(selection, cell) and (context == null or context.allows(cell)):
				cells.append(cell)
				weights[cell] = weight
				cell_weights.append(weight)
		fields.append({
			"cells": cells,
			"weights": weights,
			"cell_weights": cell_weights,
			"box": [base + low_offset, base + high_offset],
			"ordered": true,
		})
	return fields


static func _weighted_sphere(radius: int, falloff: float) -> Array:
	var key := "%d:%s" % [radius, falloff]
	_weighted_sphere_lock.lock()
	var cached: Array = _weighted_sphere_cache.get(key, [])
	_weighted_sphere_lock.unlock()
	if not cached.is_empty():
		return cached
	var offsets := TerrainGeometry.sphere_offsets(radius)
	var count := offsets.size()
	var offset_cells := []
	var weights := PackedFloat64Array()
	weights.resize(count)
	var packed := []
	var low_offset := Vector3i.ZERO
	var high_offset := Vector3i.ZERO
	for i in count:
		var entry: Dictionary = offsets[i]
		var off: Vector3i = entry["offset"]
		low_offset.x = mini(low_offset.x, off.x)
		low_offset.y = mini(low_offset.y, off.y)
		low_offset.z = mini(low_offset.z, off.z)
		high_offset.x = maxi(high_offset.x, off.x)
		high_offset.y = maxi(high_offset.y, off.y)
		high_offset.z = maxi(high_offset.z, off.z)
		offset_cells.append(off)
		weights[i] = VoxelFalloff.weight_at(float(entry["distance"]), float(radius), falloff, 0.0)
		packed.append((((off.y + 64) * 128 + (off.z + 64)) * 128 + (off.x + 64)) * (1 << 18) + i)
	packed.sort()
	var sorted_cells := []
	sorted_cells.resize(count)
	var sorted_weights := PackedFloat64Array()
	sorted_weights.resize(count)
	for i in count:
		var index: int = packed[i] % (1 << 18)
		sorted_cells[i] = offset_cells[index]
		sorted_weights[i] = weights[index]
	var result := [sorted_cells, sorted_weights, low_offset, high_offset]
	result.make_read_only()
	_weighted_sphere_lock.lock()
	_weighted_sphere_cache[key] = result
	_weighted_sphere_lock.unlock()
	return result


static func center_surface(samples: Dictionary, center_point: Vector3) -> Vector3i:
	var best := VoxelPicking.NONE
	var best_distance := INF
	for anchor in samples:
		var sample: Dictionary = samples[anchor]
		var point: Vector3 = sample["point"]
		var distance := point.distance_squared_to(center_point)
		if distance < best_distance:
			best_distance = distance
			best = sample.get("base_surface", sample["surface"])
	return best


static func compute_hover_frame(frame: VoxelFrame, hit: Vector3i, entry: Vector3i, target: Vector3i, radius: int, floor_axis: int, floor_index: int, forward: Vector3, job: VoxelFrame.EditJob = null, query: TerrainQueryContext = null) -> Dictionary:
	if frame == null:
		return {}
	if hit == VoxelPicking.NONE:
		if target == VoxelPicking.NONE:
			return {}
		var level := float(floor_index) - 0.5
		var floor_sign := 1 if target[floor_axis] >= floor_index else -1
		var floor_frame := TerrainFrame.from_floor(floor_axis, floor_sign, level, target)
		return {"frame": floor_frame, "point": floor_frame.origin, "seed_empty": true}
	var use_entry := entry
	if use_entry == Vector3i.ZERO:
		use_entry = Vector3i.ZERO
		use_entry[VoxelPicking.view_axis(forward)] = 1
	var fallback := TerrainFrame.from_face(hit, use_entry)
	var hover_frame := TerrainFrame.from_surface(frame, hit, use_entry, radius, fallback, job, query)
	return {"frame": hover_frame, "point": hover_frame.origin, "seed_empty": false}


static func watch_half(radius: int) -> int:
	return radius + 2 * TerrainGeometry.read_depth(radius) + 3


static func watch_region(active: VoxelFrame, center: Vector3i, half: int) -> PackedInt64Array:
	if active == null:
		return PackedInt64Array()
	var low := VoxelFrame.chunk_position(center - Vector3i.ONE * half)
	var high := VoxelFrame.chunk_position(center + Vector3i.ONE * half)
	var box_count := (high.x - low.x + 1) * (high.y - low.y + 1) * (high.z - low.z + 1)
	var records: Array = []
	if active.chunks.size() <= box_count:
		for location: Vector3i in active.chunks:
			if location.x < low.x or location.x > high.x:
				continue
			if location.y < low.y or location.y > high.y:
				continue
			if location.z < low.z or location.z > high.z:
				continue
			var chunk: VoxelFrame.Chunk = active.chunks[location]
			records.append(location.x)
			records.append(location.y)
			records.append(location.z)
			records.append(chunk.get_instance_id())
			records.append(chunk.voxel_revision)
	else:
		for z in range(low.z, high.z + 1):
			for y in range(low.y, high.y + 1):
				for x in range(low.x, high.x + 1):
					var chunk: VoxelFrame.Chunk = active.chunks.get(Vector3i(x, y, z))
					if chunk == null:
						continue
					records.append(x)
					records.append(y)
					records.append(z)
					records.append(chunk.get_instance_id())
					records.append(chunk.voxel_revision)
	return PackedInt64Array(records)


static func watch_chunks(active: VoxelFrame, center: Vector3i, half: int) -> Array[Vector3i]:
	var locations: Array[Vector3i] = []
	if active == null:
		return locations
	var low := VoxelFrame.chunk_position(center - Vector3i.ONE * half)
	var high := VoxelFrame.chunk_position(center + Vector3i.ONE * half)
	var box_count := (high.x - low.x + 1) * (high.y - low.y + 1) * (high.z - low.z + 1)
	if active.chunks.size() <= box_count:
		for location: Vector3i in active.chunks:
			if location.x < low.x or location.x > high.x:
				continue
			if location.y < low.y or location.y > high.y:
				continue
			if location.z < low.z or location.z > high.z:
				continue
			locations.append(location)
	else:
		for z in range(low.z, high.z + 1):
			for y in range(low.y, high.y + 1):
				for x in range(low.x, high.x + 1):
					var location := Vector3i(x, y, z)
					if active.chunks.has(location):
						locations.append(location)
	return locations


class Request extends RefCounted:
	var id := 0
	var intent := 0
	var epoch := 0
	var frame: VoxelFrame
	var frame_id := 0
	var hit := VoxelPicking.NONE
	var entry := Vector3i.ZERO
	var target := VoxelPicking.NONE
	var forward := Vector3.BACK
	var floor_axis := 1
	var floor_index := 0
	var radius := 4
	var camera := Transform3D()
	var projection := Projection()
	var viewport := Vector2i.ZERO
	var born_us := 0
	var key: Array = []
	var surface_watch := PackedInt64Array()


class HoverJob extends VoxelFrame.EditJob:
	var request: Request
	var ok := false
	var hover_frame: TerrainFrame
	var surface_us := 0
	var surface_ran := false

	func run() -> void:
		var req := request
		stage("Reading hover surface", 1)
		if not checkpoint(0):
			return
		var query := TerrainQueryContext.new(req.frame)
		var started := Time.get_ticks_usec()
		var hover := TerrainPreview.compute_hover_frame(req.frame, req.hit, req.entry, req.target, req.radius, req.floor_axis, req.floor_index, req.forward, self, query)
		surface_us = Time.get_ticks_usec() - started
		surface_ran = true
		if not checkpoint(0):
			return
		if hover.is_empty():
			ok = true
			return
		self.hover_frame = hover["frame"]
		ok = true


var provider: Callable
var publisher: Callable
var pauser: Callable = Callable()
var view_provider: Callable = Callable()
var hider: Callable = Callable()

var _cache_valid := false
var _cache_key: Array = []
var _cache_surface_watch := PackedInt64Array()
var _hover_frame: TerrainFrame
var _cache_camera := Transform3D()
var _cache_projection := Projection()
var _cache_viewport := Vector2i.ZERO
var _cache_view_axis := -1
var _stash_frame: TerrainFrame
var _stash_key: Array = []
var _stash_surface_watch := PackedInt64Array()
var _stash_camera := Transform3D()
var _stash_projection := Projection()
var _stash_viewport := Vector2i.ZERO
var _stash_view_axis := -1
var hover_surface_count := 0

var _dirty := true
var _epoch := 0
var _request_id := 0
var _published_id := 0
var _intent := 0
var _job: HoverJob

var launches := 0
var publishes := 0
var discarded := 0
var snapshot_us := 0
var hover_frame_calls := 0
var hover_frame_us := 0
var hover_frame_hits := 0
var hover_frame_misses := 0

var stale_position_publishes := 0
var last_publish_age_us := 0
var max_publish_age_us := 0
var last_publish_target := VoxelPicking.NONE
var last_publish_target_matches := true


func is_dirty() -> bool:
	return _dirty


func is_settled() -> bool:
	return _job == null and not _dirty


func is_running() -> bool:
	return _job != null


func hover_frame() -> TerrainFrame:
	return _hover_frame


func reset_counters() -> void:
	launches = 0
	publishes = 0
	discarded = 0
	snapshot_us = 0
	hover_frame_calls = 0
	hover_frame_us = 0
	hover_frame_hits = 0
	hover_frame_misses = 0
	hover_surface_count = 0
	stale_position_publishes = 0
	last_publish_age_us = 0
	max_publish_age_us = 0
	last_publish_target = VoxelPicking.NONE
	last_publish_target_matches = true


func counters() -> Dictionary:
	return {
		"launches": launches, "publishes": publishes, "discarded": discarded,
		"snapshot_us": snapshot_us,
		"hover_calls": hover_frame_calls, "hover_us": hover_frame_us,
		"hover_hits": hover_frame_hits, "hover_misses": hover_frame_misses,
		"hover_surface": hover_surface_count,
		"stale_position_publishes": stale_position_publishes,
		"last_publish_age_us": last_publish_age_us,
		"max_publish_age_us": max_publish_age_us,
		"last_publish_target_matches": last_publish_target_matches,
	}


func mark_intent() -> void:
	_dirty = true
	_intent += 1


func invalidate() -> void:
	_stash_from_cache()
	_epoch += 1
	_intent += 1
	_cache_valid = false
	_dirty = true
	if _job != null:
		_job.cancel()
	if hider.is_valid():
		hider.call()


func _stash_from_cache() -> void:
	if not _cache_valid or _hover_frame == null:
		return
	_stash_frame = _hover_frame
	_stash_key = _cache_key
	_stash_surface_watch = _cache_surface_watch
	_stash_camera = _cache_camera
	_stash_projection = _cache_projection
	_stash_viewport = _cache_viewport
	_stash_view_axis = _cache_view_axis


func clear_all() -> void:
	_epoch += 1
	_cache_valid = false
	_dirty = false
	if _job != null:
		_job.cancel()
	_publish()


func publish_now() -> void:
	_epoch += 1
	_cache_valid = false
	_dirty = false
	if _job != null:
		_job.cancel()
	_publish()


func cancel_pending() -> void:
	_epoch += 1
	if _job != null:
		_job.cancel()


func join() -> void:
	if _job == null:
		return
	_job.cancel()
	_job.wait_for_worker()
	_job = null


func process() -> void:
	poll()
	if not _dirty:
		return
	_evaluate()


func refresh() -> void:
	poll()
	_evaluate()


func stashed_frame(inputs: Dictionary) -> TerrainFrame:
	if _stash_frame == null:
		return null
	var live: VoxelFrame = inputs.get("frame")
	var hit: Vector3i = inputs.get("hit", VoxelPicking.NONE)
	if live == null or hit == VoxelPicking.NONE:
		return null
	if _key_of(inputs) != _stash_key:
		return null
	if VoxelPicking.view_axis(inputs.get("forward", Vector3.BACK)) != _stash_view_axis:
		return null
	var half := watch_half(int(inputs["radius"]))
	if watch_region(live, hit, half) != _stash_surface_watch:
		return null
	if not _stashed_view_matches(inputs):
		return null
	return _stash_frame


func _stashed_view_matches(inputs: Dictionary) -> bool:
	if not view_provider.is_valid():
		return true
	var view: Dictionary = view_provider.call()
	if view.is_empty() or not bool(view.get("valid", false)):
		return true
	if view["viewport"] != _stash_viewport:
		return false
	if not (view["camera"] as Transform3D).is_equal_approx(_stash_camera):
		return false
	return _projection_equal(view["projection"], _stash_projection)


func _evaluate() -> void:
	if _job != null:
		return
	if pauser.is_valid() and pauser.call():
		return
	if not provider.is_valid():
		return
	var inputs: Dictionary = provider.call()
	if inputs.is_empty() or not bool(inputs.get("ready", false)):
		_hide()
		return
	var live: VoxelFrame = inputs["frame"]
	var hit: Vector3i = inputs["hit"]
	var target: Vector3i = inputs["target"]
	if live == null or (hit == VoxelPicking.NONE and target == VoxelPicking.NONE):
		_hide()
		return
	var half := watch_half(int(inputs["radius"]))
	if _cache_valid and _matches(inputs, live, hit, half):
		_dirty = false
		hover_frame_hits += 1
		last_publish_target = target
		last_publish_target_matches = true
		_publish()
		return
	_launch(inputs, live, hit, half)


func poll() -> void:
	if _job == null:
		return
	if not WorkerThreadPool.is_task_completed(_job.worker_task_id):
		return
	_job.wait_for_worker()
	var job := _job
	_job = null
	_consume(job)


func _consume(job: HoverJob) -> void:
	if job.surface_ran:
		hover_frame_calls += 1
		hover_frame_us += job.surface_us
	if not job.ok:
		discarded += 1
		return
	if job.request.epoch != _epoch:
		discarded += 1
		return
	if job.request.id <= _published_id:
		discarded += 1
		return
	if pauser.is_valid() and pauser.call():
		discarded += 1
		return
	var request := job.request
	var inputs: Dictionary = provider.call() if provider.is_valid() else {}
	var live: VoxelFrame = inputs.get("frame") if not inputs.is_empty() else null
	if not _still_valid(request, inputs, live):
		discarded += 1
		_dirty = true
		return
	if not _camera_matches(request):
		discarded += 1
		_dirty = true
		return
	_cache_valid = true
	_cache_key = request.key
	_cache_surface_watch = request.surface_watch
	_cache_camera = request.camera
	_cache_projection = request.projection
	_cache_viewport = request.viewport
	_cache_view_axis = VoxelPicking.view_axis(request.forward)
	_hover_frame = job.hover_frame
	if _hover_frame != null and _hover_frame.follows_surface:
		hover_surface_count += 1
	_published_id = request.id
	hover_frame_misses += 1
	publishes += 1
	var age_us := Time.get_ticks_usec() - request.born_us
	last_publish_age_us = age_us
	max_publish_age_us = maxi(max_publish_age_us, age_us)
	last_publish_target = request.target
	var current_target: Vector3i = inputs.get("target", request.target) if not inputs.is_empty() else request.target
	last_publish_target_matches = current_target == request.target
	if not last_publish_target_matches:
		stale_position_publishes += 1
	_publish()
	_dirty = _intent != request.intent


func _still_valid(request: Request, inputs: Dictionary, live: VoxelFrame) -> bool:
	if inputs.is_empty() or not bool(inputs.get("ready", false)) or live == null:
		return false
	if int(inputs["frame_id"]) != request.frame_id:
		return false
	if int(inputs["radius"]) != request.radius:
		return false
	if int(inputs["floor_axis"]) != request.floor_axis or int(inputs["floor_index"]) != request.floor_index:
		return false
	var half := watch_half(request.radius)
	if request.hit == VoxelPicking.NONE:
		if not request.surface_watch.is_empty():
			return false
	elif watch_region(live, request.hit, half) != request.surface_watch:
		return false
	return true


func _launch(inputs: Dictionary, live: VoxelFrame, hit: Vector3i, half: int) -> void:
	var started := Time.get_ticks_usec()
	var request := Request.new()
	request.id = _request_id + 1
	request.intent = _intent
	request.epoch = _epoch
	var center := hit
	if center == VoxelPicking.NONE:
		center = inputs.get("target", VoxelPicking.NONE)
	if center != VoxelPicking.NONE:
		var reach := half + int(inputs["radius"]) + 1
		request.frame = live.copy_chunks(watch_chunks(live, center, reach))
	else:
		request.frame = live.copy_frame()
	request.frame_id = int(inputs["frame_id"])
	request.hit = hit
	request.entry = inputs["entry"]
	request.target = inputs["target"]
	request.forward = inputs["forward"]
	request.floor_axis = int(inputs["floor_axis"])
	request.floor_index = int(inputs["floor_index"])
	request.radius = int(inputs["radius"])
	request.camera = inputs["camera"]
	request.projection = inputs["projection"]
	request.viewport = inputs["viewport"]
	request.born_us = Time.get_ticks_usec()
	request.key = _key_of(inputs)
	request.surface_watch = watch_region(live, hit, half) if hit != VoxelPicking.NONE else PackedInt64Array()
	snapshot_us += Time.get_ticks_usec() - started
	var job := HoverJob.new()
	job.request = request
	_request_id = request.id
	launches += 1
	job.worker_task_id = WorkerThreadPool.add_task(job.run, false, "Terrain preview")
	_job = job


func _matches(inputs: Dictionary, live: VoxelFrame, hit: Vector3i, half: int) -> bool:
	if _key_of(inputs) != _cache_key:
		return false
	if hit == VoxelPicking.NONE:
		if not _cache_surface_watch.is_empty():
			return false
	elif watch_region(live, hit, half) != _cache_surface_watch:
		return false
	return true


func _key_of(inputs: Dictionary) -> Array:
	return [
		inputs["hit"].x, inputs["hit"].y, inputs["hit"].z,
		inputs["target"].x, inputs["target"].y, inputs["target"].z,
		inputs["radius"],
		inputs["floor_axis"], inputs["floor_index"],
		inputs["frame_id"],
	]


func _camera_matches(request: Request) -> bool:
	if not view_provider.is_valid():
		return true
	var view: Dictionary = view_provider.call()
	if view.is_empty() or not bool(view.get("valid", false)):
		return true
	if view["viewport"] != request.viewport:
		return false
	if not (view["camera"] as Transform3D).is_equal_approx(request.camera):
		return false
	return _projection_equal(view["projection"], request.projection)


static func _projection_equal(first: Projection, second: Projection) -> bool:
	return first.x.is_equal_approx(second.x) and first.y.is_equal_approx(second.y) and first.z.is_equal_approx(second.z) and first.w.is_equal_approx(second.w)


func _hide() -> void:
	_epoch += 1
	_cache_valid = false
	_dirty = false
	if _job != null:
		_job.cancel()
	_publish()


func _publish() -> void:
	if publisher.is_valid():
		publisher.call()
