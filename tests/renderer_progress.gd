extends "res://tests/test.gd"

# Focused regression tests for the chunk surface scheduling of `VoxelRenderer`.
#
# One chunk owns at most one in-flight build. A completed build installs even when
# a newer request for the same chunk already arrived, so a held edit shows
# progressive surfaces while it runs. A context change, a retire, or a chunk
# removal drops the in-flight eligibility, so an obsolete result never appears.
#
#   godot --headless --path . res://tests/renderer_progress.tscn
#   godot --headless --path . res://tests/renderer_progress.tscn -- held_edits
#
# The end-to-end drag acceptance lives in `tests/benchmarks/spray_latency.tscn`.

## The surface edits of one held edit.
const EDITS := 24
## The frames that a scenario observes after its last edit.
const SETTLE_FRAMES := 40
## The block edge of the single-chunk fixture.
const BLOCK := 16
## The block edge of the multi-chunk fixture.
const WIDE := 32

var renderer: VoxelRenderer
var second: VoxelRenderer
var frame: VoxelFrame
# The ordered wanted keys of one scenario, for the install order check.
var _wanted: Array[PackedInt64Array] = []
var _watch := Vector3i.ZERO
var _last_shown_key := PackedInt64Array()
var _last_order := -1
var _installs := 0
var _first_install_frame := -1
var _violations := 0
var _first_violation := ""
var _measuring := false
var _last_frame_us := 0
var _longest_frame_us := 0
var _kept := {}
# Per-scenario state that a later step reads.
var _edit_started_us := 0
var _edited_key := PackedInt64Array()
var _history := 0
var _other: VoxelFrame
var _target: VoxelFrame
var _jobs := {}
var _locations: Array[Vector3i] = []
var _peak_jobs := 0
var _peak_pending := 0
var _broken_eligibility := 0
var _wanted_key := PackedInt64Array()
# The shared cache saved around the lost-in-flight scenario.
var _saved_cache := {}
var _saved_order: Array[PackedInt64Array] = []
var _saved_bytes := 0
var _older_key := PackedInt64Array()
var _newer_key := PackedInt64Array()
var _base_key := PackedInt64Array()
var _settled_at_start := false


func _ready() -> void:
	timeout = 60.0
	test("a held edit installs progressive surfaces before the edits stop", _held_edits, "held_edits")
	test("undo drops a result that belongs to the undone state", _undo_no_stale, "undo_no_stale")
	test("a frame change drops a result from the previous frame", _frame_no_stale, "frame_no_stale")
	test("a source frame change drops a result from the replaced frame", _source_frame_no_stale, "source_frame_no_stale")
	test("a document change drops a result from the replaced document", _document_no_stale, "document_no_stale")
	test("an emptied chunk takes no stale or resurrected result", _chunk_removed, "chunk_removed")
	test("a lost completed in-flight result never deadlocks the view", _lost_inflight, "lost_inflight")
	test("two views share one build per chunk and one cached mesh", _shared_views, "shared_views")
	test("the request queue and the shared job map stay inside their bounds", _job_limits, "job_limits")
	test("an eligible completed result installs before a newer request and keeps it pending", _coalesced_install, "coalesced_install")


func _process(_delta: float) -> void:
	if not _measuring:
		return
	var now := Time.get_ticks_usec()
	_longest_frame_us = maxi(_longest_frame_us, now - _last_frame_us)
	_last_frame_us = now


# --- Scenarios ---------------------------------------------------------------

func _held_edits() -> void:
	step("Given one dense chunk with a fractured top face", func():
		_single_chunk_fixture()
		_watch = Vector3i.ZERO
	)
	await _settle(renderer)
	step("Then the chunk starts settled and displayed", func():
		expect(renderer.is_settled(), "the chunk starts settled")
		expect(renderer._chunk_instances.has(_watch), "the chunk is displayed")
		_wanted = [_active_key(_watch)]
	)
	step("When the user keeps editing the same chunk without a pause", func():
		_reset_observation()
		_measuring = true
		_edit_started_us = Time.get_ticks_usec()
	)
	for index in EDITS:
		_edit_surface(index)
		_wanted.append(_active_key(_watch))
		await get_tree().process_frame
		_observe()
	var installs_before_stop := _installs
	var first_frame := _first_install_frame
	var edits_us := Time.get_ticks_usec() - _edit_started_us
	for index in SETTLE_FRAMES:
		await get_tree().process_frame
		_observe()
	_measuring = false
	step("Then the held edit shows intermediate surfaces before it stops", func():
		print("MEASURE renderer_progress held_edits: edits=%d installs_before_stop=%d installs_total=%d first_install_frame=%d edit_span_us=%d gap_us=%d" % [
			EDITS, installs_before_stop, _installs, first_frame, edits_us, _longest_frame_us,
		])
		# Progress only. How many intermediate surfaces fit in the window follows
		# the chunk build cost and the machine load, so the count is reported and
		# the cadence target lives in `tests/benchmarks/renderer_cycle.tscn`.
		expect(installs_before_stop > 0, "a surface installs while the edits continue")
	)
	step("Then the installs follow the request order and the last one is exact", func():
		expect(_violations == 0, "no earlier surface replaced a later one%s" % _violation_note())
		expect(_same_key(_shown_key(renderer, _watch), _active_key(_watch)), "the final surface is the exact wanted surface")
		expect(renderer.is_settled(), "the renderer settles on the exact wanted surface")
	)


func _undo_no_stale() -> void:
	step("Given a settled two-chunk block", func():
		_wide_fixture()
		watch_chunk(WIDE - 1, WIDE - 1, WIDE - 1)
	)
	await _settle(renderer)
	step("Then the block starts settled", func():
		expect(renderer.is_settled(), "the block starts settled")
	)
	step("When a surface edit is undone two frames after it lands", func():
		_edit_recorded(WIDE - 1, WIDE - 1, WIDE - 1)
		_edited_key = _active_key(_watch)
		_history = State.undo_redo.get_history_count()
	)
	# Let the renderer start the build for the edited state, then undo it while
	# that result is still in flight.
	await get_tree().process_frame
	await get_tree().process_frame
	step("When the user undoes the edit", func():
		_kept = _displayed_map()
		State.undo_redo.undo()
		expect(not State.undo_redo.has_undo(), "the undo consumed the only history action")
		expect(not _same_key(_active_key(_watch), _edited_key), "the restored state has a different surface key")
	)
	await _context_safety([_watch])
	step("Then the undone state never reappears", func():
		expect(not _same_key(_shown_key(renderer, _watch), _edited_key), "the undone surface never installs again")
	)


func _frame_no_stale() -> void:
	step("Given a settled block on frame zero", func():
		_wide_fixture()
		watch_chunk(0, WIDE - 1, 0)
		_edit_recorded(0, WIDE - 1, 0)
	)
	await _settle(renderer)
	step("Then the edited block settles", func():
		expect(renderer.is_settled(), "the edited block settles")
	)
	step("When the user switches to an empty frame", func():
		_kept = _displayed_map()
		State.add_frame()
		expect(State.current_frame == 1, "the new frame is current")
	)
	await _context_safety(_all_locations())


func _source_frame_no_stale() -> void:
	step("Given a settled block and a second frame with other voxels", func():
		_wide_fixture()
		watch_chunk(0, WIDE - 1, 0)
	)
	await _settle(renderer)
	step("Then the block starts settled", func():
		expect(renderer.is_settled(), "the block starts settled")
		_other = _build_frame(WIDE, 8)
		_kept = _displayed_map()
	)
	step("When the view is pointed at the second frame", func():
		renderer.source_frame = _other
	)
	await _context_safety([_watch])
	step("When the view returns to the document frame", func():
		_kept = _displayed_map()
		renderer.source_frame = null
	)
	await _context_safety([_watch])


func _document_no_stale() -> void:
	step("Given a settled block", func():
		_wide_fixture()
		watch_chunk(0, WIDE - 1, 0)
	)
	await _settle(renderer)
	step("Then the block starts settled", func():
		expect(renderer.is_settled(), "the block starts settled")
		_kept = _displayed_map()
	)
	step("When the document is replaced", func():
		var replacement := VoxelDocument.new()
		replacement.frames[0].set_cell(Vector3i.ZERO, VoxelFrame.material(Color.GREEN))
		State.document = replacement
	)
	await _context_safety([_watch])


func _chunk_removed() -> void:
	step("Given a settled block where one chunk is about to empty", func():
		_wide_fixture()
		watch_chunk(WIDE - 1, WIDE - 1, WIDE - 1)
	)
	await _settle(renderer)
	step("Then the chunk is displayed", func():
		expect(renderer._chunk_instances.has(_watch), "the chunk is displayed")
	)
	step("When an edited chunk is emptied", func():
		_edit_recorded(WIDE - 1, WIDE - 1, WIDE - 1)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("When the last voxel of the chunk goes", func():
		_kept = _displayed_map()
		_wipe_chunk(_watch)
		expect(not renderer._displayed_surface_keys.has(_watch), "the emptied chunk leaves the display records")
		expect(not renderer._chunk_instances.has(_watch), "the emptied chunk retires its instance")
		expect(not renderer._inflight_surface_keys.has(_watch), "the emptied chunk owns no in-flight key")
	)
	await _context_safety([_watch])
	step("Then the removed chunk never returns", func():
		expect(not renderer._displayed_surface_keys.has(_watch), "no result installs for the removed chunk")
		expect(not renderer._chunk_instances.has(_watch), "no instance is created for the removed chunk")
		expect(not renderer._inflight_surface_keys.has(_watch), "the removed chunk owns no in-flight key")
		expect(renderer.is_settled(), "the renderer settles without the removed chunk")
	)


# A completed in-flight result can leave the shared cache before this view
# consumes it: another view reaps the build and later caches evict the entry. The
# view must drop that eligibility and schedule the newest request, or the chunk
# never updates and the view never settles.
#
# The scenario uses a dedicated view of a standalone frame, so no sibling view
# rebuilds the key and hides the gap.
func _lost_inflight() -> void:
	step("Given a settled dedicated view of a standalone frame", func():
		second = load("res://ui/Viewport/VoxelRenderer.tscn").instantiate()
		main.add_child(second)
		_target = _build_frame(WIDE, 8)
		second.source_frame = _target
		watch_chunk(0, 0, 0)
	)
	await _settle(second)
	step("Then the watched chunk is settled and displayed", func():
		expect(second.is_settled(), "the view starts settled")
		expect(second._chunk_instances.has(_watch), "the watched chunk is displayed")
	)
	step("When a completed result is evicted before the view consumes it", func():
		_target.set_cell(_watch * VoxelFrame.CHUNK_SIZE, VoxelFrame.material(Color.BLUE))
		second._request(_target, _watch)
		_wanted_key = _view_key(second, _watch)
		var wanted: PackedInt64Array = second._pending_surface_keys[_watch]
		expect(_same_key(wanted, _wanted_key), "the edit requests the newest surface")
		# A step lambda captures a local by value, so the saved cache lives on a
		# member.
		_saved_cache = VoxelRenderer._surface_cache.duplicate()
		_saved_order = VoxelRenderer._surface_use_order.duplicate()
		_saved_bytes = VoxelRenderer._surface_cache_bytes
		# Hold the newest key as this view's in-flight result while the shared
		# cache no longer holds it, as a full cache after an eviction would.
		VoxelRenderer._surface_cache = {}
		VoxelRenderer._surface_use_order = []
		VoxelRenderer._surface_cache_bytes = 0
		second._inflight_surface_keys[_watch] = _wanted_key
		expect(not VoxelRenderer._surface_cache.has(_wanted_key), "the completed result is not in the cache")
		expect(not VoxelRenderer._surface_jobs.has(_wanted_key), "no build is in flight for that key")
		expect(not _same_key(_shown_key(second, _watch), _wanted_key), "the newest surface is not displayed yet")
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the view schedules the newest request again", func():
		var building := VoxelRenderer._surface_jobs.has(_wanted_key)
		var shown := _shown_key(second, _watch)
		expect(building or _same_key(shown, _wanted_key), "the newest request is building or already installed")
	)
	var settled: bool = await _settle_within(second, 120)
	step("Then the newest surface installs and the view settles", func():
		expect(settled, "the view settles without the lost result")
		expect(_same_key(_shown_key(second, _watch), _view_key(second, _watch)), "the newest surface installs")
		expect(second._pending_surface_keys.is_empty(), "no request stays pending")
	)
	step("Then the shared cache returns for the other tests", func():
		VoxelRenderer._surface_cache = _saved_cache
		VoxelRenderer._surface_use_order = _saved_order
		VoxelRenderer._surface_cache_bytes = _saved_bytes
		expect(VoxelRenderer._surface_cache.size() > 0, "the shared cache is restored")
	)


func _shared_views() -> void:
	step("Given two views of the same settled block", func():
		_wide_fixture()
		second = load("res://ui/Viewport/VoxelRenderer.tscn").instantiate()
		main.add_child(second)
		watch_chunk(0, WIDE - 1, 0)
	)
	await _settle(renderer)
	await _settle(second)
	step("Then both views show one surface and one cached mesh", func():
		expect(renderer.is_settled() and second.is_settled(), "both views settle")
		expect(_same_key(_shown_key(renderer, _watch), _shown_key(second, _watch)), "both views show the same surface key")
		expect(renderer._chunk_instances[_watch].mesh == second._chunk_instances[_watch].mesh, "both views show one cached mesh")
		expect(not _has_duplicate_order(), "the shared cache holds one entry per surface key")
	)
	step("When one chunk changes while both views display it", func():
		_edit_recorded(0, WIDE - 1, 0)
		_jobs = {}
	)
	for index in SETTLE_FRAMES:
		for key in VoxelRenderer._surface_jobs:
			_jobs[key] = VoxelRenderer._surface_jobs[key].chunk_location
		if renderer.is_settled() and second.is_settled():
			break
		await get_tree().process_frame
	await _settle(renderer)
	await _settle(second)
	step("Then one build serves both views", func():
		var builds := 0
		for key in _jobs:
			if _jobs[key] == _watch:
				builds += 1
		print("MEASURE renderer_progress shared_views: views=2 builds_for_chunk=%d" % builds)
		expect(builds == 1, "one surface build serves both views")
		expect(not _has_duplicate_order(), "the shared cache holds one entry per surface key")
	)
	step("Then both views show the new exact surface and one mesh", func():
		var wanted := _active_key(_watch)
		expect(_same_key(_shown_key(renderer, _watch), wanted), "the first view shows the exact new surface")
		expect(_same_key(_shown_key(second, _watch), wanted), "the second view shows the exact new surface")
		expect(renderer._chunk_instances[_watch].mesh == second._chunk_instances[_watch].mesh, "both views reuse one mesh object")
		expect(renderer.is_settled() and second.is_settled(), "both views settle on the exact surface")
	)


func _job_limits() -> void:
	step("Given a settled eight-chunk block", func():
		_wide_fixture()
		_locations = _all_locations()
	)
	await _settle(renderer)
	step("Then the block covers eight settled chunks", func():
		expect(_locations.size() == 8, "the block covers eight chunks")
		expect(renderer.is_settled(), "the block starts settled")
		_peak_jobs = 0
		_peak_pending = 0
		_broken_eligibility = 0
		# Reset the frame mark, or the first measured frame counts the idle time
		# since the fixture was built.
		_reset_observation()
		_measuring = true
	)
	for index in EDITS:
		_edit_ring(index)
		await get_tree().process_frame
		_peak_jobs = maxi(_peak_jobs, VoxelRenderer._surface_jobs.size())
		_peak_pending = maxi(_peak_pending, renderer._pending_surface_keys.size())
		for location in renderer._inflight_surface_keys:
			if not renderer._pending_surface_keys.has(location):
				_broken_eligibility += 1
	_measuring = false
	await _settle(renderer)
	step("Then the bounds hold and every chunk shows its exact surface", func():
		print("MEASURE renderer_progress job_limits: chunks=%d edits=%d peak_jobs=%d peak_pending=%d gap_us=%d" % [
			_locations.size(), EDITS, _peak_jobs, _peak_pending, _longest_frame_us,
		])
		expect(_peak_jobs <= VoxelRenderer.SURFACE_JOB_LIMIT_MAX, "the shared job map stays inside its limit")
		expect(_peak_pending <= _locations.size(), "the pending queue holds one request per chunk at most")
		expect(_broken_eligibility == 0, "no in-flight key outlives its own request")
		for location in _locations:
			expect(_same_key(_shown_key(renderer, location), _active_key(location)), "the chunk %s shows its exact surface" % str(location))
	)


# --- Context safety ----------------------------------------------------------

# Watches every location for many frames after a context change. A surface that
# belongs to the replaced context must never appear. A surviving chunk may keep
# the key it displayed when the change happened, until its replacement is ready.
func _context_safety(locations: Array[Vector3i]) -> void:
	var watched: Array[Vector3i] = locations.duplicate()
	for location in _kept:
		if not watched.has(location):
			watched.append(location)
	_reset_observation()
	_measuring = true
	for index in SETTLE_FRAMES:
		await get_tree().process_frame
		_check_allowed(watched)
		if renderer.is_settled():
			break
	_measuring = false
	_check_allowed(watched)
	step("Then no surface from the replaced context appears", func():
		expect(_violations == 0, "every installed surface belongs to the current context%s" % _violation_note())
	)
	step("Then every surviving chunk settles on its exact surface", func():
		expect(renderer.is_settled(), "the renderer settles after the context change")
		var active: VoxelFrame = renderer._get_frame()
		for location in watched:
			if active != null and active.chunks.has(location):
				expect(_same_key(_shown_key(renderer, location), _active_key(location)), "the chunk %s shows the exact current surface" % str(location))
	)


func _check_allowed(watched: Array[Vector3i]) -> void:
	var active: VoxelFrame = renderer._get_frame()
	for location in watched:
		var shown := _shown_key(renderer, location)
		if active == null or not active.chunks.has(location):
			# The context no longer holds the chunk, so no surface or instance may
			# survive it.
			if shown.size() > 0:
				_record_violation("the removed chunk %s kept a surface" % str(location))
			if renderer._chunk_instances.has(location):
				_record_violation("the removed chunk %s kept an instance" % str(location))
			continue
		if shown.size() == 0:
			continue
		if _same_key(shown, _active_key(location)):
			continue
		if _kept.has(location) and _same_key(shown, _kept[location]):
			continue
		_record_violation("the chunk %s installed a surface outside the current context: %s" % [str(location), str(shown)])


# --- Observation -------------------------------------------------------------

func _observe() -> void:
	var shown := _shown_key(renderer, _watch)
	if shown.size() == 0 or _same_key(shown, _last_shown_key):
		return
	_last_shown_key = shown
	_installs += 1
	if _first_install_frame < 0:
		_first_install_frame = _installs
	var order := _wanted_index(shown)
	if order < 0:
		_record_violation("the chunk installed an unrequested surface: %s" % str(shown))
	elif order < _last_order:
		_record_violation("the surface %s installed after a newer one" % str(shown))
	else:
		_last_order = order


func _wanted_index(shown: PackedInt64Array) -> int:
	for index in _wanted.size():
		if _same_key(_wanted[index], shown):
			return index
	return -1


func _reset_observation() -> void:
	_last_shown_key = PackedInt64Array()
	_installs = 0
	_first_install_frame = -1
	_last_order = -1
	_violations = 0
	_first_violation = ""
	_longest_frame_us = 0
	_last_frame_us = Time.get_ticks_usec()


func _record_violation(message: String) -> void:
	_violations += 1
	if _first_violation == "":
		_first_violation = message


func _violation_note() -> String:
	return "" if _first_violation == "" else " (first: %s)" % _first_violation


func _displayed_map() -> Dictionary:
	var shown := {}
	for location in renderer._displayed_surface_keys:
		shown[location] = renderer._displayed_surface_keys[location]
	return shown


func _shown_key(target: VoxelRenderer, location: Vector3i) -> PackedInt64Array:
	if not target._displayed_surface_keys.has(location):
		return PackedInt64Array()
	return target._displayed_surface_keys[location]


# The exact wanted key of one chunk in the frame a given view draws.
func _view_key(view: VoxelRenderer, location: Vector3i) -> PackedInt64Array:
	var active: VoxelFrame = view._get_frame()
	if active == null or State.document == null or not active.chunks.has(location):
		return PackedInt64Array()
	return VoxelRenderer._signature(active, location, State.document.smooth_normals)


# The exact wanted key of one chunk in the frame the editor view draws.
func _active_key(location: Vector3i) -> PackedInt64Array:
	return _view_key(renderer, location)


func _same_key(first: PackedInt64Array, second: PackedInt64Array) -> bool:
	return first.size() == second.size() and first == second


func _has_duplicate_order() -> bool:
	var seen := {}
	for key in VoxelRenderer._surface_use_order:
		if seen.has(key):
			return true
		seen[key] = true
	return false


# --- Coalescing contract ------------------------------------------------------

# The coalescing contract, with no timing and no worker: an eligible completed
# result installs in the next renderer update even when a newer request already
# arrived, and the newer request stays pending until its own result is ready. A
# renderer that installs only the newest key fails this. The throughput target it
# replaced lives in `tests/benchmarks/renderer_cycle.tscn`.
func _coalesced_install() -> void:
	step("Given a settled dedicated view of a standalone frame", func():
		second = load("res://ui/Viewport/VoxelRenderer.tscn").instantiate()
		main.add_child(second)
		_target = _build_frame(WIDE, 8)
		second.source_frame = _target
		watch_chunk(0, 0, 0)
	)
	_settled_at_start = await _settle_within(second, 120)
	step("Then the watched chunk is settled and displayed", func():
		expect(_settled_at_start, "the view starts settled")
		expect(second._chunk_instances.has(_watch), "the watched chunk is displayed")
	)
	step("When an older request completes behind a newer one", func():
		var origin := _watch * VoxelFrame.CHUNK_SIZE
		_base_key = _view_key(second, _watch)
		# A first change, then a second change before the view updates, so the
		# older request and the newest request are two real states of the chunk.
		_target.set_cell(origin + Vector3i(0, 7, 0), VoxelFrame.material(Color.BLUE))
		second._request(_target, _watch)
		_older_key = _view_key(second, _watch)
		_target.set_cell(origin + Vector3i(1, 7, 0), VoxelFrame.material(Color.YELLOW))
		second._request(_target, _watch)
		_newer_key = _view_key(second, _watch)
		expect(not _same_key(_older_key, _newer_key), "the two requests differ")
		var wanted := PackedInt64Array()
		if second._pending_surface_keys.has(_watch):
			wanted = second._pending_surface_keys[_watch]
		expect(_same_key(wanted, _newer_key), "the newest change owns the request")
		expect(_same_key(_shown_key(second, _watch), _base_key), "the view still shows the first state")
		# The older request finished before the newest change arrived. Another view
		# left the result in the shared cache, and this view owns it as its
		# in-flight key.
		VoxelRenderer._cache_surface(_older_key, ArrayMesh.new(), 0, null)
		second._inflight_surface_keys[_watch] = _older_key
		expect(VoxelRenderer._surface_cache.has(_older_key), "the older result is complete")
		expect(not _same_key(_older_key, _base_key), "the older result is a new state")
	)
	step("When the view updates once", func():
		second._update_surfaces()
		expect(_same_key(_shown_key(second, _watch), _older_key), "the eligible result installs in the same update")
		var wanted := PackedInt64Array()
		if second._pending_surface_keys.has(_watch):
			wanted = second._pending_surface_keys[_watch]
		expect(_same_key(wanted, _newer_key), "the newest request stays pending")
	)
	step("Then the newest surface installs and the view settles", func():
		expect(await _settle_within(second, 120), "the view settles on the newest result")
		expect(_same_key(_shown_key(second, _watch), _view_key(second, _watch)), "the newest surface installs")
		expect(second._pending_surface_keys.is_empty(), "no request stays pending")
	)


# --- Fixtures ----------------------------------------------------------------

func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.current_color = Color.RED
	renderer = viewport_scene().get_node("VoxelRenderer")
	frame = State.get_current_voxel_frame()
	_kept = {}


func _cleanup_test() -> void:
	_measuring = false
	VoxelRenderer._surface_job_limit = 0
	if is_instance_valid(second):
		await _settle_within(second, 30)
		second.queue_free()
		second = null
	_target = null
	await _settle_within(renderer, 30)
	_wanted = []
	_kept = {}
	_wipe_document()
	_reset_observation()


# One dense chunk whose top face holds sixteen materials, so a surface edit
# changes real geometry and a chunk build costs more than one frame.
func _single_chunk_fixture() -> void:
	_wipe_document()
	_fill_block(BLOCK, true)
	sync_viewport()


func _wide_fixture() -> void:
	_wipe_document()
	_fill_block(WIDE, false)
	sync_viewport()


func _wipe_document() -> void:
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	frame = State.get_current_voxel_frame()


func _build_frame(size: int, height: int) -> VoxelFrame:
	var other := VoxelFrame.new()
	var cells := {}
	var material := VoxelFrame.material(Color.GREEN)
	for z in size:
		for y in height:
			for x in size:
				cells[Vector3i(x, y, z)] = material
	other.set_cells(cells)
	return other


# A uniform block, or one whose top face holds sixteen materials.
func _fill_block(size: int, fractured: bool) -> void:
	var cells := {}
	for z in size:
		for y in size:
			for x in size:
				var material := VoxelFrame.material(Color.RED)
				if fractured and y == size - 1:
					material = VoxelFrame.material(Color.from_hsv(float((x * size + z) % 16) / 16.0, 0.8, 0.9))
				cells[Vector3i(x, y, z)] = material
	frame.set_cells(cells)


# --- Edits -------------------------------------------------------------------

func watch_chunk(x: int, y: int, z: int) -> void:
	_watch = VoxelFrame.chunk_position(Vector3i(x, y, z))


# One top-face cell of the single chunk takes a new material.
func _edit_surface(index: int) -> void:
	var cell := Vector3i(index % BLOCK, BLOCK - 1, (index / BLOCK) % BLOCK)
	frame.set_cell(cell, VoxelFrame.material(Color.from_hsv(float(index % 12) / 12.0, 1.0, 0.5 + 0.03 * (index % 12))))
	_emit_cells([cell])


# One cell takes a new material through an edit transaction, so history can undo
# it.
func _edit_recorded(x: int, y: int, z: int) -> void:
	var cell := Vector3i(x, y, z)
	var tx := State.begin_edit()
	State.paint(cell, VoxelFrame.material(Color.BLUE))
	State.finish_edit(tx)
	_emit_cells([cell])


# One cell of every chunk of the block takes a new material.
func _edit_ring(index: int) -> void:
	var cells: Array[Vector3i] = []
	for location in _all_locations():
		var cell := location * VoxelFrame.CHUNK_SIZE + Vector3i(index % VoxelFrame.CHUNK_SIZE, VoxelFrame.CHUNK_SIZE - 1, 0)
		frame.set_cell(cell, VoxelFrame.material(Color.from_hsv(float(index % 10) / 10.0, 0.9, 0.6 + 0.03 * (index % 10))))
		cells.append(cell)
	_emit_cells(cells)


# Removes every voxel of one chunk, so the frame drops the chunk.
func _wipe_chunk(location: Vector3i) -> void:
	var cells: Array[Vector3i] = []
	var origin := location * VoxelFrame.CHUNK_SIZE
	for z in VoxelFrame.CHUNK_SIZE:
		for y in VoxelFrame.CHUNK_SIZE:
			for x in VoxelFrame.CHUNK_SIZE:
				var cell := origin + Vector3i(x, y, z)
				frame.set_cell(cell, VoxelFrame.material(Color.TRANSPARENT))
				cells.append(cell)
	_emit_cells(cells)


func _emit_cells(cells: Array[Vector3i]) -> void:
	State.document._bounds_dirty = true
	State.cells_changed.emit(State.current_frame, cells)


func _all_locations() -> Array[Vector3i]:
	var locations: Array[Vector3i] = []
	var chunks := int(WIDE / VoxelFrame.CHUNK_SIZE)
	for z in chunks:
		for y in chunks:
			for x in chunks:
				locations.append(Vector3i(x, y, z))
	locations.sort()
	return locations


func _settle(target: VoxelRenderer) -> void:
	if not is_instance_valid(target):
		return
	while not target.is_settled():
		await get_tree().process_frame


# Settles a renderer inside a bounded frame count, so a view that cannot make
# progress fails a check instead of hanging the watchdog.
func _settle_within(target: VoxelRenderer, frames: int) -> bool:
	for index in frames:
		if target.is_settled():
			return true
		await get_tree().process_frame
	return target.is_settled()
