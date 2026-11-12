class_name TerrainPreview
extends RefCounted

## The maximum depth of the footprint for tall terrain.
const FOOTPRINT_DEPTH_LIMIT := 64

## Owns the idle hover preview of the terrain tool.
##
## The controller holds the hover frame, the footprint cells, and their cache. A
## hover that misses the cache runs on the worker pool, so a maximum size surface read
## or footprint map never stalls the frame that asked for it. One job runs at a
## time, and only the newest request waits for it, so a fast pointer never builds
## a backlog. A published result must belong to a live request: a job that an
## invalidation superseded is dropped, and a job that a newer published result
## superseded is dropped too.
##
## The tool supplies the live inputs through [member provider], receives the cells
## through [member publisher], and reports whether a stroke blocks the hover
## through [member pauser]. The worker reads only the request: plain values and
## one frozen frame snapshot. It never reads [code]State[/code] or a node.
##
## A request is a plain dictionary. The keys are:
##
## [code]ready[/code] -- false when the pointer has no hover.
## [code]frame[/code] -- the live frame, frozen by the controller.
## [code]frame_id[/code] -- the identity of the live frame.
## [code]hit[/code], [code]entry[/code], [code]target[/code] -- the pick.
## [code]forward[/code] -- the view direction, for the missing entry fallback.
## [code]context[/code] -- the frozen edit context.
## [code]floor_axis[/code], [code]floor_cell[/code] -- the floor plane and the first buildable cell on the stroke side.
## [code]tool[/code], [code]build_mode[/code] -- the settings.
## [code]radius[/code], [code]falloff[/code], [code]depth[/code] -- the footprint.
## [code]camera[/code], [code]projection[/code], [code]viewport[/code] -- the
## captured view, so a camera change drops a stale result.

const CANCEL_CHECKPOINT := 16
## The disc offsets between two worker cancel checks of one surface read. One offset is one
## bounded surface walk.
const READ_CANCEL_CHECKPOINT := 32


## Returns the bounded surface search depth of one radius.
##
## Uses the same formula as footprint_depth for consistency with the brush
## plugin's diameter-based scaling. The hover outline matches the execution
## cells, making tall terrain behavior predictable.
static func depth_for(radius: int) -> int:
	return footprint_depth(radius)


## Returns the bounded surface search depth of one footprint column.
##
## The depth scales with the brush size, but keeps a minimum depth for tall
## terrain. Users think in terms of brush size, so the size is the input.
static func footprint_depth(size: int) -> int:
	# Scale with the size but ensure at least 16 cells for tall terrain support.
	# This matches the brush plugin's footprint scaling behavior.
	return mini(FOOTPRINT_DEPTH_LIMIT, maxi(16, size))


## Returns the active symmetry masks of one context. A null context is one mask.
static func masks_for(context: VoxelFrame.EditContext) -> Array:
	var masks := []
	if context == null:
		masks.append(0)
		return masks
	for mask in 8:
		if (mask & ~context.axes) == 0:
			masks.append(mask)
	return masks


## Returns the footprint samples keyed by their anchor cell.
##
## The samples come from every active symmetry mask. [param known] maps an anchor
## cell to its tracked surface, so a persisting column never re-scans. A repeated
## claimed surface keeps the highest weight, so two samples never write the same
## cell. Every candidate is collected first, then resolved once, so a tilted disc
## whose entries share an anchor or a claim can never leave a dangling owner. The
## surface scan order is the shipped order, so the query stream is unchanged.
##
## The body is shared by the stroke path and the hover worker, so both read one
## definition. [param job] supplies the cancel checkpoints of a worker, and
## [param query] its exact read-only column index.
static func compute_sample_map(frame: VoxelFrame, terrain_frame: TerrainFrame, center_point: Vector3, radius: int, falloff: float, context: VoxelFrame.EditContext, depth: int, known: Dictionary = {}, job: VoxelFrame.EditJob = null, query: TerrainQueryContext = null, base_known: Dictionary = {}, floor_axis := 1, floor_cell := 0, known_columns: Dictionary = {}) -> Dictionary:
	var candidates := []
	var completed := 0
	for mask in masks_for(context):
		var reflected := terrain_frame.reflected(context, mask)
		var center := center_point if mask == 0 else TerrainFrame.mirror_point(center_point, context, mask)
		for entry in TerrainGeometry.disk_offsets(radius):
			var weight := TerrainGeometry.weight_at(entry["distance"], float(radius), falloff, TerrainGeometry.disk_inner(radius))
			if weight <= 0.0:
				continue
			var point: Vector3 = center + float(entry["u"]) * reflected.tangent_u + float(entry["v"]) * reflected.tangent_v
			# The cell anchor is the mirror of the cell, not the cell of the mirror
			# point. The half-cell rounding otherwise moves a mirrored seed by one.
			var base_point: Vector3 = center_point + float(entry["u"]) * terrain_frame.tangent_u + float(entry["v"]) * terrain_frame.tangent_v
			var anchor := TerrainGeometry.cell_at(base_point) if mask == 0 else context.reflect(TerrainGeometry.cell_at(base_point), mask)
			var seed0 := TerrainGeometry.cell_at(base_point)
			seed0[floor_axis] = floor_cell
			var seed := seed0 if mask == 0 else context.reflect(seed0, mask)
			# The tracked top of a column outlives one dab. [param known_columns]
			# keys the whole logical column, so a column that left the brush and
			# came back reuses its top instead of a read from the old plane.
			var base_key := TerrainGeometry.column_key(anchor, reflected.normal)
			var tracked := known.has(anchor) or known_columns.has(base_key)
			var surface: Vector3i
			if known.has(anchor):
				surface = known[anchor]
			elif known_columns.has(base_key):
				surface = known_columns[base_key]
			else:
				surface = TerrainGeometry.surface_along(frame, point, reflected.normal, depth, {}, query)
			# A surface that still has solid beyond the read depth is outside the
			# brush volume. Ignore it instead of writing from an interior cell. A
			# tracked surface is authoritative, so it is never rejected.
			if surface != VoxelPicking.NONE and not tracked:
				if TerrainGeometry.is_occupied(frame, {}, TerrainGeometry.next_cell(surface, reflected.normal)):
					surface = VoxelPicking.NONE
			# The first sample of a column records the surface before this stroke
			# writes it. The key is the column, not the moving plane anchor, so a
			# later anchor in the same column reuses the base.
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


## Returns one rounding field per active symmetry mask. Each field holds the
## writable candidate cells and the per-cell falloff weight.
##
## The candidates fill a sphere of the brush size around the dab point, so the
## rounding reaches every cell the brush covers, up, down, and sideways. A cell
## is writable only when the frozen selection allows it. The body is shared by
## the stroke path and the hover worker. [param job] supplies the cancel
## checkpoints of a worker.
static func compute_smooth_fields(center_point: Vector3, radius: int, falloff: float, context: VoxelFrame.EditContext, job: VoxelFrame.EditJob = null) -> Array:
	var fields := []
	var completed := 0
	var selection: Dictionary = context.selection if context != null else {}
	var offsets := TerrainGeometry.sphere_offsets(radius)
	for mask in masks_for(context):
		var center := center_point if mask == 0 else TerrainFrame.mirror_point(center_point, context, mask)
		var base := TerrainGeometry.cell_at(center)
		var region := {}
		for entry in offsets:
			var cell: Vector3i = base + entry["offset"]
			var weight := TerrainGeometry.weight_at(float(entry["distance"]), float(radius), falloff, 0.0)
			if weight <= 0.0:
				continue
			# A cell reached by two mirrors keeps the strongest weight, so the
			# rate is deterministic and mirrored cells match.
			region[cell] = maxf(float(region.get(cell, 0.0)), weight)
			completed += 1
			if job != null and completed % CANCEL_CHECKPOINT == 0 and not job.checkpoint(completed):
				return []
		var cells := []
		var weights := {}
		for cell: Vector3i in region:
			if TerrainGeometry.allows(selection, cell) and (context == null or context.allows(cell)):
				cells.append(cell)
				weights[cell] = float(region[cell])
		cells.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return a.y < b.y if a.y != b.y else (a.z < b.z if a.z != b.z else a.x < b.x))
		fields.append({
			"cells": cells,
			"weights": weights,
		})
	return fields


## Returns the base surface of the sample nearest the dab center. The base is the
## surface that existed before this stroke first sampled the column, so the ground
## follows the cursor and never follows the brush's own output.
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


## Returns the hover frame of one request. The result holds the frame, its origin
## point, and whether an empty floor seed applies. A parallel miss leaves no
## target, so the result is empty and the sentinel arithmetic never runs.
##
## The surface read uses the frozen frame, so a worker never reads the live model.
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


## Returns the half extent in cells of the region a surface read or a map can read. One
## bounded query walks up to [param depth] cells to find the surface, then up to
## depth + 1 further outward, so a read cell is at most 2 * depth + 2 cells away.
## The disc adds the brush radius and one cell covers the half cell seed step.
static func watch_half(radius: int) -> int:
	return radius + 2 * depth_for(radius) + 3


## Returns the exact identity and revision of every occupied chunk inside the
## bounded box around one center. A missing chunk leaves no record, so a new
## chunk inside the box changes the result. The box scans through the smaller of
## the occupied chunk set and the box itself, so a big model with a small brush
## stays cheap.
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


## Returns the occupied chunk locations inside the bounded box around one center.
## `copy_chunks` then freezes only these chunks, so a hover costs the read box,
## not the whole frame. The box scan follows the smaller of the chunk set and the
## box, like [method watch_region].
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


## One frozen hover request. It holds the plain inputs and one frame snapshot, so
## a worker reads only the request.
class Request extends RefCounted:
	## The request id, in launch order.
	var id := 0
	## The intent serial that the request was launched for.
	var intent := 0
	## The invalidation epoch of the launch.
	var epoch := 0
	## The frozen frame snapshot.
	var frame: VoxelFrame
	## The identity of the live frame at the launch.
	var frame_id := 0
	## The hovered cell, its entered face, and the target cell.
	var hit := VoxelPicking.NONE
	var entry := Vector3i.ZERO
	var target := VoxelPicking.NONE
	## The view direction of the launch.
	var forward := Vector3.BACK
	## The floor plane.
	var floor_axis := 1
	var floor_index := 0
	## The surface read radius.
	var radius := 4
	## The captured view. The camera transform and the exact projection matrix
	## cover a zoom, a lens change, and a viewport resize, so a stale result never
	## reaches the cursor after any of them.
	var camera := Transform3D()
	var projection := Projection()
	var viewport := Vector2i.ZERO
	## The launch time, so a publish can report its age.
	var born_us := 0
	## The cache inputs without the watches.
	var key: Array = []
	## The watched chunks of the surface read region, computed on the live frame at the
	## launch.
	var surface_watch := PackedInt64Array()


## One cancellable hover computation. [method VoxelFrame.EditJob.run] is the
## worker body. The result is valid only when [member ok] is true and the job was
## not cancelled.
class HoverJob extends VoxelFrame.EditJob:
	## The request the job computes.
	var request: Request
	## Whether the job completed every stage.
	var ok := false
	## The hover frame of the request, or null when the hover has none.
	var hover_frame: TerrainFrame
	## The exact microseconds of the surface read.
	var surface_us := 0
	## Whether the surface read ran.
	var surface_ran := false

	## Computes the hover frame. This is the worker body. The cursor is the one
	## footprint ring, so the surface read is the whole hover result.
	func run() -> void:
		var req := request
		stage("Reading hover surface", 1)
		if not checkpoint(0):
			return
		# One exact column index per job. It shortens a cardinal query on an empty
		# column, and it never changes a result.
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


## The live inputs of the tool. It returns the dictionary above and must be set
## before the first [method process].
var provider: Callable
## The pose sink of the tool. It runs on the main thread when the hover state
## changes, so the tool can pose the footprint ring.
var publisher: Callable
## Returns true while an open stroke blocks the hover. Optional.
var pauser: Callable = Callable()
## Returns the live view as [code]{camera, projection, viewport}[/code]. Optional.
## Without it a camera change never drops a result.
var view_provider: Callable = Callable()
## Hides the visible preview without clearing the cursor request. Optional. An
## invalidation calls it, so a wrong footprint never shows, and the cursor keeps
## the mesh it already built.
var hider: Callable = Callable()

# The hover cache. It holds the surface frame and the inputs that produced it.
# The surface watch is recomputed against the live frame on every check, so a raw
# write inside the read region drops the cache and a write outside it does not.
var _cache_valid := false
var _cache_key: Array = []
var _cache_surface_watch := PackedInt64Array()
# The hover frame of the last published result, or null when the hover had none.
var _hover_frame: TerrainFrame
# The view and the fallback axis of the last published result. A press compares
# them against the live view, so a zoom or a rotation drops a reused frame.
var _cache_camera := Transform3D()
var _cache_projection := Projection()
var _cache_viewport := Vector2i.ZERO
var _cache_view_axis := -1
# The stash of the last valid hover result. An invalidation moves the valid
# cache here, so a press that follows at once reuses the surface hover frame
# instead of reading the same surface on the main thread. Every explicit press input
# is re-checked against the stash, so a stale frame never reaches a stroke.
var _stash_frame: TerrainFrame
var _stash_key: Array = []
var _stash_surface_watch := PackedInt64Array()
var _stash_camera := Transform3D()
var _stash_projection := Projection()
var _stash_viewport := Vector2i.ZERO
var _stash_view_axis := -1
# The count of published hover frames that follow the surface.
var hover_surface_count := 0

# The request state. The epoch rises on every invalidation, so a job that a
# settings, a context, or a frame change superseded is dropped. The request id
# rises on every launch, so a job that a newer published result superseded is
# dropped too.
var _dirty := true
var _epoch := 0
var _request_id := 0
var _published_id := 0
# The intent serial. A pointer move or an invalidation rises it. A published
# result clears the dirty flag only when its request still holds the live serial.
var _intent := 0
var _job: HoverJob

# The stage counters of the last measurement.
var launches := 0
var publishes := 0
var discarded := 0
var snapshot_us := 0
var hover_frame_calls := 0
var hover_frame_us := 0
var hover_frame_hits := 0
var hover_frame_misses := 0

# The publish latency and the position lag. The main-thread cost is not the
# preview latency: a fast pointer can publish a result for an older cell. These
# counters state the honest age and the lag of every published result.
var stale_position_publishes := 0
var last_publish_age_us := 0
var max_publish_age_us := 0
var last_publish_target := VoxelPicking.NONE
var last_publish_target_matches := true


## Returns true when the visible preview may not match the current inputs.
func is_dirty() -> bool:
	return _dirty


## Returns true when no hover job runs and no request waits.
func is_settled() -> bool:
	return _job == null and not _dirty


## Returns true while a hover job runs.
func is_running() -> bool:
	return _job != null


## Returns the hover frame of the last published result, or null when the hover
## had no frame.
func hover_frame() -> TerrainFrame:
	return _hover_frame


## Clears the stage counters. It does not change the preview state.
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


## Returns the stage counters as a dictionary.
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


## Marks the hover dirty after a pointer move. The visible preview stays, so a
## fast pointer never blanks the outline. A pointer move is not an invalidation:
## a result that a newer pointer superseded may still publish, with its age
## reported, because each published outline is exact for its own request.
func mark_intent() -> void:
	_dirty = true
	_intent += 1


## Retires every running and finished request and hides the visible preview. It
## never waits for the worker. A stroke, a Grab drag, a clear, and a context
## change call it, so an older hover result can never reach the cursor.
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


# Moves a valid cache result into the press stash before the cache is dropped.
# A press that follows at once can then reuse the surface hover frame, and an
# invalid cache leaves no stash.
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


## Drops the cache, retires every request, and clears the cursor request. A
## finished or a cancelled stroke calls it, so the ring of the closed stroke stays
## gone and no finished hover job can reappear.
func clear_all() -> void:
	_epoch += 1
	_cache_valid = false
	_dirty = false
	if _job != null:
		_job.cancel()
	_publish()


## Publishes the current hover state on the main thread and retires every hover
## request. The stroke and the Grab preview use it, so a finished hover job can
## never overwrite the stroke ring.
func publish_now() -> void:
	_epoch += 1
	_cache_valid = false
	_dirty = false
	if _job != null:
		_job.cancel()
	_publish()


## Retires the running request without waiting. The next [method poll] joins it
## and drops its result, so a press never waits for a preview worker. A stale job
## that already finished can never publish either, because the epoch moved.
func cancel_pending() -> void:
	_epoch += 1
	if _job != null:
		_job.cancel()


## Joins the running job. Call it on the main thread at teardown or on a document
## change, so no worker outlives the tool. It never runs on the press path.
func join() -> void:
	if _job == null:
		return
	_job.cancel()
	_job.wait_for_worker()
	_job = null


## Pumps the controller for one frame. It joins a finished job, publishes a valid
## result, and starts at most one request. It never blocks on a running worker.
func process() -> void:
	poll()
	if not _dirty:
		return
	_evaluate()


## Re-checks the cache and starts one request even when the hover is not marked
## dirty. A test and a benchmark use it to force one request outside the frame
## loop, so a raw write with no signal still refreshes the preview. The request
## still runs on the worker.
func refresh() -> void:
	poll()
	_evaluate()


## Returns the stashed hover frame when it exactly matches the given explicit
## press inputs. Any mismatch returns null, so the caller reads its own surface.
##
## The inputs are the same dictionary that [member provider] returns. The check
## covers the pick, the surface read radius, the floor, the surface read region of the live
## region of the live frame, and the live view. A stale frame of an older pointer
## therefore never reaches a stroke.
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


# Returns true when the live view still matches the stashed result. A zoom, a
# lens change, a rotation, or a viewport resize fails it.
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


# Runs the cache check and starts one request when the hover is ready.
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
		# A cache hit is exact for the live inputs, so its target is the current
		# one. The publisher reads the target to reject a stale read.
		last_publish_target = target
		last_publish_target_matches = true
		_publish()
		return
	_launch(inputs, live, hit, half)


# Polls the running job. A finished job joins, feeds the counters, and publishes
# when it belongs to the live epoch and a newer result did not win.
func poll() -> void:
	if _job == null:
		return
	if not WorkerThreadPool.is_task_completed(_job.worker_task_id):
		return
	_job.wait_for_worker()
	var job := _job
	_job = null
	_consume(job)


# Feeds the stage counters of a finished job and publishes a valid result.
#
# The publish gate runs before the cursor is touched. A result reaches the cursor
# only when the request still owns the tool and every live input still matches the
# request: the frame identity, the symmetry, the selection, the tool and its
# footprint, the floor, and the exact surface and map read regions of the live frame.
# A raw write with no signal inside a read region therefore drops the result and
# starts a fresh request, so a stale cell or a stale normal never shows.
func _consume(job: HoverJob) -> void:
	if job.surface_ran:
		hover_frame_calls += 1
		hover_frame_us += job.surface_us
	if not job.ok:
		# A cancelled job. The caller that cancelled it owns the next state.
		discarded += 1
		return
	if job.request.epoch != _epoch:
		discarded += 1
		return
	if job.request.id <= _published_id:
		discarded += 1
		return
	if pauser.is_valid() and pauser.call():
		# A stroke or an edit owns the tool, so no hover result may show.
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
	# The age and the position lag of this publish, so a report states the real
	# preview latency and not only the main-thread cost.
	var age_us := Time.get_ticks_usec() - request.born_us
	last_publish_age_us = age_us
	max_publish_age_us = maxi(max_publish_age_us, age_us)
	last_publish_target = request.target
	var current_target: Vector3i = inputs.get("target", request.target) if not inputs.is_empty() else request.target
	last_publish_target_matches = current_target == request.target
	if not last_publish_target_matches:
		stale_position_publishes += 1
	_publish()
	# The visible preview now matches the live inputs only when no newer intent
	# arrived while the job ran. A newer intent keeps the flag set, so the frame
	# loop starts the next request at once.
	_dirty = _intent != request.intent


# Returns true when the live inputs still match the request that produced a
# finished result. A pointer move to another cell is not a mismatch, because the
# result is exact for its own position; the age is reported apart. Every context,
# geometry, or read-region change is a mismatch, so a stale result never shows.
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


# Starts one request. The frame is frozen here, once per launch, so a mouse event
# never copies the model. The map watch is computed from the frozen snapshot when
# the job publishes.
func _launch(inputs: Dictionary, live: VoxelFrame, hit: Vector3i, half: int) -> void:
	var started := Time.get_ticks_usec()
	var request := Request.new()
	request.id = _request_id + 1
	request.intent = _intent
	request.epoch = _epoch
	# The job reads the surface disc around the hit, then the map disc under the
	# pointer. The pointer stays within the brush radius of the hit, so one box
	# covers both reads. A hover with no cell copies the full frame.
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


# Returns true when the cached frame still matches the live inputs and the live
# read region. A raw write or a new missing chunk inside the region fails it.
func _matches(inputs: Dictionary, live: VoxelFrame, hit: Vector3i, half: int) -> bool:
	if _key_of(inputs) != _cache_key:
		return false
	if hit == VoxelPicking.NONE:
		if not _cache_surface_watch.is_empty():
			return false
	elif watch_region(live, hit, half) != _cache_surface_watch:
		return false
	return true


# Returns the cache inputs that do not depend on the read region. Two inputs with
# the same list give the same surface frame.
#
# The entered face is not part of the key. A ray that grazes a convex edge can
# report either face for the same cell, and re-reading the surface on that flip rotated the
# ring under a still pointer. The first read for a cell is kept until the cell,
# the size, the floor, the frame, or the read region changes.
func _key_of(inputs: Dictionary) -> Array:
	return [
		inputs["hit"].x, inputs["hit"].y, inputs["hit"].z,
		inputs["target"].x, inputs["target"].y, inputs["target"].z,
		inputs["radius"],
		inputs["floor_axis"], inputs["floor_index"],
		inputs["frame_id"],
	]


# Returns true when the live view still matches the request. The camera transform
# and the exact projection matrix cover a zoom, a lens or an FOV change, a near or
# far change, and a viewport resize, so a result computed for another view never
# reaches the cursor.
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


# Returns true when two projection matrices match within the float tolerance.
static func _projection_equal(first: Projection, second: Projection) -> bool:
	return first.x.is_equal_approx(second.x) and first.y.is_equal_approx(second.y) and first.z.is_equal_approx(second.z) and first.w.is_equal_approx(second.w)


# Hides the visible preview and retires a finished request, so a pending old
# result can never reappear when the pointer leaves the model.
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
