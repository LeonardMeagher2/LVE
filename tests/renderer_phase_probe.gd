extends VoxelRenderer

## A test-only renderer probe for the surface phase timings.
##
## It records, for each `_update_surfaces` call, how long the call took, how many
## shared builds were already finished at entry, and whether the call consumed a
## result or launched a build. For one watched chunk it also records the frame a
## build's worker finished, the frame its result was cached, the frame its
## replacement was launched, and the frame it installed.
##
## The probe changes no behavior. The phases are what an ordering change must be
## judged on, so the numbers are recorded where the renderer itself takes the
## decisions.

## One entry per `_update_surfaces` call: frame, microseconds, ready builds,
## whether the call consumed a result, and whether it launched a build.
var calls: Array[Dictionary] = []
## The frame a shared build's worker was seen finished while this view looked,
## keyed by surface key. It stays -1 when another view reaps the build first.
var worker_frames := {}
## The frame a finished result was cached by this view, keyed by surface key.
var cache_frames := {}
## The frame a launched result was first seen in the shared cache, whichever view
## cached it. This is the frame the build really became available.
var available_frames := {}
## The frames a chunk's result installed.
var install_frames := {}
## The frames a build was launched for a chunk.
var launch_frames := {}
## The surface key of each launch, in the same order as [member launch_frames].
var launch_keys := {}
## The frames a chunk's in-flight result was consumed.
var consume_frames := {}
## The number of calls that spent the whole work slice without consuming or
## launching anything. A call like that deferred this view's own result behind
## the shared reap work.
var starved_calls := 0
## The longest one call took.
var max_call_us := 0
## The total microseconds of every call.
var total_call_us := 0
## The peak number of shared builds already finished at one call entry.
var max_ready := 0
## The surface keys this probe launched. A key that appears twice is a duplicate
## build for one identical surface.
var launched_keys := {}
## The frames of a bare worker round trip, measured in the same frame loop. It
## separates the pool pickup latency from the surface build cost.
var pool_trips: Array[int] = []
## The frame of the current call, relative to the mark.
var _call_frame := 0
var _call_started_us := 0
var _call_consumed := false
var _call_launched := false
var _ready_at_entry: Array = []
var _mark_frame := 0
var _trip_task_id := -1
var _trip_start_frame := 0
var _trip_sink := 0


## Starts a relative timeline. Every later frame record is relative to this one.
func mark() -> void:
	_mark_frame = Engine.get_process_frames()


func _now() -> int:
	return Engine.get_process_frames() - _mark_frame


## Clears every record. It does not change the renderer state.
func reset_probe() -> void:
	calls = []
	worker_frames = {}
	cache_frames = {}
	available_frames = {}
	install_frames = {}
	launch_frames = {}
	launch_keys = {}
	consume_frames = {}
	pool_trips = []
	starved_calls = 0
	max_call_us = 0
	total_call_us = 0
	max_ready = 0
	launched_keys = {}
	mark()


func _update_surfaces() -> void:
	_call_frame = _now()
	_call_started_us = Time.get_ticks_usec()
	_call_consumed = false
	_call_launched = false
	_ready_at_entry = []
	_tick_pool_trip()
	# A launched result can be cached by any view that shares the surface cache.
	# The frame it first appears there is the frame the build became available.
	for key in launched_keys:
		if not available_frames.has(key) and _surface_cache.has(key):
			available_frames[key] = _call_frame
	for key in _surface_jobs:
		var job: VoxelMeshBuilder = _surface_jobs[key]
		if WorkerThreadPool.is_task_completed(job.worker_task_id):
			_ready_at_entry.append(key)
			if not worker_frames.has(key):
				worker_frames[key] = _call_frame
	max_ready = maxi(max_ready, _ready_at_entry.size())
	super._update_surfaces()
	var elapsed := Time.get_ticks_usec() - _call_started_us
	total_call_us += elapsed
	max_call_us = maxi(max_call_us, elapsed)
	for key in _ready_at_entry:
		if not _surface_jobs.has(key) and not cache_frames.has(key):
			cache_frames[key] = _call_frame
	if not _call_consumed and not _call_launched and elapsed >= State.WORK_SLICE_US:
		starved_calls += 1
	calls.append({
		"frame": _call_frame,
		"us": elapsed,
		"ready": _ready_at_entry.size(),
		"consumed": _call_consumed,
		"launched": _call_launched,
	})


func _consume_inflight(chunk_location: Vector3i) -> bool:
	var consumed := super._consume_inflight(chunk_location)
	if consumed:
		_call_consumed = true
		if not consume_frames.has(chunk_location):
			consume_frames[chunk_location] = []
		consume_frames[chunk_location].append(_call_frame)
	return consumed


func _launch_surface(chunk_location: Vector3i, active_frame: VoxelFrame) -> void:
	var before = _inflight_surface_keys.get(chunk_location, null)
	super._launch_surface(chunk_location, active_frame)
	var after = _inflight_surface_keys.get(chunk_location, null)
	if after != null and after != before:
		_call_launched = true
		if not launch_frames.has(chunk_location):
			launch_frames[chunk_location] = []
			launch_keys[chunk_location] = []
		launch_frames[chunk_location].append(_call_frame)
		launch_keys[chunk_location].append(after)
		if launched_keys.has(after):
			launched_keys[after] = int(launched_keys[after]) + 1
		else:
			launched_keys[after] = 1


func _install(chunk_location: Vector3i, surface_key: PackedInt64Array, entry: Dictionary) -> void:
	super._install(chunk_location, surface_key, entry)
	var shown = _displayed_surface_keys.get(chunk_location, null)
	if shown != null and shown == surface_key:
		if not install_frames.has(chunk_location):
			install_frames[chunk_location] = []
		install_frames[chunk_location].append(_call_frame)


# Measures one bare worker round trip in the same frame loop. It separates the
# pool pickup latency from the surface build cost, because the bare task does no
# work.
func _tick_pool_trip() -> void:
	if _trip_task_id >= 0:
		if WorkerThreadPool.is_task_completed(_trip_task_id):
			WorkerThreadPool.wait_for_task_completion(_trip_task_id)
			pool_trips.append(_call_frame - _trip_start_frame)
			_trip_task_id = -1
	if _trip_task_id < 0:
		_trip_start_frame = _call_frame
		_trip_task_id = WorkerThreadPool.add_task(_trip_run, false, "phase probe")


func _trip_run() -> void:
	_trip_sink += 1
